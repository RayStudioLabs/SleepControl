import Foundation

enum AITaskPhase: String, Codable {
    case active, waiting
}

struct AITask: Codable, Equatable {
    var source: String
    var session: String
    var branch: String
    var turn: String?
    var phase: AITaskPhase
    var ownerPID: Int32?
    var updated: Date
    var toolName: String?
}

/// 只接收生命周期元数据；不保存提示词、回复或工具参数。
struct AIEvent {
    let source: String
    let name: String
    let session: String
    let turn: String?
    let agent: String?
    let tool: String
    let toolID: String?
    let notification: String
    let background: [(String, Bool)]?

    init(source: String, payload: [String: Any]) throws {
        guard ["codex", "claude"].contains(source),
              let name = payload["hook_event_name"] as? String,
              let session = payload["session_id"] as? String,
              !session.isEmpty, session.count < 256 else {
            throw AIProtectionError.invalidEvent
        }
        self.source = source
        self.name = name
        self.session = session
        turn = payload["turn_id"] as? String
        agent = payload["agent_id"] as? String
        tool = payload["tool_name"] as? String ?? ""
        toolID = payload["tool_use_id"] as? String
        notification = payload["notification_type"] as? String ?? ""
        background = (payload["background_tasks"] as? [[String: Any]])?.compactMap {
            guard let id = $0["id"] as? String else { return nil }
            let status = ($0["status"] as? String ?? "running").lowercased()
            return (id, !["completed", "failed", "cancelled", "killed"].contains(status))
        }
    }

    var asksUser: Bool {
        let name = tool.lowercased().split(separator: "__").last.map(String.init) ?? tool.lowercased()
        return ["askuserquestion", "exitplanmode", "request_user_input"].contains(name)
    }
}

struct AITaskRegistry: Codable, Equatable {
    var tasks: [String: AITask] = [:]
    var lastEvent: Date?
    var seenSources: Set<String> = []
    var endedBranches: [String: String] = [:]
    var runtimeSessions: [String: Set<String>] = [:]

    var activeCount: Int { tasks.values.filter { $0.phase == .active }.count }
    var waitingCount: Int { tasks.values.filter { $0.phase == .waiting }.count }
    var activeSources: String {
        ["codex", "claude"].compactMap { source in
            let count = tasks.values.filter { $0.source == source && $0.phase == .active }.count
            return count > 0 ? "\(source == "codex" ? "Codex" : "Claude") \(count)" : nil
        }.joined(separator: " · ")
    }

    mutating func receive(_ event: AIEvent, ownerPID: Int32?, now: Date = Date()) {
        let prefix = event.source + ":" + event.session + ":"
        // SubagentStart/Stop 的 agent_id 表示子代理，其余事件为事件所属分支。
        let branch = event.agent.map { "agent:" + $0 } ?? "main"
        let key = prefix + branch
        lastEvent = now
        seenSources.insert(event.source)

        func record(_ phase: AITaskPhase, branch: String, turn: String?) -> AITask {
            AITask(source: event.source, session: event.session, branch: branch,
                   turn: turn, phase: phase, ownerPID: ownerPID, updated: now,
                   toolName: event.tool.isEmpty ? nil : event.tool)
        }
        func matchesTurn(_ task: AITask) -> Bool {
            event.turn == nil || task.turn == nil || event.turn == task.turn
        }

        switch event.name {
        case "SessionStart":
            // 打开会话本身不提供保护。
            break
        case "SessionEnd":
            tasks = tasks.filter { !$0.key.hasPrefix(prefix) }
            endedBranches = endedBranches.filter { !$0.key.hasPrefix(prefix) }
        case "UserPromptSubmit", "SubagentStart", "PreCompact", "PostCompact", "ToolExecutionStart":
            endedBranches.removeValue(forKey: key)
            if event.name == "UserPromptSubmit" {
                tasks = tasks.filter { !$0.key.hasPrefix(prefix + branch + "/tool:") }
            }
            tasks[key] = record(.active, branch: branch, turn: event.turn)
        case "PreToolUse":
            endedBranches.removeValue(forKey: key)
            // 同一轮的并行工具分别记录，等待一个工具不会抹去其他执行分支。
            let toolBranch = branch + "/tool:" + (event.toolID ?? event.tool)
            tasks[prefix + toolBranch] = record(event.asksUser ? .waiting : .active,
                                               branch: toolBranch, turn: event.turn)
            tasks.removeValue(forKey: key)
        case "PermissionRequest":
            // 申请可能被另一个钩子自动处理，不能据此认定用户正在等待。
            // Codex 的 waitingOnApproval 由只读运行时快照确认。
            break
        case "Notification":
            if ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog"].contains(event.notification) {
                for id in Array(tasks.keys) where id.hasPrefix(prefix) && tasks[id]?.branch == branch {
                    tasks[id]?.phase = .waiting
                    tasks[id]?.updated = now
                }
                // 无调用标识时只影响最近的请求，不抹去其他并行工作。
                let candidates = tasks.filter { $0.key.hasPrefix(prefix + branch + "/tool:") }
                if !candidates.values.contains(where: { $0.phase == .waiting }),
                   let latest = candidates.max(by: { $0.value.updated < $1.value.updated })?.key {
                    tasks[latest]?.phase = .waiting
                    tasks[latest]?.updated = now
                }
                if !tasks.keys.contains(where: { $0.hasPrefix(prefix + branch) }) {
                    tasks[key] = record(.waiting, branch: branch, turn: event.turn)
                }
            }
        case "PostToolUse", "PostToolUseFailure":
            let toolBranch = branch + "/tool:" + (event.toolID ?? event.tool)
            if let old = tasks[prefix + toolBranch], !matchesTurn(old) { break }
            tasks.removeValue(forKey: prefix + toolBranch)
            if let ended = endedBranches[key], ended == (event.turn ?? "") { break }
            // 迟到的工具结果不能重新激活已经结束或开始了下一轮的主分支。
            if let current = tasks[key], !matchesTurn(current) { break }
            if !tasks.keys.contains(where: { $0.hasPrefix(prefix + branch + "/tool:") }) {
                tasks[key] = record(.active, branch: branch, turn: event.turn)
            }
        case "Stop", "StopFailure", "Interrupt", "SubagentStop":
            if let old = tasks[key], !matchesTurn(old) { break }
            tasks.removeValue(forKey: key)
            endedBranches[key] = event.turn ?? ""
            // 工具仍在运行时保留它；实际 PostToolUse 才结束该工具。
            if event.name == "StopFailure" || event.name == "Interrupt" {
                tasks = tasks.filter { !($0.key.hasPrefix(prefix + branch + "/tool:") && matchesTurn($0.value)) }
            }
        default:
            break
        }

        if let background = event.background {
            let bgPrefix = prefix + "background:"
            tasks = tasks.filter { !$0.key.hasPrefix(bgPrefix) }
            for (id, running) in background where running {
                let bgBranch = "background:" + id
                tasks[prefix + bgBranch] = record(.active, branch: bgBranch, turn: event.turn)
            }
        }
    }

    mutating func removeDeadOwners(isAlive: (Int32) -> Bool) {
        tasks = tasks.filter { _, task in task.ownerPID.map(isAlive) ?? true }
    }

    mutating func apply(_ snapshot: AIRuntimeSnapshot) {
        let previous = runtimeSessions[snapshot.source] ?? []
        let current = Set(snapshot.sessions.keys)
        for session in previous.union(current) {
            let prefix = snapshot.source + ":" + session + ":"
            // 快照开始读取后收到的新钩子优先，下一轮快照再校准。
            if tasks.contains(where: { $0.key.hasPrefix(prefix) && $0.value.updated > snapshot.startedAt }) { continue }
            let row = snapshot.sessions[session]
            if snapshot.source == "codex" {
                tasks = tasks.filter { !$0.key.hasPrefix(prefix) }
            } else {
                let main = prefix + "main"
                if let pid = row?.ownerPID {
                    for key in Array(tasks.keys) where key.hasPrefix(prefix) {
                        tasks[key]?.ownerPID = pid
                    }
                }
                tasks.removeValue(forKey: main)
                if row?.phase == nil {
                    tasks = tasks.filter { !$0.key.hasPrefix(main + "/tool:") }
                } else if row?.phase == .active {
                    for key in Array(tasks.keys) where key.hasPrefix(main + "/tool:") {
                        tasks[key]?.phase = .active
                    }
                } else {
                    // 客户端确认正在等待，最近的待审批请求不再提供保护。
                    let tools = tasks.filter { $0.key.hasPrefix(main + "/tool:") }
                    if !tools.values.contains(where: { $0.phase == .waiting }),
                       let latest = tools.max(by: { $0.value.updated < $1.value.updated })?.key {
                        tasks[latest]?.phase = .waiting
                    }
                }
            }
            guard let row else { continue }
            if let phase = row.phase {
                tasks[prefix + "main"] = AITask(source: snapshot.source, session: session, branch: "main",
                    turn: nil, phase: phase, ownerPID: row.ownerPID, updated: snapshot.startedAt)
            }
            for id in row.backgroundIDs {
                let branch = "runtime-background:" + id
                tasks[prefix + branch] = AITask(source: snapshot.source, session: session, branch: branch,
                    turn: nil, phase: .active, ownerPID: row.ownerPID, updated: snapshot.startedAt)
            }
        }
        runtimeSessions[snapshot.source] = current
    }
}

enum AIProtectionError: LocalizedError {
    case invalidEvent
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .invalidEvent: return L10n.text("The AI task event was not recognized.")
        case .failed(let message): return message
        }
    }
}
