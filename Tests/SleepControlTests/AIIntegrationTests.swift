import Foundation
import XCTest
@testable import SleepControl

final class AIIntegrationTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testInstallerPreservesExistingSettingsAndIsIdempotent() throws {
        let helper = directory.appendingPathComponent("a path's helper")
        let original = Data("""
        {"model":"existing-model","hooks":{"Stop":[{"matcher":".*","hooks":[{"type":"command","command":"notify-existing"}]}]}}
        """.utf8)
        let first = try AIIntegration.merged(original, source: "claude", helper: helper)
        let second = try AIIntegration.merged(first, source: "claude", helper: helper)
        XCTAssertEqual(first, second)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "existing-model")
        let hooks = try XCTUnwrap(root["hooks"] as? [String: [[String: Any]]])
        let stop = try XCTUnwrap(hooks["Stop"])
        XCTAssertEqual(stop.count, 2)
        XCTAssertEqual((stop[0]["hooks"] as? [[String: Any]])?[0]["command"] as? String, "notify-existing")
        let command = AIIntegration.command(helper: helper, source: "claude")
        XCTAssertTrue(command.contains("'\\''"))
        let result = Shell.run("/bin/sh", ["-n", "-c", command])
        XCTAssertEqual(result.status, 0)
    }

    func testInstallerDoesNotReplaceOtherHandlersInSameGroup() throws {
        let original = Data("""
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"old # lidcontrol-ai-observer"},{"type":"command","command":"duplicate # sleepcontrol-ai-observer"},{"type":"command","command":"keep-me"}]}]}}
        """.utf8)
        let merged = try AIIntegration.merged(original, source: "codex", helper: directory)
        let text = String(decoding: merged, as: UTF8.self)
        XCTAssertTrue(text.contains("keep-me"))
        XCTAssertFalse(text.contains("old #"))
        XCTAssertFalse(text.contains("lidcontrol-ai-observer"))
        XCTAssertFalse(text.contains("duplicate #"))
        XCTAssertFalse(text.contains("dangerously-bypass"))
        XCTAssertEqual(merged, try AIIntegration.merged(merged, source: "codex", helper: directory))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: [[String: Any]]])
        let stopCommands = try XCTUnwrap(hooks["Stop"]).flatMap {
            ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
        XCTAssertEqual(stopCommands.filter { $0.contains("sleepcontrol-ai-observer") }.count, 1)
    }

    func testMalformedConfigFailsBeforeAnyFileIsModified() throws {
        let config = directory.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: config)
        let executable = directory.appendingPathComponent("fake-helper")
        try Data("fixture".utf8).write(to: executable)
        let store = AIProtectionStore(directory: directory.appendingPathComponent("state"))
        XCTAssertThrowsError(try AIIntegration.install(store: store, executable: executable, home: directory))
        XCTAssertEqual(try String(contentsOf: config), "broken")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".codex/hooks.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.helper.path))
    }

    func testConcurrentHookEventsAreNotLost() throws {
        let store = AIProtectionStore(directory: directory.appendingPathComponent("state"))
        let group = DispatchGroup()
        let failures = NSMutableArray()
        for index in 0..<40 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let event = try AIEvent(source: "codex", payload: ["hook_event_name": "UserPromptSubmit", "session_id": "s\(index)"])
                    try AIProtectionEngine(store: store).receive(event, ownerPID: nil)
                } catch {
                    objc_sync_enter(failures)
                    failures.add(error)
                    objc_sync_exit(failures)
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(failures.count, 0)
        XCTAssertEqual(try store.snapshot().registry.activeCount, 40)
        let data = try String(contentsOf: store.directory.appendingPathComponent("state.json"))
        XCTAssertFalse(data.contains("prompt"))
    }

    func testCodexRuntimeDistinguishesApprovalAndInputWaitFromWork() throws {
        XCTAssertEqual(try CodexRuntimeProbe.phase(["type": "active", "activeFlags": []]), .active)
        XCTAssertEqual(try CodexRuntimeProbe.phase(["type": "active", "activeFlags": ["waitingOnApproval"]]), .waiting)
        XCTAssertEqual(try CodexRuntimeProbe.phase(["type": "active", "activeFlags": ["waitingOnUserInput"]]), .waiting)
        XCTAssertNil(try CodexRuntimeProbe.phase(["type": "idle"]))
        XCTAssertThrowsError(try CodexRuntimeProbe.phase(["type": "active", "activeFlags": ["new-unknown-flag"]]))
    }

    func testCodexProbeUsesOnlyReadMethodsAndIncludesBackgroundWork() throws {
        var calls: [String] = []
        let snapshot = try CodexRuntimeProbe.snapshot(startedAt: Date()) { method, params in
            calls.append(method)
            switch method {
            case "thread/loaded/list": return ["data": ["waiting", "working"]]
            case "thread/read":
                XCTAssertEqual(params["includeTurns"] as? Bool, false)
                return ["thread": ["status": ["type": "active", "activeFlags": params["threadId"] as? String == "waiting" ? ["waitingOnApproval"] : []]]]
            case "thread/backgroundTerminals/list":
                return ["data": params["threadId"] as? String == "waiting" ? [["processId": "background"]] : []]
            default: XCTFail("Unexpected mutation method"); return [:]
            }
        }
        XCTAssertEqual(snapshot.sessions["waiting"]?.phase, .waiting)
        XCTAssertEqual(snapshot.sessions["working"]?.phase, .active)
        var registry = AITaskRegistry()
        registry.apply(snapshot)
        XCTAssertEqual(registry.activeCount, 2)
        XCTAssertEqual(registry.waitingCount, 1)
        XCTAssertFalse(calls.contains("thread/resume"))
    }

    func testRuntimeSnapshotDoesNotOverwriteNewerHook() throws {
        var registry = AITaskRegistry()
        let old = Date().addingTimeInterval(-10)
        try registry.receive(AIEvent(source: "codex", payload: ["hook_event_name": "UserPromptSubmit", "session_id": "s"]), ownerPID: nil)
        registry.apply(AIRuntimeSnapshot(source: "codex", startedAt: old,
            sessions: ["s": AIRuntimeSession(phase: nil, ownerPID: nil)]))
        XCTAssertEqual(registry.activeCount, 1)
    }

    func testClaudeRuntimeWaitResumesBeforeLongToolCompletes() throws {
        var registry = AITaskRegistry()
        try registry.receive(AIEvent(source: "claude", payload: ["hook_event_name": "PreToolUse", "session_id": "s", "tool_name": "Bash", "tool_use_id": "tool"]), ownerPID: nil, now: .distantPast)
        registry.apply(AIRuntimeSnapshot(source: "claude", startedAt: Date(),
            sessions: ["s": AIRuntimeSession(phase: .waiting, ownerPID: nil)]))
        XCTAssertEqual(registry.activeCount, 0)
        registry.apply(AIRuntimeSnapshot(source: "claude", startedAt: Date(),
            sessions: ["s": AIRuntimeSession(phase: .active, ownerPID: nil)]))
        XCTAssertGreaterThan(registry.activeCount, 0)
    }

    func testClaudeSessionRegistryRejectsUnknownAndIgnoresDeadPIDs() throws {
        let sessions = directory.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("123.json")
        let fixture: [String: Any] = ["pid": 123, "sessionId": "s", "version": "2.1.305", "status": "waiting"]
        try JSONSerialization.data(withJSONObject: fixture).write(to: file)
        let result = try ClaudeRuntimeProbe.read(home: directory, isAlive: { $0 == 123 })
        XCTAssertEqual(result.sessions["s"]?.phase, .waiting)
        XCTAssertTrue(try ClaudeRuntimeProbe.read(home: directory, isAlive: { _ in false }).sessions.isEmpty)
        var invalid = fixture
        invalid["status"] = "unknown"
        try JSONSerialization.data(withJSONObject: invalid).write(to: file)
        XCTAssertThrowsError(try ClaudeRuntimeProbe.read(home: directory, isAlive: { _ in true }))
    }

    func testNativeHookEntryUsesIsolatedStateAndReturnsJSONWithoutSavingContent() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let executable = package.appendingPathComponent(".build/debug/SleepControl")
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--ai-event", "codex"]
        var environment = ProcessInfo.processInfo.environment
        environment["SLEEPCONTROL_STATE_DIRECTORY"] = directory.path
        process.environment = environment
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data("""
        {"hook_event_name":"UserPromptSubmit","session_id":"fixture","prompt":"private fixture content"}
        """.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0,
            String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: Any])?.count, 0)
        let snapshot = try AIProtectionStore(directory: directory).snapshot()
        XCTAssertEqual(snapshot.registry.activeCount, 1)
        XCTAssertFalse(snapshot.enabled)
        XCTAssertFalse(try String(contentsOf: directory.appendingPathComponent("state.json")).contains("private fixture content"))
    }

    func testHelperDeploymentAndRepeatedInstallPreserveBothConfigs() throws {
        let executable = directory.appendingPathComponent("fake-helper")
        let fixture = Data("helper fixture".utf8)
        try fixture.write(to: executable)
        let store = AIProtectionStore(directory: directory.appendingPathComponent("state"))
        try store.withState { state in
            state.enabled = true
            state.manualSleepDisabled = true
        }
        let savedState = try Data(contentsOf: store.directory.appendingPathComponent("state.json"))
        let legacyHelper = store.directory.appendingPathComponent("LidControlHelper")
        let legacyFixture = Data("legacy helper fixture".utf8)
        try legacyFixture.write(to: legacyHelper)
        let codexConfig = directory.appendingPathComponent(".codex/hooks.json")
        try FileManager.default.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AIIntegration.merged(nil, source: "codex", helper: legacyHelper).write(to: codexConfig)
        try AIIntegration.install(store: store, executable: executable, home: directory)
        try AIIntegration.install(store: store, executable: executable, home: directory)
        XCTAssertEqual(store.helper.lastPathComponent, "SleepControlHelper")
        XCTAssertEqual(try Data(contentsOf: store.helper), fixture)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: store.helper.path))
        XCTAssertEqual(try Data(contentsOf: legacyHelper), legacyFixture)
        XCTAssertEqual(try Data(contentsOf: store.directory.appendingPathComponent("state.json")), savedState)
        for file in [".codex/hooks.json", ".claude/settings.json"] {
            let content = try Data(contentsOf: directory.appendingPathComponent(file))
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: content) as? [String: Any])
            XCTAssertNotNil(root["hooks"])
            let text = String(decoding: content, as: UTF8.self)
            XCTAssertTrue(text.contains("SleepControlHelper"))
            XCTAssertFalse(text.contains("LidControlHelper"))
        }
    }
}
