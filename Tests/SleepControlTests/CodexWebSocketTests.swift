import Foundation
import CryptoKit
import Darwin
import XCTest
@testable import SleepControl

final class CodexWebSocketTests: XCTestCase {
    private final class Outcome: @unchecked Sendable {
        let lock = NSLock()
        private var failure: Error?
        func save(_ error: Error) { lock.lock(); failure = error; lock.unlock() }
        func check() throws { lock.lock(); defer { lock.unlock() }; if let failure { throw failure } }
    }

    private struct Peer {
        let fd: Int32
        func read(_ size: Int) throws -> Data {
            var data = Data()
            let deadline = Date().addingTimeInterval(3)
            while data.count < size {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard Date() < deadline, poll(&descriptor, 1, 100) >= 0 else { throw FixtureError.io }
                if descriptor.revents & Int16(POLLIN) == 0 { continue }
                var bytes = [UInt8](repeating: 0, count: min(64 * 1024, size - data.count))
                let count = recv(fd, &bytes, bytes.count, 0)
                guard count > 0 else { throw FixtureError.io }
                data.append(contentsOf: bytes.prefix(count))
            }
            return data
        }
        func write(_ data: Data) throws {
            var offset = 0
            while offset < data.count {
                let count = data.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
                guard count > 0 else { throw FixtureError.io }
                offset += count
            }
        }
        func handshake(validAccept: Bool = true, status: Int = 101) throws {
            var data = Data()
            while !data.suffix(4).elementsEqual(Data("\r\n\r\n".utf8)) {
                guard data.count < 16 * 1024 else { throw FixtureError.protocolError }
                data.append(try read(1))
            }
            let header = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(header.hasPrefix("GET / HTTP/1.1\r\n"))
            XCTAssertTrue(header.contains("Sec-WebSocket-Version: 13"))
            let keyLine = try XCTUnwrap(header.components(separatedBy: "\r\n").first { $0.hasPrefix("Sec-WebSocket-Key:") })
            let key = keyLine.dropFirst("Sec-WebSocket-Key:".count).trimmingCharacters(in: .whitespaces)
            XCTAssertEqual(Data(base64Encoded: key)?.count, 16)
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
                .base64EncodedString()
            try write(Data("HTTP/1.1 \(status) Upgrade\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: \(validAccept ? accept : "invalid")\r\n\r\n".utf8))
        }
        func frame(opcode: UInt8 = 1, payload: Data, final: Bool = true) throws {
            var data = Data([(final ? 0x80 : 0) | opcode])
            let count = UInt64(payload.count)
            if count < 126 { data.append(UInt8(count)) }
            else if count <= UInt16.max { data.append(126); data.append(UInt8(count >> 8)); data.append(UInt8(count & 255)) }
            else { data.append(127); data.append(contentsOf: (0..<8).reversed().map { UInt8((count >> ($0 * 8)) & 255) }) }
            data.append(payload)
            try write(data)
        }
        func readFrame() throws -> (UInt8, Data) {
            let head = [UInt8](try read(2))
            XCTAssertNotEqual(head[1] & 0x80, 0, "Client frames must be masked")
            var length = Int(head[1] & 0x7f)
            if length == 126 { length = try read(2).reduce(0) { $0 << 8 | Int($1) } }
            else if length == 127 { length = try read(8).reduce(0) { $0 << 8 | Int($1) } }
            guard length <= CodexWebSocket.maximumMessageSize else { throw FixtureError.protocolError }
            let mask = [UInt8](try read(4))
            let payload = try read(length)
            return (head[0] & 15, Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }))
        }
        func row() throws -> [String: Any] {
            let (opcode, data) = try readFrame()
            XCTAssertEqual(opcode, 1)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        func respond(to row: [String: Any], result: [String: Any]) throws {
            try frame(payload: JSONSerialization.data(withJSONObject: ["id": try XCTUnwrap(row["id"]), "result": result]))
        }
    }
    private enum FixtureError: Error { case io, protocolError }

    /// socketpair 不访问真实 Codex、聊天记录、电源或外部 socket。
    private func fixture(server: @escaping (Peer) throws -> Void, client: (Int32) throws -> Void) throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        guard sockets[0] >= 0, sockets[1] >= 0 else { throw FixtureError.io }
        var yes: Int32 = 1
        setsockopt(sockets[1], SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        let peer = Peer(fd: sockets[1])
        let done = expectation(description: "WebSocket peer completed")
        let outcome = Outcome()
        DispatchQueue.global().async {
            defer { close(peer.fd); done.fulfill() }
            do { try server(peer) } catch { outcome.save(error) }
        }
        // 客户端连接接管并关闭 sockets[0]，包括握手失败的情况。
        var clientError: Error?
        do { try client(sockets[0]) } catch { clientError = error }
        wait(for: [done], timeout: 5)
        try outcome.check()
        if let clientError { throw clientError }
    }

    func testRealHandshakeAndFramedReadOnlySnapshotRecognizesWorkAndWaiting() throws {
        try fixture { peer in
            try peer.handshake()
            let initialize = try peer.row()
            XCTAssertEqual(initialize["method"] as? String, "initialize")
            try peer.respond(to: initialize, result: [:])
            XCTAssertEqual(try peer.row()["method"] as? String, "initialized")
            let loaded = try peer.row()
            XCTAssertEqual(loaded["method"] as? String, "thread/loaded/list")
            // 通知必须被忽略，不能当作某个请求的响应或审批决策。
            try peer.frame(payload: JSONSerialization.data(withJSONObject: ["method": "thread/status/changed", "params": [:]]))
            try peer.respond(to: loaded, result: ["data": ["waiting", "working"]])
            for id in ["waiting", "working"] {
                let read = try peer.row()
                XCTAssertEqual(read["method"] as? String, "thread/read")
                let params = try XCTUnwrap(read["params"] as? [String: Any])
                XCTAssertEqual(params["threadId"] as? String, id)
                XCTAssertEqual(params["includeTurns"] as? Bool, false)
                try peer.respond(to: read, result: ["thread": ["status": ["type": "active", "activeFlags": id == "waiting" ? ["waitingOnApproval"] : []]]])
                let background = try peer.row()
                XCTAssertEqual(background["method"] as? String, "thread/backgroundTerminals/list")
                try peer.respond(to: background, result: ["data": id == "waiting" ? [] : [["processId": "job"]]])
            }
        } client: { fd in
            let connection = try CodexStatusConnection(transport: CodexWebSocket(connectedSocket: fd))
            let snapshot = try CodexRuntimeProbe.snapshot(startedAt: Date(), request: connection.request)
            XCTAssertEqual(snapshot.sessions["waiting"]?.phase, .waiting)
            XCTAssertEqual(snapshot.sessions["working"]?.phase, .active)
            XCTAssertEqual(snapshot.sessions["working"]?.backgroundIDs, ["job"])
            XCTAssertThrowsError(try connection.request("thread/resume", [:]))
        }
    }

    func testExtendedLengthsAndClientMasking() throws {
        let messages = [Data(repeating: 65, count: 126), Data(repeating: 66, count: 65_536)]
        try fixture { peer in
            try peer.handshake()
            for message in messages {
                let (opcode, received) = try peer.readFrame()
                XCTAssertEqual(opcode, 1)
                XCTAssertEqual(received, message)
                try peer.frame(payload: message)
            }
        } client: { fd in
            let connection = try CodexWebSocket(connectedSocket: fd)
            for message in messages {
                let deadline = Date().addingTimeInterval(2)
                try connection.send(message, deadline: deadline)
                XCTAssertEqual(try connection.receive(deadline: deadline), message)
            }
        }
    }

    func testFragmentedTextWithInterleavedPing() throws {
        try fixture { peer in
            try peer.handshake()
            try peer.frame(payload: Data("{\"result\":".utf8), final: false)
            try peer.frame(opcode: 9, payload: Data("ping".utf8))
            let (opcode, pong) = try peer.readFrame()
            XCTAssertEqual(opcode, 10)
            XCTAssertEqual(pong, Data("ping".utf8))
            try peer.frame(opcode: 0, payload: Data("{}}".utf8))
        } client: { fd in
            let connection = try CodexWebSocket(connectedSocket: fd)
            XCTAssertEqual(try connection.receive(deadline: Date().addingTimeInterval(2)), Data("{\"result\":{}}".utf8))
        }
    }

    func testInvalidHandshakeIsRejected() throws {
        for status in [101, 400] {
            try fixture { peer in
                try peer.handshake(validAccept: false, status: status)
            } client: { fd in
                XCTAssertThrowsError(try CodexWebSocket(connectedSocket: fd))
            }
        }
    }

    func testInvalidAndOversizedFramesAreRejected() throws {
        let badFrames = [
            Data([0x81, 0x80]), // 服务器不能使用掩码。
            Data([0x80, 0]), // 没有起始帧的 continuation。
            Data([0xc1, 0]), // 未协商压缩却设置 RSV。
            Data([0x09, 0]), // 控制帧不能分片。
            Data([0x81, 127, 0, 0, 0, 0, 0, 128, 0, 1]), // > 8 MiB，不分配负载。
            Data([0x81, 1, 0xff]) // 非 UTF-8 文本。
        ]
        for frame in badFrames {
            try fixture { peer in
                try peer.handshake()
                try peer.write(frame)
            } client: { fd in
                let connection = try CodexWebSocket(connectedSocket: fd)
                XCTAssertThrowsError(try connection.receive(deadline: Date().addingTimeInterval(1)))
            }
        }
    }

    func testPartialMessageTimesOutWithoutBlockingIndefinitely() throws {
        try fixture { peer in
            try peer.handshake()
            try peer.write(Data([0x81, 4, 65]))
            Thread.sleep(forTimeInterval: 0.15)
        } client: { fd in
            let connection = try CodexWebSocket(connectedSocket: fd)
            let start = Date()
            XCTAssertThrowsError(try connection.receive(deadline: start.addingTimeInterval(0.04)))
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        }
    }

    func testCloseFrameIsAcknowledged() throws {
        try fixture { peer in
            try peer.handshake()
            try peer.frame(opcode: 8, payload: Data([3, 232]))
            let (opcode, _) = try peer.readFrame()
            XCTAssertEqual(opcode, 8)
        } client: { fd in
            let connection = try CodexWebSocket(connectedSocket: fd)
            XCTAssertThrowsError(try connection.receive(deadline: Date().addingTimeInterval(1)))
        }
    }

    func testRPCErrorReportsMethodAndCodeWithoutServerContent() throws {
        try fixture { peer in
            try peer.handshake()
            try peer.respond(to: peer.row(), result: [:])
            _ = try peer.row() // initialized
            let request = try peer.row()
            try peer.frame(payload: JSONSerialization.data(withJSONObject: ["id": try XCTUnwrap(request["id"]),
                "error": ["code": -32601, "message": "private fixture content"]]))
        } client: { fd in
            let connection = try CodexStatusConnection(transport: CodexWebSocket(connectedSocket: fd))
            XCTAssertThrowsError(try connection.request("thread/loaded/list", [:])) { error in
                XCTAssertTrue(error.localizedDescription.contains("thread/loaded/list"))
                XCTAssertTrue(error.localizedDescription.contains("-32601"))
                XCTAssertFalse(error.localizedDescription.contains("private fixture content"))
            }
        }
    }
}
