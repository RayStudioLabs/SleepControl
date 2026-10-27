import Foundation
import IOKit
import CoreGraphics
import Darwin

struct AISystemContext {
    var sleepDisabled: Bool
    var lidClosed: Bool?
    var onACPower: Bool
    var externalDisplay: Bool
    var isPortable: Bool

    var lidWouldSleep: Bool {
        isPortable && lidClosed == true && !(onACPower && externalDisplay)
    }
}

protocol AIPowerDriver {
    func context() throws -> AISystemContext
    func setSleepDisabled(_ disabled: Bool) throws
    func sleepNow() throws
}

struct MacAIPowerDriver: AIPowerDriver {
    func context() throws -> AISystemContext {
        let state = try PowerState.checkedRead()
        let battery = BatteryInfo.read()
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        var closed: Bool?
        if root != 0 {
            closed = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString,
                                                     kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
            IOObjectRelease(root)
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success else {
            throw AIProtectionError.failed(L10n.text("Unable to read display status. Automatic sleep on lid close has been paused."))
        }
        let external = displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
        return AISystemContext(sleepDisabled: state.sleepDisabled, lidClosed: closed,
            onACPower: battery.hasBattery ? battery.onACPower : true,
            externalDisplay: external, isPortable: battery.hasBattery)
    }

    func setSleepDisabled(_ disabled: Bool) throws {
        try Privileged.runPmsetWithoutPrompt(["-a", "disablesleep", disabled ? "1" : "0"])
    }

    func sleepNow() throws { try Privileged.runPmsetWithoutPrompt(["sleepnow"]) }
}

/// 短暂的稳定窗口用于合并一轮结束、下一轮自动续跑和乱序回调。
struct AIProtectionEngine {
    let store: AIProtectionStore
    var driver: AIPowerDriver = MacAIPowerDriver()
    var isAlive: (Int32) -> Bool = AIProcess.isAlive
    var settlingTime: TimeInterval = 2

    func attach(ownerPID: Int32, snapshots: [AIRuntimeSnapshot] = [], runtimeWarning: String? = nil) throws {
        let context = try driver.context()
        try store.withState { state in
            if state.ownerPID != ownerPID && isAlive(state.ownerPID) {
                throw AIProtectionError.failed(L10n.text("SleepControl is already running in another process."))
            }
            // 临时保护仍在时，不能把系统实际值当作用户手动选择。
            if !state.ownsSleepSetting { state.manualSleepDisabled = context.sleepDisabled }
            state.ownerPID = ownerPID
            state.suspended = false
            for snapshot in snapshots { state.registry.apply(snapshot) }
            state.runtimeWarning = runtimeWarning
            state.registry.removeDeadOwners(isAlive: isAlive)
            do {
                try reconcile(&state, context: context, now: Date(), allowSleepRequest: false)
            } catch {
                state.lastError = error.localizedDescription
            }
        }
    }

    func receive(_ event: AIEvent, ownerPID: Int32?) throws {
        try store.withState { state in
            if state.enabled && !state.suspended && !state.ownsSleepSetting && !state.protecting {
                state.manualSleepDisabled = try driver.context().sleepDisabled
            }
            state.registry.receive(event, ownerPID: ownerPID)
            try store.checkpoint(state)
            guard state.enabled && !state.suspended else { return }
            try update(&state, now: Date())
        }
    }

    func tick(now: Date = Date(), snapshots: [AIRuntimeSnapshot] = [], runtimeWarning: String? = nil) throws {
        try store.withState { state in
            // 没有接管电源时，尊重系统或其他程序对原有全局设置的修改。
            if !state.ownsSleepSetting && !state.protecting {
                state.manualSleepDisabled = try driver.context().sleepDisabled
            }
            for snapshot in snapshots { state.registry.apply(snapshot) }
            state.runtimeWarning = runtimeWarning
            try update(&state, now: now)
        }
    }

    func setEnabled(_ on: Bool, snapshots: [AIRuntimeSnapshot] = [], runtimeWarning: String? = nil) throws {
        try store.withState { state in
            if on && !state.ownsSleepSetting {
                state.manualSleepDisabled = try driver.context().sleepDisabled
            }
            state.enabled = on
            state.suspended = false
            state.releaseAfter = nil
            for snapshot in snapshots { state.registry.apply(snapshot) }
            state.runtimeWarning = runtimeWarning
            try update(&state, now: Date())
        }
    }

    func setManualSleepDisabled(_ on: Bool) throws {
        try store.withState { state in
            state.manualSleepDisabled = on
            try update(&state, now: Date())
        }
    }

    func detach(ownerPID: Int32? = nil) throws {
        try store.withState { state in
            if let ownerPID, state.ownerPID != ownerPID { return }
            state.suspended = true
            state.ownerPID = 0
            state.releaseAfter = nil
            state.deferredLidSleep = false
            try reconcile(&state, context: driver.context(), now: Date(), allowSleepRequest: false)
        }
    }

    private func update(_ state: inout AIProtectionState, now: Date) throws {
        state.registry.removeDeadOwners(isAlive: isAlive)
        if !isAlive(state.ownerPID) && state.registry.activeCount == 0 {
            state.suspended = true
        }
        do {
            try reconcile(&state, context: driver.context(), now: now, allowSleepRequest: true)
            state.lastError = nil
        } catch {
            // 即便电源命令失败，也保存新的任务状态与错误，不伪装成旧任务仍活跃。
            state.lastError = error.localizedDescription
        }
    }

    private func reconcile(_ state: inout AIProtectionState, context: AISystemContext,
                           now: Date, allowSleepRequest: Bool) throws {
        let active = state.protecting
        if !context.lidWouldSleep { state.deferredLidSleep = false }
        if state.appliedProtection && context.lidWouldSleep { state.deferredLidSleep = true }
        if active && !state.manualSleepDisabled {
            state.releaseAfter = nil
            if context.lidWouldSleep { state.deferredLidSleep = true }
        } else if state.appliedProtection && state.enabled && !state.suspended,
                  state.releaseAfter == nil {
            state.releaseAfter = now.addingTimeInterval(settlingTime)
        }
        let settling = state.enabled && !state.suspended && state.appliedProtection
            && (state.releaseAfter.map { now < $0 } ?? false)
        let unknownHold = state.enabled && !state.suspended && state.appliedProtection && state.runtimeWarning != nil
        let aiNeedsProtection = (active || settling || unknownHold) && !state.manualSleepDisabled
        let desired = state.manualSleepDisabled || aiNeedsProtection
        let shouldRequestSleep = allowSleepRequest && state.enabled && !state.suspended
            && !active && !settling && !state.manualSleepDisabled
            && state.deferredLidSleep && context.lidWouldSleep && state.runtimeWarning == nil

        if context.sleepDisabled != desired {
            // 先记录接管信息；命令之后进程被杀或系统直接睡下，仍可恢复原值。
            // 操作的完整结果由同一锁内的持久状态记录。
            state.ownsSleepSetting = state.ownsSleepSetting || aiNeedsProtection
            try store.checkpoint(state)
            try driver.setSleepDisabled(desired)
        }
        state.appliedProtection = aiNeedsProtection
        state.ownsSleepSetting = aiNeedsProtection
        if !aiNeedsProtection { state.releaseAfter = nil }
        if shouldRequestSleep {
            // 开盖、插电且外接显示器或新任务到达都会令前述条件失效。
            // 不主动重演闲置休眠；解除保护后由系统原有计时与其他应用的断言决定。
            state.deferredLidSleep = false
            try store.checkpoint(state)
            try driver.sleepNow()
        }
    }
}

enum AIGuard {
    static func start(store: AIProtectionStore) throws {
        guard FileManager.default.isExecutableFile(atPath: store.helper.path) else {
            throw AIProtectionError.failed(L10n.text("The AI event helper is missing. Turn the AI task switch off and back on to repair it."))
        }
        let process = Process()
        process.executableURL = store.helper
        process.arguments = ["--ai-guard"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static func run(store: AIProtectionStore) throws {
        try store.prepare()
        let fd = open(store.directory.appendingPathComponent("guard.lock").path,
                      O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AIProtectionError.failed(L10n.text("Unable to start the AI monitoring process.")) }
        defer { close(fd) }
        // 重复启动时仅保留一个监护进程。
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return }
        try store.withState { $0.guardPID = getpid() }
        defer {
            try? store.withState { state in
                if state.guardPID == getpid() { state.guardPID = nil }
            }
        }
        let engine = AIProtectionEngine(store: store)
        let codex = CodexRuntimeProbe()
        while true {
            // Command-line helpers have no AppKit event loop to drain autoreleased
            // Foundation objects. Release each polling cycle's temporary objects here.
            let keepRunning = autoreleasepool { () -> Bool in
                do {
                    let before = try store.snapshot()
                    if !before.enabled && !before.appliedProtection && !before.ownsSleepSetting { return false }
                    var snapshots: [AIRuntimeSnapshot] = []
                    var warnings: [String] = []
                    if before.enabled && !before.suspended {
                        do {
                            if let snapshot = try codex.read() { snapshots.append(snapshot) }
                            else if !(before.registry.runtimeSessions["codex"] ?? []).isEmpty {
                                warnings.append(L10n.text("The local Codex status connection was lost"))
                            }
                        } catch { warnings.append(error.localizedDescription) }
                        do { snapshots.append(try ClaudeRuntimeProbe.read(environment: ProcessInfo.processInfo.environment)) }
                        catch { warnings.append(error.localizedDescription) }
                    }
                    try engine.tick(snapshots: snapshots,
                        runtimeWarning: warnings.isEmpty ? nil : warnings.joined(separator: L10n.text("Warning separator")))
                    let state = try store.snapshot()
                    if state.suspended && !state.appliedProtection && !state.ownsSleepSetting { return false }
                } catch {
                    // 共享文件损坏时保留原文件与接管现场，不覆盖成空状态。
                    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                    return false
                }
                return true
            }
            guard keepRunning else { return }
            Thread.sleep(forTimeInterval: 1)
        }
    }
}
