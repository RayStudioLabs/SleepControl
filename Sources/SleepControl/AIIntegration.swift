import Foundation

enum AIIntegration {
    static let marker = "sleepcontrol-ai-observer"
    // 更新时同时清理旧名称，保留其他程序的钩子。
    private static let ownedMarkers = [marker, "lidcontrol-ai-observer"]
    static let codexEvents = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
                              "PermissionRequest", "PostToolUse", "Stop", "Interrupt",
                              "SubagentStart", "SubagentStop", "PreCompact", "PostCompact"]
    static let claudeEvents = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
                               "PostToolUse", "PostToolUseFailure", "Stop", "StopFailure",
                               "SubagentStart", "SubagentStop", "Notification", "PreCompact", "PostCompact"]

    static func command(helper: URL, source: String) -> String {
        // 固定标识用于只更新本应用的钩子，不碰其他钩子。
        let quoted = "'" + helper.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "exec \(quoted) --ai-event \(source) # \(marker)"
    }

    static func merged(_ data: Data?, source: String, helper: URL) throws -> Data {
        var root: [String: Any] = [:]
        if let data {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AIProtectionError.failed(L10n.text("The %@ configuration is invalid. The original file was not changed.", String(describing: source)))
            }
            root = parsed
        }
        if let old = root["hooks"], !(old is [String: Any]) {
            throw AIProtectionError.failed(L10n.text("The hooks configuration for %@ is invalid.", String(describing: source)))
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let events = source == "codex" ? codexEvents : claudeEvents
        // 旧版本本应用的钩子也一并更新，保留同组中其他程序的处理器。
        for event in Array(hooks.keys) {
            guard let groups = hooks[event] as? [[String: Any]] else {
                throw AIProtectionError.failed(L10n.text("The hook configuration for %@ (%@) is invalid.", String(describing: source), String(describing: event)))
            }
            hooks[event] = groups.compactMap { group -> [String: Any]? in
                var group = group
                guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                let kept = handlers.filter { handler in
                    guard let command = handler["command"] as? String else { return true }
                    return !ownedMarkers.contains(where: command.contains)
                }
                guard !kept.isEmpty else { return nil }
                group["hooks"] = kept
                return group
            }
        }
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            let timeout = ["SessionEnd", "Interrupt"].contains(event) ? 3 : 10
            var group: [String: Any] = ["hooks": [["type": "command",
                "command": command(helper: helper, source: source), "timeout": timeout]]]
            if ["PreToolUse", "PostToolUse", "PostToolUseFailure"].contains(event) {
                group["matcher"] = ".*"
            }
            if event == "Notification" {
                group["matcher"] = "permission_prompt|elicitation_dialog|elicitation_url_dialog"
            }
            groups.append(group)
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    static func install(store: AIProtectionStore, executable: URL,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        environment: [String: String] = [:]) throws {
        try store.prepare()
        let codex = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        let claude = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        let targets = [("codex", codex.appendingPathComponent("hooks.json")),
                       ("claude", claude.appendingPathComponent("settings.json"))]
        // 先解析全部配置，避免第二个文件有问题时只完成一半安装。
        let plans = try targets.map { source, url -> (URL, Data?, Data) in
            let old = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            return (url, old, try merged(old, source: source, helper: store.helper))
        }
        // The helper runs outside the app bundle, so deploy its language resources first.
        let resources = store.directory.appendingPathComponent(L10n.resourceBundleName)
        let stagedResources = store.directory.appendingPathComponent("resources-\(UUID().uuidString).bundle")
        defer { try? FileManager.default.removeItem(at: stagedResources) }
        try FileManager.default.copyItem(at: L10n.resourceBundle.bundleURL, to: stagedResources)
        if FileManager.default.fileExists(atPath: resources.path) {
            _ = try FileManager.default.replaceItemAt(resources, withItemAt: stagedResources)
        } else {
            try FileManager.default.moveItem(at: stagedResources, to: resources)
        }
        let staged = store.directory.appendingPathComponent("helper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: executable, to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staged.path)
        if FileManager.default.fileExists(atPath: store.helper.path) {
            _ = try FileManager.default.replaceItemAt(store.helper, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: store.helper)
        }
        // 保留已安装的 LidControlHelper，供尚未重载配置的旧会话继续上报。
        // 新配置统一指向 SleepControlHelper，两者使用相同状态文件和锁。
        var applied: [(URL, Data?)] = []
        do {
            for (url, old, data) in plans {
                guard old != data else { continue }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                if let old {
                    let backup = store.directory.appendingPathComponent("\(url.deletingLastPathComponent().lastPathComponent)-\(UUID().uuidString).backup.json")
                    try old.write(to: backup, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                }
                try data.write(to: url, options: .atomic)
                applied.append((url, old))
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        } catch {
            for (url, old) in applied.reversed() {
                if let old { try? old.write(to: url, options: .atomic) }
                else { try? FileManager.default.removeItem(at: url) }
            }
            throw error
        }
    }
}
