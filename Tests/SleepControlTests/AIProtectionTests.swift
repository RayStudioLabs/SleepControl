import Foundation
import XCTest
@testable import SleepControl

final class AIProtectionTests: XCTestCase {
    final class Driver: AIPowerDriver {
        var value = AISystemContext(sleepDisabled: false, lidClosed: false,
                                   onACPower: false, externalDisplay: false, isPortable: true)
        var commands: [String] = []
        var failure = false
        func context() throws -> AISystemContext { value }
        func setSleepDisabled(_ disabled: Bool) throws {
            if failure { throw AIProtectionError.failed("simulated failure") }
            commands.append(disabled ? "disable" : "restore")
            value.sleepDisabled = disabled
        }
        func sleepNow() throws { commands.append("sleep") }
    }

    var directory: URL!
    var store: AIProtectionStore!
    var driver: Driver!
    var engine: AIProtectionEngine!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = AIProtectionStore(directory: directory)
        driver = Driver()
        engine = AIProtectionEngine(store: store, driver: driver, isAlive: { $0 == 123 || $0 == 456 }, settlingTime: 0)
        try engine.attach(ownerPID: 123)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func event(_ name: String, source: String = "codex", session: String = "session",
               extra: [String: Any] = [:]) throws -> AIEvent {
        var json: [String: Any] = ["hook_event_name": name, "session_id": session, "turn_id": "turn"]
        extra.forEach { json[$0] = $1 }
        return try AIEvent(source: source, payload: json)
    }

    func receive(_ name: String, source: String = "codex", session: String = "session",
                 extra: [String: Any] = [:]) throws {
        try engine.receive(event(name, source: source, session: session, extra: extra), ownerPID: 456)
    }

    func testDisabledFeatureNeverProtectsTasks() throws {
        try receive("UserPromptSubmit")
        XCTAssertEqual(try store.snapshot().registry.activeCount, 1)
        XCTAssertTrue(driver.commands.isEmpty)
    }

    func testManualKeepAwakeWinsAfterLastTask() throws {
        try engine.setManualSleepDisabled(true)
        try engine.setEnabled(true)
        try receive("UserPromptSubmit")
        driver.value.lidClosed = true
        try receive("Stop")
        XCTAssertEqual(driver.commands, ["disable"])
        XCTAssertTrue(try store.snapshot().manualSleepDisabled)
    }

    func testClosedLidSleepsOnlyAfterAllSessionsFinish() throws {
        try engine.setEnabled(true)
        try receive("UserPromptSubmit")
        try receive("UserPromptSubmit", source: "claude", session: "other")
        driver.value.lidClosed = true
        try engine.tick()
        try receive("Stop")
        XCTAssertTrue(driver.value.sleepDisabled)
        XCTAssertFalse(driver.commands.contains("sleep"))
        try receive("Stop", source: "claude", session: "other")
        XCTAssertEqual(driver.commands, ["disable", "restore", "sleep"])
    }

    func testWaitingForQuestionDoesNotProtectAndAnswerResumes() throws {
        try engine.setEnabled(true)
        try receive("UserPromptSubmit")
        let question: [String: Any] = ["tool_name": "request_user_input", "tool_use_id": "question"]
        try receive("PreToolUse", extra: question)
        XCTAssertEqual(try store.snapshot().registry.activeCount, 0)
        XCTAssertEqual(try store.snapshot().registry.waitingCount, 1)
        XCTAssertFalse(driver.value.sleepDisabled)
        try receive("PostToolUse", extra: question)
        XCTAssertTrue(driver.value.sleepDisabled)
    }

    func testWaitingParentDoesNotHideActiveChild() throws {
        try engine.setEnabled(true)
        try receive("UserPromptSubmit")
        try receive("SubagentStart", extra: ["agent_id": "child"])
        try receive("PreToolUse", extra: ["tool_name": "request_user_input", "tool_use_id": "q"])
        XCTAssertEqual(try store.snapshot().registry.activeCount, 1)
        XCTAssertTrue(driver.value.sleepDisabled)
        try receive("SubagentStop", extra: ["agent_id": "child"])
        XCTAssertFalse(driver.value.sleepDisabled)
    }

    func testOpenLidBeforeCompletionCancelsDeferredSleep() throws {
        try engine.setEnabled(true)
        try receive("UserPromptSubmit")
        driver.value.lidClosed = true
        try engine.tick()
        driver.value.lidClosed = false
        try receive("Stop")
        XCTAssertEqual(driver.commands, ["disable", "restore"])
    }

    func testACExternalDisplayDoesNotForceClamshellSleep() throws {
        try engine.setEnabled(true)
        try receive("UserPromptSubmit")
        driver.value.lidClosed = true
        driver.value.onACPower = true
        driver.value.externalDisplay = true
        try receive("Stop")
        XCTAssertFalse(driver.commands.contains("sleep"))
    }

    func testDisablingFeatureRestoresOriginalWithoutSleepCommand() throws {
        try engine.setEnabled(true)
        try receive("UserPromptSubmit")
        driver.value.lidClosed = true
        try engine.tick()
        try engine.setEnabled(false)
        XCTAssertEqual(driver.commands, ["disable", "restore"])
    }

    func testNewTaskDuringSettlingCancelsSleep() throws {
        engine.settlingTime = 3
        try engine.setEnabled(true)
        try receive("UserPromptSubmit")
        driver.value.lidClosed = true
        try receive("Stop")
        XCTAssertEqual(driver.commands, ["disable"])
        try receive("UserPromptSubmit", session: "new")
        try engine.tick(now: Date().addingTimeInterval(10))
        XCTAssertEqual(driver.commands, ["disable"])
    }

    func testBackgroundTaskKeepsProtectionWhenMainStops() throws {
        try engine.setEnabled(true)
        try receive("UserPromptSubmit", source: "claude")
        try receive("Stop", source: "claude", extra: ["background_tasks": [["id": "job", "status": "running"]]])
        XCTAssertTrue(driver.value.sleepDisabled)
        XCTAssertEqual(try store.snapshot().registry.activeCount, 1)
        try receive("Stop", source: "claude", extra: ["background_tasks": []])
        XCTAssertFalse(driver.value.sleepDisabled)
    }

    func testDuplicateStartsAndStaleTurnEnd() throws {
        try engine.setEnabled(true)
        try receive("UserPromptSubmit")
        try receive("UserPromptSubmit")
        XCTAssertEqual(try store.snapshot().registry.activeCount, 1)
        try receive("UserPromptSubmit", extra: ["turn_id": "new-turn"])
        try receive("Stop")
        XCTAssertEqual(try store.snapshot().registry.activeCount, 1)
    }

    func testDeadOwnerPrunedButNoSilentExpiryOfLongTask() throws {
        try engine.setEnabled(true)
        try receive("UserPromptSubmit")
        try engine.tick(now: Date().addingTimeInterval(86400))
        XCTAssertEqual(try store.snapshot().registry.activeCount, 1)
        engine.isAlive = { $0 == 123 }
        try engine.tick()
        XCTAssertEqual(try store.snapshot().registry.activeCount, 0)
        XCTAssertFalse(driver.value.sleepDisabled)
    }

    func testCrashRecoveryDoesNotAdoptTemporaryProtectionAsManual() throws {
        try engine.setEnabled(true)
        try receive("UserPromptSubmit")
        XCTAssertTrue(driver.value.sleepDisabled)
        engine.isAlive = { $0 == 456 }
        try engine.attach(ownerPID: 789)
        XCTAssertFalse(try store.snapshot().manualSleepDisabled)
    }

    func testErrorRecordedWithoutLosingTask() throws {
        try engine.setEnabled(true)
        driver.failure = true
        try receive("UserPromptSubmit")
        let snapshot = try store.snapshot()
        XCTAssertEqual(snapshot.registry.activeCount, 1)
        XCTAssertNotNil(snapshot.lastError)
        XCTAssertFalse(driver.commands.contains("sleep"))
    }

    func testMalformedStateIsNotOverwrittenOrSlept() throws {
        let file = directory.appendingPathComponent("state.json")
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try engine.tick())
        XCTAssertEqual(try String(contentsOf: file), "broken")
        XCTAssertTrue(driver.commands.isEmpty)
    }

    func testValidatedPowerParsingRejectsUnknownState() throws {
        XCTAssertThrowsError(try PowerState.parse(general: "command failed", custom: ""))
        let state = try PowerState.parse(general: "SleepDisabled 1", custom: "AC Power:\n sleep 0\n displaysleep 10\nBattery Power:\n displaysleep 2")
        XCTAssertTrue(state.sleepDisabled)
        XCTAssertTrue(state.preventsACSleep)
    }

    func testPermissionRequestAloneDoesNotMistakeAutoApprovalForWaiting() throws {
        try engine.setEnabled(true)
        try receive("UserPromptSubmit")
        try receive("PreToolUse", extra: ["tool_name": "Bash", "tool_use_id": "tool"])
        try receive("PermissionRequest", extra: ["tool_name": "Bash"])
        XCTAssertTrue(driver.value.sleepDisabled)
        XCTAssertGreaterThan(try store.snapshot().registry.activeCount, 0)
        let snapshot = AIRuntimeSnapshot(source: "codex", startedAt: Date(),
            sessions: ["session": AIRuntimeSession(phase: .waiting, ownerPID: 456)])
        try engine.tick(snapshots: [snapshot])
        XCTAssertFalse(driver.value.sleepDisabled)
        XCTAssertEqual(try store.snapshot().registry.activeCount, 0)
        let resumed = AIRuntimeSnapshot(source: "codex", startedAt: Date(),
            sessions: ["session": AIRuntimeSession(phase: .active, ownerPID: 456)])
        try engine.tick(snapshots: [resumed])
        XCTAssertTrue(driver.value.sleepDisabled)
    }

    func testMonitoringLossKeepsExistingProtectionAndDoesNotRequestSleep() throws {
        try engine.setEnabled(true)
        try receive("UserPromptSubmit")
        driver.value.lidClosed = true
        try engine.tick()
        try store.withState { $0.registry.tasks.removeAll() }
        try engine.tick(runtimeWarning: "offline")
        XCTAssertTrue(driver.value.sleepDisabled)
        XCTAssertFalse(driver.commands.contains("sleep"))
        try engine.setEnabled(false)
        XCTAssertFalse(driver.value.sleepDisabled)
    }

    func testLateToolResultDoesNotResurrectCompletedTurn() throws {
        try engine.setEnabled(true)
        try receive("PreToolUse", extra: ["tool_name": "Bash", "tool_use_id": "tool"])
        try receive("Stop")
        try receive("PostToolUse", extra: ["tool_name": "Bash", "tool_use_id": "tool"])
        XCTAssertEqual(try store.snapshot().registry.activeCount, 0)
        XCTAssertFalse(driver.value.sleepDisabled)
    }

    func testParallelWaitingToolDoesNotBecomeActiveWhenOtherToolCompletes() throws {
        try engine.setEnabled(true)
        try receive("PreToolUse", extra: ["tool_name": "request_user_input", "tool_use_id": "q"])
        try receive("PreToolUse", extra: ["tool_name": "Bash", "tool_use_id": "b"])
        try receive("PostToolUse", extra: ["tool_name": "Bash", "tool_use_id": "b"])
        XCTAssertEqual(try store.snapshot().registry.activeCount, 0)
        XCTAssertEqual(try store.snapshot().registry.waitingCount, 1)
    }

    func testInitialSyncProtectsAlreadyRunningTask() throws {
        let snapshot = AIRuntimeSnapshot(source: "codex", startedAt: Date(),
            sessions: ["already-running": AIRuntimeSession(phase: .active, ownerPID: 456)])
        try engine.setEnabled(true, snapshots: [snapshot])
        XCTAssertTrue(driver.value.sleepDisabled)
    }

    func testDetachRestoresBaselineEvenWithActiveTask() throws {
        try engine.setEnabled(true)
        try receive("UserPromptSubmit")
        try engine.detach()
        XCTAssertFalse(driver.value.sleepDisabled)
        XCTAssertTrue(try store.snapshot().suspended)
        XCTAssertFalse(driver.commands.contains("sleep"))
    }

    func testSecondAppCannotReleaseFirstAppsProtectionOnExit() throws {
        try engine.setEnabled(true)
        try receive("UserPromptSubmit")
        try engine.detach(ownerPID: 999)
        XCTAssertTrue(driver.value.sleepDisabled)
        XCTAssertFalse(try store.snapshot().suspended)
        XCTAssertEqual(try store.snapshot().ownerPID, 123)
    }
}
