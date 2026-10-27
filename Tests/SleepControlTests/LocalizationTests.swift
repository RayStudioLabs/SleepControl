import Foundation
import XCTest
@testable import SleepControl

final class LocalizationTests: XCTestCase {
    func testLanguageFollowsPreferredSupportedLanguage() {
        XCTAssertEqual(L10n.language(for: ["en-US", "zh-Hans"]), "en")
        XCTAssertEqual(L10n.language(for: ["zh-CN", "en"]), "zh-Hans")
        XCTAssertEqual(L10n.language(for: ["zh-Hant-TW", "en"]), "zh-Hans")
        XCTAssertEqual(L10n.language(for: ["fr-FR", "zh_HK", "en"]), "zh-Hans")
        XCTAssertEqual(L10n.language(for: ["fr-FR", "en-GB"]), "en")
        XCTAssertEqual(L10n.language(for: ["de-DE"]), "en")
        XCTAssertEqual(L10n.language(for: []), "en")
    }

    private func catalog(_ language: String, bundle: Bundle = L10n.resourceBundle) throws -> [String: String] {
        let folder = try XCTUnwrap(bundle.url(forResource: language.lowercased(), withExtension: "lproj"))
        let data = try Data(contentsOf: folder.appendingPathComponent("Localizable.strings"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    func testBothCatalogsAreCompleteAndFormatsAgree() throws {
        let english = try catalog("en")
        let chinese = try catalog("zh-Hans")
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        XCTAssertGreaterThan(english.count, 100)
        for (key, value) in english {
            let translated = try XCTUnwrap(chinese[key])
            XCTAssertFalse(value.isEmpty, key)
            XCTAssertFalse(translated.isEmpty, key)
            XCTAssertNil(value.range(of: "\\p{Han}", options: .regularExpression), key)
            XCTAssertEqual(value.components(separatedBy: "%@").count,
                           translated.components(separatedBy: "%@").count, key)
            let count = value.components(separatedBy: "%@").count - 1
            let arguments: [CVarArg] = Array(repeating: "sample", count: count)
            for language in ["en", "zh-Hans"] {
                let result = L10n.localized(key, arguments: arguments, preferences: [language])
                XCTAssertFalse(result.contains("%@"), "\(language): \(key)")
            }
        }
    }

    func testDynamicStatusAndPercentageAreLocalized() {
        XCTAssertEqual(L10n.localized("Battery %@%%", arguments: ["75"], preferences: ["en"]), "Battery 75%")
        XCTAssertEqual(L10n.localized("Battery %@%%", arguments: ["75"], preferences: ["zh-Hans"]), "电量 75%")
        XCTAssertEqual(L10n.localized("Keeping your Mac awake · %@", arguments: ["Codex 2"], preferences: ["en"]),
                       "Keeping your Mac awake · Codex 2")
        XCTAssertEqual(L10n.localized("Keeping your Mac awake · %@", arguments: ["Codex 2"], preferences: ["zh-Hans"]),
                       "AI保护中 · Codex 2")
        XCTAssertEqual(L10n.localized("1 minute", preferences: ["en"]), "1 minute")
        XCTAssertEqual(L10n.localized("%@ minutes", arguments: ["2"], preferences: ["en"]), "2 minutes")
    }

    func testCopiedHelperIncludesResourcesAndRunsAwayFromTheBuildDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIProtectionStore(directory: directory.appendingPathComponent("AI"))
        let executable = L10n.resourceBundle.bundleURL.deletingLastPathComponent().appendingPathComponent("SleepControl")
        try AIIntegration.install(store: store, executable: executable, home: directory)
        let installedBundle = try XCTUnwrap(Bundle(url: store.directory.appendingPathComponent(L10n.resourceBundleName)))
        XCTAssertEqual(try catalog("en", bundle: installedBundle)["Close"], "Close")
        XCTAssertEqual(try catalog("zh-Hans", bundle: installedBundle)["Close"], "关闭")
        let process = Process()
        process.executableURL = store.helper
        process.arguments = ["--ai-event", "codex"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "SLEEPCONTROL_STATE_DIRECTORY": store.directory.path
        ]) { _, new in new }
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = output
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data("{}".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let error = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 1)
        XCTAssertTrue(error.contains("The AI task event was not recognized.")
                      || error.contains("无法识别 AI 任务事件。"), error)
        XCTAssertFalse(error.contains("could not load resource bundle"), error)
    }
}
