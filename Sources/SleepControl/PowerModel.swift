import AppKit
import Foundation
import ServiceManagement

@MainActor
final class PowerModel: ObservableObject {
    @Published private(set) var state = PowerState()
    @Published private(set) var manualSleepDisabled = false
    @Published private(set) var aiEnabled = false
    @Published private(set) var aiStatus = L10n.text("Reading task status…")
    @Published private(set) var aiSetupMessage: String?
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published var errorMessage: String?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    static let displaySleepChoices = [1, 2, 5, 10, 15, 30, 60, 0]
    private let store = AIProtectionStore()
    private var monitor: Timer?
    private var reading = false
    private var ticks = 0

    init() {
        Task { await initialize() }
        monitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
    }

    static func label(forMinutes minutes: Int) -> String {
        switch minutes {
        case 0: return L10n.text("Never")
        case 1: return L10n.text("1 minute")
        case 60: return L10n.text("1 hour")
        default: return L10n.text("%@ minutes", String(describing: minutes))
        }
    }

    private func initialize() async {
        busy = true
        let store = store
        let executable = Bundle.main.executableURL
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let power = try PowerState.checkedRead()
                let previous = try store.snapshot()
                var integrationError: String?
                if previous.enabled, let executable {
                    // 已开启功能的用户升级后自动更新助手及旧名称钩子。
                    do {
                        try AIIntegration.install(store: store, executable: executable,
                                                  environment: ProcessInfo.processInfo.environment)
                    } catch {
                        // 更新失败也保持面板可用，允许用户关闭保护或重试。
                        integrationError = L10n.text("Unable to update AI hooks: %@", String(describing: error.localizedDescription))
                    }
                }
                let sync = previous.enabled ? AIRuntimeInitialSync.read() : ([], nil)
                try AIProtectionEngine(store: store).attach(ownerPID: getpid(), snapshots: sync.0, runtimeWarning: sync.1)
                if (try store.snapshot()).enabled {
                    do { try AIGuard.start(store: store) }
                    catch { try store.withState { $0.lastError = error.localizedDescription } }
                }
                return (power, try store.snapshot(), integrationError)
            }.value
            state = result.0
            display(result.1)
            errorMessage = result.2
            loaded = true
        } catch {
            errorMessage = error.localizedDescription
            aiStatus = L10n.text("Task detection has not started")
        }
        busy = false
    }

    func refresh() async {
        guard loaded else {
            if !busy { await initialize() }
            return
        }
        let store = store
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let power = try store.withState { snapshot -> PowerState in
                    let power = try PowerState.checkedRead()
                    if !snapshot.ownsSleepSetting && !snapshot.protecting {
                        snapshot.manualSleepDisabled = power.sleepDisabled
                    }
                    return power
                }
                let snapshot = try store.snapshot()
                if snapshot.enabled && !(snapshot.guardPID.map(AIProcess.isAlive) ?? false) {
                    try AIGuard.start(store: store)
                }
                return (power, snapshot)
            }.value
            state = result.0
            display(result.1)
        } catch { errorMessage = error.localizedDescription }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func poll() async {
        guard loaded, !busy, !reading else { return }
        reading = true
        defer { reading = false }
        ticks += 1
        if ticks % 10 == 0 {
            await refresh()
        } else {
            do { display(try store.snapshot()) }
            catch { aiStatus = L10n.text("Unable to read task status"); errorMessage = error.localizedDescription }
        }
    }

    private func display(_ snapshot: AIProtectionState) {
        manualSleepDisabled = snapshot.manualSleepDisabled
        aiEnabled = snapshot.enabled
        if !snapshot.enabled {
            aiStatus = L10n.text("Off · Using the first two switches")
            aiSetupMessage = nil
        } else if let error = snapshot.lastError {
            aiStatus = L10n.text("AI sleep protection error: %@", String(describing: error))
        } else if snapshot.runtimeWarning != nil {
            aiStatus = L10n.text("Some task statuses are unknown · Check the connection")
        } else if snapshot.manualSleepDisabled {
            aiStatus = L10n.text("Your current settings already prevent sleep")
        } else if snapshot.registry.activeCount > 0 {
            aiStatus = L10n.text("Keeping your Mac awake · %@", String(describing: snapshot.registry.activeSources))
        } else if snapshot.releaseAfter != nil {
            aiStatus = L10n.text("Checking whether your Mac can sleep…")
        } else if snapshot.registry.waitingCount > 0 {
            aiStatus = L10n.text("Waiting for you · Using your usual sleep settings")
        } else {
            aiStatus = L10n.text("No running AI tasks · Using your usual sleep settings")
        }
        if snapshot.enabled {
            let missing = ["codex", "claude"].filter { !snapshot.registry.seenSources.contains($0) }
            aiSetupMessage = missing.isEmpty ? nil
                : L10n.text("No task events have been received from %@ yet. Reopen a conversation after the initial setup. For Codex, trust the sleepcontrol-ai-observer hooks in /hooks.", String(describing: missing.map { $0 == "codex" ? "Codex" : "Claude Code" }.joined(separator: L10n.text("List separator"))))
            if let warning = snapshot.runtimeWarning {
                aiSetupMessage = warning + L10n.text(". Only the last confirmed task status is available. Check the connection to your AI app.")
            }
        }
    }

    func setLidKeepAwake(_ on: Bool) {
        let store = store
        perform {
            try Privileged.preparePasswordlessAccess()
            try AIProtectionEngine(store: store).setManualSleepDisabled(on)
        }
    }

    func setAIEnabled(_ on: Bool) {
        let store = store
        guard let executable = Bundle.main.executableURL else { return }
        perform {
            if on {
                try Privileged.preparePasswordlessAccess()
                try AIIntegration.install(store: store, executable: executable,
                                          environment: ProcessInfo.processInfo.environment)
            }
            let engine = AIProtectionEngine(store: store)
            let sync = on ? AIRuntimeInitialSync.read() : ([], nil)
            try engine.setEnabled(on, snapshots: sync.0, runtimeWarning: sync.1)
            if on {
                do { try AIGuard.start(store: store) }
                catch { try? engine.setEnabled(false); throw error }
            }
        }
    }

    func setPreventACSleep(_ on: Bool) {
        apply(["-c", "sleep", on ? "0" : "1"])
    }

    func setACDisplaySleep(_ minutes: Int) {
        guard minutes >= 0 else { return }
        apply(["-c", "displaysleep", String(minutes)])
    }

    func setBatteryDisplaySleep(_ minutes: Int) {
        guard minutes >= 0 else { return }
        apply(["-b", "displaysleep", String(minutes)])
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            errorMessage = nil
        } catch { errorMessage = L10n.text("Unable to change launch at login: %@", String(describing: error.localizedDescription)) }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func quit() {
        guard !busy else { return }
        busy = true
        let store = store
        Task {
            do {
                try await Task.detached { try AIProtectionEngine(store: store).detach(ownerPID: getpid()) }.value
                NSApplication.shared.terminate(nil)
            } catch {
                errorMessage = L10n.text("SleepControl could not restore your sleep settings and has not quit: %@", String(describing: error.localizedDescription))
                busy = false
            }
        }
    }

    private func apply(_ arguments: [String]) {
        perform { try Privileged.runPmset(arguments) }
    }

    private func perform(_ work: @escaping @Sendable () throws -> Void) {
        guard loaded, !busy else { return }
        busy = true
        errorMessage = nil
        Task {
            do { try await Task.detached(priority: .userInitiated) { try work() }.value }
            catch { errorMessage = error.localizedDescription }
            await refresh()
            busy = false
        }
    }
}
