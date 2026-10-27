import Foundation
import CryptoKit
import Darwin

/// Codex 控制 socket 使用 RFC 6455 WebSocket，并非 stdio 的 JSONL。
/// 仅连接已有的本机服务；不创建监听端口，也不启动 Codex 服务。
final class CodexWebSocket {
    static let maximumMessageSize = 8 * 1024 * 1024
    private var fd: Int32
    private var buffer = Data()

    convenience init(socket: URL, timeout: TimeInterval = 2) throws {
        try self.init(connectedSocket: Self.connect(socket, timeout: timeout), timeout: timeout)
    }

    /// 接管描述符的所有权；socketpair 用于不接触真实会话的传输测试。
    init(connectedSocket: Int32, timeout: TimeInterval = 2) throws {
        fd = connectedSocket
        do {
            try Self.configure(fd)
            try upgrade(deadline: Date().addingTimeInterval(timeout))
        } catch {
            disconnect()
            throw error
        }
    }

    deinit { disconnect() }

    private func disconnect() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    private static func failure(_ operation: String) -> AIProtectionError {
        .failed(L10n.text("The local Codex connection failed during %@ (errno %@).", String(describing: operation), String(describing: errno)))
    }

    private static func configure(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw failure(L10n.text("configuration")) }
        var yes: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0 else {
            throw failure(L10n.text("configuration"))
        }
    }

    private static func connect(_ url: URL, timeout: TimeInterval) throws -> Int32 {
        var address = sockaddr_un()
        let path = Array(url.path.utf8)
        guard !path.contains(0), path.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw AIProtectionError.failed(L10n.text("The local Codex socket path is invalid or too long."))
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.copyBytes(from: path)
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure(L10n.text("creation")) }
        do {
            try configure(fd)
            let status = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if status != 0 {
                guard errno == EINPROGRESS else { throw failure(L10n.text("connection")) }
                try wait(fd, events: Int16(POLLOUT), deadline: Date().addingTimeInterval(timeout))
                var error: Int32 = 0
                var size = socklen_t(MemoryLayout.size(ofValue: error))
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else { throw failure(L10n.text("connection")) }
                guard error == 0 else {
                    throw AIProtectionError.failed(L10n.text("The local Codex connection could not be established (errno %@).", String(describing: error)))
                }
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    private static func wait(_ fd: Int32, events: Int16, deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw AIProtectionError.failed(L10n.text("The local Codex status connection timed out.")) }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let status = poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
            if status < 0 && errno == EINTR { continue }
            guard status >= 0 else { throw failure(L10n.text("waiting")) }
            if status == 0 { continue }
            if descriptor.revents & events != 0 { return }
            throw AIProtectionError.failed(L10n.text("The local Codex status connection was lost."))
        }
    }

    private func write(_ data: Data, deadline: Date) throws {
        var offset = 0
        while offset < data.count {
            try Self.wait(fd, events: Int16(POLLOUT), deadline: deadline)
            let count = data.withUnsafeBytes {
                Darwin.send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0)
            }
            if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            guard count > 0 else { throw Self.failure(L10n.text("sending")) }
            offset += count
        }
    }

    private func fill(_ size: Int, deadline: Date) throws {
        while buffer.count < size {
            try Self.wait(fd, events: Int16(POLLIN), deadline: deadline)
            var bytes = [UInt8](repeating: 0, count: min(64 * 1024, size - buffer.count))
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            guard count > 0 else { throw AIProtectionError.failed(L10n.text("The local Codex status connection was lost.")) }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }

    private func take(_ size: Int, deadline: Date) throws -> Data {
        try fill(size, deadline: deadline)
        let result = Data(buffer.prefix(size))
        buffer.removeFirst(size)
        return result
    }

    private func upgrade(deadline: Date) throws {
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        try write(Data(request.utf8), deadline: deadline)
        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil {
            guard buffer.count < 16 * 1024 else { throw AIProtectionError.failed(L10n.text("The Codex WebSocket handshake response is too large.")) }
            try fill(buffer.count + 1, deadline: deadline)
        }
        let end = buffer.range(of: separator)!.upperBound
        let header = String(decoding: buffer[..<end], as: UTF8.self)
        buffer.removeSubrange(..<end)
        let lines = header.components(separatedBy: "\r\n")
        guard lines.first?.split(separator: " ").prefix(2).joined(separator: " ") == "HTTP/1.1 101" else {
            throw AIProtectionError.failed(L10n.text("The Codex control socket did not accept the WebSocket handshake."))
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
            if pair.count == 2 {
                let name = pair[0].lowercased()
                let value = pair[1].trimmingCharacters(in: .whitespaces)
                headers[name] = headers[name].map { $0 + "," + value } ?? value
            }
        }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
            .base64EncodedString()
        let upgrades = (headers["connection"] ?? "").lowercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard headers["upgrade"]?.lowercased() == "websocket", upgrades.contains("upgrade"),
              headers["sec-websocket-accept"] == accept,
              headers["sec-websocket-extensions"] == nil, headers["sec-websocket-protocol"] == nil else {
            throw AIProtectionError.failed(L10n.text("The Codex WebSocket handshake could not be verified."))
        }
    }

    func send(_ data: Data, deadline: Date) throws {
        guard data.count <= Self.maximumMessageSize else { throw AIProtectionError.failed(L10n.text("The Codex status request is too large.")) }
        try sendFrame(opcode: 1, payload: data, deadline: deadline)
    }

    private func sendFrame(opcode: UInt8, payload: Data, deadline: Date) throws {
        var frame = Data([0x80 | opcode])
        let length = UInt64(payload.count)
        if length < 126 { frame.append(0x80 | UInt8(length)) }
        else if length <= UInt16.max {
            frame.append(0x80 | 126)
            frame.append(contentsOf: [UInt8(length >> 8), UInt8(length & 255)])
        } else {
            frame.append(0x80 | 127)
            frame.append(contentsOf: (0..<8).reversed().map { UInt8((length >> ($0 * 8)) & 255) })
        }
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        try write(frame, deadline: deadline)
    }

    func receive(deadline: Date) throws -> Data {
        var message = Data()
        var fragmented = false
        while true {
            let head = [UInt8](try take(2, deadline: deadline))
            let final = head[0] & 0x80 != 0
            let opcode = head[0] & 0x0f
            guard head[0] & 0x70 == 0, head[1] & 0x80 == 0 else { throw invalidFrame() }
            var length = UInt64(head[1] & 0x7f)
            if length == 126 {
                length = try take(2, deadline: deadline).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                guard length >= 126 else { throw invalidFrame() }
            } else if length == 127 {
                length = try take(8, deadline: deadline).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                guard length > UInt16.max else { throw invalidFrame() }
            }
            guard length <= UInt64(Self.maximumMessageSize) else { throw invalidFrame() }
            if opcode >= 8 {
                guard final, length <= 125, [8, 9, 10].contains(opcode) else { throw invalidFrame() }
            } else {
                guard (opcode == 1 && !fragmented) || (opcode == 0 && fragmented),
                      UInt64(message.count) + length <= UInt64(Self.maximumMessageSize) else { throw invalidFrame() }
            }
            let payload = try take(Int(length), deadline: deadline)
            switch opcode {
            case 8:
                try sendFrame(opcode: 8, payload: payload, deadline: deadline)
                throw AIProtectionError.failed(L10n.text("Codex closed the local status connection."))
            case 9: try sendFrame(opcode: 10, payload: payload, deadline: deadline)
            case 10: continue
            default:
                message.append(payload)
                if final {
                    guard String(data: message, encoding: .utf8) != nil else { throw invalidFrame() }
                    return message
                }
                fragmented = true
            }
        }
    }

    private func invalidFrame() -> AIProtectionError {
        .failed(L10n.text("Codex WebSocket returned an invalid or oversized message."))
    }
}
