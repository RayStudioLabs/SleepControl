import Foundation
import Darwin

struct AIRuntimeSession {
    var phase: AITaskPhase?
    var ownerPID: Int32?
    var backgroundIDs: [String] = []
}

struct AIRuntimeSnapshot {
    var source: String
    var startedAt: Date
    var sessions: [String: AIRuntimeSession]
}

enum AIRuntimeInitialSync {
    static func read() -> ([AIRuntimeSnapshot], String?) {
        var snapshots: [AIRuntimeSnapshot] = []
        var errors: [String] = []
        do { if let snapshot = try CodexRuntimeProbe().read() { snapshots.append(snapshot) } }
        catch { errors.append(error.localizedDescription) }
        do { snapshots.append(try ClaudeRuntimeProbe.read(environment: ProcessInfo.processInfo.environment)) }
        catch { errors.append(error.localizedDescription) }
        return (snapshots, errors.isEmpty ? nil : errors.joined(separator: L10n.text("Warning separator")))
    }
}

enum ClaudeRuntimeProbe {
    /// 兼容当前 Claude Code 2.1 的本机会话注册文件，只读取状态与进程身份。
    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     environment: [String: String] = [:],
                     isAlive: (Int32) -> Bool = AIProcess.isAlive) throws -> AIRuntimeSnapshot {
        let start = Date()
        let config = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        let directory = config.appendingPathComponent("sessions")
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return AIRuntimeSnapshot(source: "claude", startedAt: start, sessions: [:])
        }
        var sessions: [String: AIRuntimeSession] = [:]
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        for file in files {
            guard let pid = Int32(file.deletingPathExtension().lastPathComponent), isAlive(pid) else { continue }
            let data = try Data(contentsOf: file)
            guard data.count < 1024 * 1024,
                  let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (row["pid"] as? NSNumber)?.int32Value == pid,
                  let id = row["sessionId"] as? String,
                  let version = row["version"] as? String, version.hasPrefix("2.1."),
                  let status = row["status"] as? String else {
                throw AIProtectionError.failed(L10n.text("The Claude session status format has changed. Unknown status was not treated as a finished task."))
            }
            let phase: AITaskPhase?
            switch status {
            case "busy": phase = .active
            case "waiting": phase = .waiting
            case "idle": phase = nil
            // shell 表示终端会话暂时处于 shell 界面，不能据此认定 AI 正在执行。
            case "shell": phase = nil
            default: throw AIProtectionError.failed(L10n.text("Claude returned an unknown task status: %@", String(describing: status)))
            }
            sessions[id] = AIRuntimeSession(phase: phase, ownerPID: pid)
        }
        return AIRuntimeSnapshot(source: "claude", startedAt: start, sessions: sessions)
    }
}

/// 只使用 initialize、thread/loaded/list、thread/read 与 backgroundTerminals/list。
/// 不启动会话、不接管会话订阅，也不读取令牌或审批请求的内容。
final class CodexRuntimeProbe {
    private var connection: CodexStatusConnection?

    func read() throws -> AIRuntimeSnapshot? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        let socket = codexHome.appendingPathComponent("app-server-control/app-server-control.sock")
        guard FileManager.default.fileExists(atPath: socket.path) else { return nil }
        let start = Date()
        do {
            if connection == nil { connection = try CodexStatusConnection(socket: socket) }
            guard let connection else { return nil }
            return try Self.snapshot(startedAt: start, request: connection.request)
        } catch {
            connection = nil
            throw AIProtectionError.failed(L10n.text("The local Codex status connection is unavailable: %@ Disconnected sessions were not treated as finished.", String(describing: error.localizedDescription)))
        }
    }

    static func phase(_ status: [String: Any]) throws -> AITaskPhase? {
        switch status["type"] as? String {
        case "idle", "notLoaded": return nil
        case "active":
            guard let flags = status["activeFlags"] as? [String],
                  flags.allSatisfy({ ["waitingOnApproval", "waitingOnUserInput"].contains($0) }) else {
                throw AIProtectionError.failed(L10n.text("The Codex task status was not recognized."))
            }
            return flags.isEmpty ? .active : .waiting
        default: throw AIProtectionError.failed(L10n.text("A Codex session reported an unknown or unexpected status."))
        }
    }

    static func snapshot(startedAt: Date,
                         request: (String, [String: Any]) throws -> [String: Any]) throws -> AIRuntimeSnapshot {
        let deadline = Date().addingTimeInterval(8)
        func read(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            guard Date() < deadline else { throw AIProtectionError.failed(L10n.text("Reading Codex session status timed out.")) }
            return try request(method, params)
        }
        var ids: [String] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = ["limit": 100]
            if let cursor { params["cursor"] = cursor }
            let result = try read("thread/loaded/list", params)
            guard let page = result["data"] as? [String] else { throw AIProtectionError.invalidEvent }
            ids += page
            cursor = result["nextCursor"] as? String
            guard ids.count <= 1000 else { throw AIProtectionError.failed(L10n.text("The number of Codex sessions exceeds the detection limit.")) }
        } while cursor != nil
        var sessions: [String: AIRuntimeSession] = [:]
        for id in ids {
            let result = try read("thread/read", ["threadId": id, "includeTurns": false])
            guard let thread = result["thread"] as? [String: Any],
                  let status = thread["status"] as? [String: Any] else { throw AIProtectionError.invalidEvent }
            let phase = try phase(status)
            var backgrounds: [String] = []
            var bgCursor: String?
            repeat {
                var params: [String: Any] = ["threadId": id, "limit": 100]
                if let bgCursor { params["cursor"] = bgCursor }
                let result = try read("thread/backgroundTerminals/list", params)
                guard let rows = result["data"] as? [[String: Any]] else { throw AIProtectionError.invalidEvent }
                backgrounds += rows.compactMap { $0["processId"] as? String }
                bgCursor = result["nextCursor"] as? String
                guard backgrounds.count <= 1000 else { throw AIProtectionError.failed(L10n.text("The number of background terminals exceeds the detection limit.")) }
            } while bgCursor != nil
            sessions[id] = AIRuntimeSession(phase: phase, ownerPID: nil, backgroundIDs: backgrounds)
        }
        return AIRuntimeSnapshot(source: "codex", startedAt: startedAt, sessions: sessions)
    }
}

/// 请求和响应均在 WebSocket 文本帧中，不使用换行分隔协议。
final class CodexStatusConnection {
    private let transport: CodexWebSocket
    private var nextID = 0

    convenience init(socket: URL) throws {
        try self.init(transport: CodexWebSocket(socket: socket))
    }

    init(transport: CodexWebSocket) throws {
        self.transport = transport
        _ = try request("initialize", ["clientInfo": ["name": "sleepcontrol_observer", "version": "0.2.1"],
                                      "capabilities": ["experimentalApi": true]])
        try send(["method": "initialized"], deadline: Date().addingTimeInterval(2))
    }

    private func send(_ row: [String: Any], deadline: Date) throws {
        try transport.send(JSONSerialization.data(withJSONObject: row), deadline: deadline)
    }

    func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        guard ["initialize", "thread/loaded/list", "thread/read", "thread/backgroundTerminals/list"].contains(method) else {
            throw AIProtectionError.failed(L10n.text("The status observer cannot call Codex methods that change sessions."))
        }
        nextID += 1
        let id = nextID
        let deadline = Date().addingTimeInterval(2)
        try send(["id": id, "method": method, "params": params], deadline: deadline)
        while Date() < deadline {
            let data = try transport.receive(deadline: deadline)
            guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AIProtectionError.failed(L10n.text("The Codex status API returned an invalid message."))
            }
            // 其他会话的通知不参与判定，不保存其内容，也不响应审批。
            guard (row["id"] as? NSNumber)?.intValue == id else { continue }
            if let error = row["error"] as? [String: Any] {
                let code = (error["code"] as? NSNumber)?.stringValue ?? "unknown"
                throw AIProtectionError.failed(L10n.text("Codex status method %@ returned an error (%@).", String(describing: method), String(describing: code)))
            }
            guard let result = row["result"] as? [String: Any] else {
                throw AIProtectionError.failed(L10n.text("Codex status method %@ returned no result.", String(describing: method)))
            }
            return result
        }
        throw AIProtectionError.failed(L10n.text("Reading Codex status method %@ timed out.", String(describing: method)))
    }
}
