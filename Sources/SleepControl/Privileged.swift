import Foundation

enum PrivilegedError: LocalizedError {
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return L10n.text("Authorization was cancelled.")
        case .failed(let message): return message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// 首次修改时自动配置免密规则，之后通过非交互 sudo 执行 pmset。
enum Privileged {
    static let pmsetPath = "/usr/bin/pmset"
    static let sudoersFile = "/etc/sudoers.d/lidcontrol"

    static func runPmset(_ arguments: [String]) throws {
        try preparePasswordlessAccess()
        try runPmsetWithoutPrompt(arguments)
    }

    static func preparePasswordlessAccess() throws {
        // 忽略临时凭据缓存，确保权限在重启和缓存过期后仍然有效。
        let probe = Shell.run("/usr/bin/sudo", ["-n", "-k", pmsetPath, "-g"])
        if probe.status != 0 {
            try installPasswordlessRule()
        }
    }

    /// 后台与钩子不能弹出授权框，缺少权限时返回可见错误。
    static func runPmsetWithoutPrompt(_ arguments: [String]) throws {
        let result = Shell.run("/usr/bin/sudo", ["-n", "-k", pmsetPath] + arguments, timeout: 2)
        guard result.status == 0 else {
            throw PrivilegedError.failed(L10n.text("Unable to change settings: %@", String(describing: result.output)))
        }
    }

    /// 安装 sudoers 规则：当前用户可免密执行 /usr/bin/pmset。写入前用 visudo 校验。
    private static func installPasswordlessRule() throws {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw PrivilegedError.failed(L10n.text("The username contains special characters, so a sudoers rule could not be created."))
        }
        let rule = "\(user) ALL=(root) NOPASSWD: \(pmsetPath)"
        let command = """
        set -eu
        umask 077
        rule_dir=$(/usr/bin/mktemp -d /private/tmp/sleepcontrol.sudoers.XXXXXX)
        trap '/bin/rm -rf "$rule_dir"' EXIT
        printf '%s\\n' '\(rule)' > "$rule_dir/rule"
        /usr/sbin/visudo -cf "$rule_dir/rule"
        /usr/bin/install -d -m 0755 -o root -g wheel /etc/sudoers.d
        /usr/bin/install -m 0440 -o root -g wheel "$rule_dir/rule" \(sudoersFile)
        """
        try runAsAdmin(command)
    }

    /// 通过 osascript 的 `with administrator privileges` 弹出系统授权框执行命令。
    private static func runAsAdmin(_ command: String) throws {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let result = Shell.run("/usr/bin/osascript", ["-e", script])
        if result.status == 0 { return }
        if result.output.contains("-128") {
            throw PrivilegedError.cancelled
        }
        throw PrivilegedError.failed(result.output)
    }
}
