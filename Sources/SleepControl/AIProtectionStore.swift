import Foundation
import Darwin

struct AIProtectionState: Codable {
    var version = 1
    var enabled = false
    var suspended = true
    var manualSleepDisabled = false
    var ownerPID: Int32 = 0
    var registry = AITaskRegistry()
    var appliedProtection = false
    var ownsSleepSetting = false
    var releaseAfter: Date?
    var deferredLidSleep = false
    var lastError: String?
    var runtimeWarning: String?
    var guardPID: Int32?
    var updated = Date()

    var protecting: Bool { enabled && !suspended && registry.activeCount > 0 }
}

/// UI、钩子与监护进程通过同一把跨进程锁协调，写入采用原子替换。
final class AIProtectionStore {
    let directory: URL
    // 沿用状态目录和锁，新旧会话中的助手继续共享同一份任务状态。
    var helper: URL { directory.appendingPathComponent("SleepControlHelper") }
    private var stateURL: URL { directory.appendingPathComponent("state.json") }

    init(directory: URL = (ProcessInfo.processInfo.environment["SLEEPCONTROL_STATE_DIRECTORY"]
        ?? ProcessInfo.processInfo.environment["LIDCONTROL_STATE_DIRECTORY"])
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LidControl/AI", isDirectory: true)) {
        self.directory = directory
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }

    func withState<T>(_ body: (inout AIProtectionState) throws -> T) throws -> T {
        try prepare()
        let fd = open(directory.appendingPathComponent("state.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AIProtectionError.failed(L10n.text("Unable to open the AI state lock.")) }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(5)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else { throw AIProtectionError.failed(L10n.text("AI status is being updated. Please try again shortly.")) }
            usleep(10_000)
        }
        defer { flock(fd, LOCK_UN) }

        var state: AIProtectionState
        if FileManager.default.fileExists(atPath: stateURL.path) {
            // 损坏时报告错误，不以空任务集合覆盖旧记录。
            state = try JSONDecoder().decode(AIProtectionState.self, from: Data(contentsOf: stateURL))
        } else {
            state = AIProtectionState()
        }
        let result = try body(&state)
        state.updated = Date()
        try checkpoint(state)
        return result
    }

    /// 仅在 withState 的锁内调用；在改变全局电源设置前保存接管信息。
    func checkpoint(_ state: AIProtectionState) throws {
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    func snapshot() throws -> AIProtectionState {
        // 读者读取原子快照，不必等待正在执行电源命令的写者。
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return AIProtectionState() }
        return try JSONDecoder().decode(AIProtectionState.self, from: Data(contentsOf: stateURL))
    }
}

enum AIProcess {
    static func isAlive(_ pid: Int32) -> Bool {
        pid > 1 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    static func parent(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    static func executable(of pid: Int32) -> String? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return String(cString: path)
    }

    static func owner(source: String) -> Int32? {
        var pid = getppid()
        for _ in 0..<16 {
            guard pid > 1 else { break }
            let name = executable(of: pid)?.lowercased() ?? ""
            if !name.contains("sleepcontrol"), !name.contains("lidcontrol"), name.contains(source) { return pid }
            guard let next = parent(of: pid), next != pid else { break }
            pid = next
        }
        return nil
    }
}
