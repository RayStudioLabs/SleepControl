import Foundation
import XCTest
@testable import SleepControl

final class LocalizationTests: XCTestCase {
    func testLanguageFollowsPreferredSupportedLanguage() {
        XCTAssertEqual(L10n.language(for: ["en-US", "zh-Hans"]), "en")
        XCTAssertEqual(L10n.language(for: ["zh-CN", "en"]), "zh-Hans")
        XCTAssertEqual(L10n.language(for: ["zh-Hant-TW", "en"]), "zh-Hant")
        XCTAssertEqual(L10n.language(for: ["zh_HK", "en"]), "zh-Hant")
        XCTAssertEqual(L10n.language(for: ["zh-MO"]), "zh-Hant")
        XCTAssertEqual(L10n.language(for: ["zh-SG"]), "zh-Hans")
        XCTAssertEqual(L10n.language(for: ["zh"]), "zh-Hans")
        XCTAssertEqual(L10n.language(for: ["zh-Hans-TW"]), "zh-Hans")
        XCTAssertEqual(L10n.language(for: ["zh-Hant-CN"]), "zh-Hant")
        XCTAssertEqual(L10n.language(for: ["fr-FR", "zh_HK", "en"]), "fr")
        XCTAssertEqual(L10n.language(for: ["de-DE"]), "de")
        XCTAssertEqual(L10n.language(for: ["es-MX"]), "es")
        XCTAssertEqual(L10n.language(for: ["ja-JP"]), "ja")
        XCTAssertEqual(L10n.language(for: ["ko-KR"]), "ko")
        XCTAssertEqual(L10n.language(for: ["pt_BR", "en"]), "pt-BR")
        XCTAssertEqual(L10n.language(for: ["it-IT"]), "it")
        XCTAssertEqual(L10n.language(for: ["nl-NL", "ja-JP", "en"]), "ja")
        XCTAssertEqual(L10n.language(for: ["nl-NL"]), "en")
        XCTAssertEqual(L10n.language(for: []), "en")
    }

    private func catalog(_ language: String, bundle: Bundle = L10n.resourceBundle) throws -> [String: String] {
        let folder = try XCTUnwrap(bundle.url(forResource: language.lowercased(), withExtension: "lproj"))
        let data = try Data(contentsOf: folder.appendingPathComponent("Localizable.strings"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    func testAllTenCatalogsAreCompleteAndFormatsAgree() throws {
        let english = try catalog("en")
        XCTAssertEqual(Set(L10n.supportedLanguages),
                       Set(["en", "zh-Hans", "zh-Hant", "de", "fr", "es", "ja", "ko", "pt-BR", "it"]))
        XCTAssertEqual(Set(L10n.resourceBundle.localizations.map { $0.lowercased() }),
                       Set(L10n.supportedLanguages.map { $0.lowercased() }))
        XCTAssertGreaterThan(english.count, 100)
        let formats = try NSRegularExpression(pattern: "%@|%%")
        func specifiers(_ value: String) -> [String] {
            formats.matches(in: value, range: NSRange(value.startIndex..., in: value))
                .map { (value as NSString).substring(with: $0.range) }
        }
        for language in L10n.supportedLanguages {
            let translated = try catalog(language)
            XCTAssertEqual(Set(english.keys), Set(translated.keys), language)
            for (key, value) in english {
                let translation = try XCTUnwrap(translated[key], "\(language): \(key)")
                XCTAssertFalse(translation.isEmpty, "\(language): \(key)")
                XCTAssertEqual(specifiers(value), specifiers(translation), "\(language): \(key)")
                let count = specifiers(value).filter { $0 == "%@" }.count
                let arguments: [CVarArg] = Array(repeating: "sample", count: count)
                let result = L10n.localized(key, arguments: arguments, preferences: [language])
                let expected = arguments.isEmpty ? translation
                    : String(format: translation, locale: Locale(identifier: language), arguments: arguments)
                XCTAssertEqual(result, expected, "\(language): \(key)")
                XCTAssertFalse(result.contains("%@"), "\(language): \(key)")
            }
        }
    }

    func testAppMetadataAdvertisesAllSupportedLanguages() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let resources = root.appendingPathComponent("Resources")
        let data = try Data(contentsOf: resources.appendingPathComponent("Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(info["CFBundleName"] as? String, "SleepControl")
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "SleepControl")
        let languages = try XCTUnwrap(info["CFBundleLocalizations"] as? [String])
        XCTAssertEqual(Set(languages), Set(L10n.supportedLanguages))
        for language in languages {
            let data = try Data(contentsOf: resources.appendingPathComponent("\(language).lproj/InfoPlist.strings"))
            let names = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            XCTAssertEqual(names["CFBundleName"], "SleepControl", language)
            XCTAssertEqual(names["CFBundleDisplayName"], "SleepControl", language)
        }
    }

    func testDynamicStatusAndPercentageAreLocalized() {
        XCTAssertEqual(L10n.localized("Battery %@%%", arguments: ["75"], preferences: ["en"]), "Battery 75%")
        XCTAssertEqual(L10n.localized("Battery %@%%", arguments: ["75"], preferences: ["zh-Hans"]), "电量 75%")
        XCTAssertEqual(L10n.localized("Battery %@%%", arguments: ["75"], preferences: ["zh-TW"]), "電池電量 75%")
        XCTAssertEqual(L10n.localized("Close", preferences: ["de-DE"]), "Schließen")
        XCTAssertEqual(L10n.localized("Close", preferences: ["fr-FR"]), "Fermer")
        XCTAssertEqual(L10n.localized("Close", preferences: ["es-ES"]), "Cerrar")
        XCTAssertEqual(L10n.localized("Close", preferences: ["ja-JP"]), "閉じる")
        XCTAssertEqual(L10n.localized("Close", preferences: ["ko-KR"]), "닫기")
        XCTAssertEqual(L10n.localized("Close", preferences: ["pt-BR"]), "Fechar")
        XCTAssertEqual(L10n.localized("Close", preferences: ["it-IT"]), "Chiudi")
        XCTAssertEqual(L10n.localized("Close", preferences: ["nl-NL"]), "Close")
        XCTAssertEqual(L10n.localized("List separator", preferences: ["en"]), ", ")
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
        for language in L10n.supportedLanguages {
            XCTAssertEqual(try catalog(language, bundle: installedBundle), try catalog(language), language)
        }
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
        let localizedErrors = try L10n.supportedLanguages.map { language in
            try XCTUnwrap(catalog(language)["The AI task event was not recognized."])
        }
        XCTAssertTrue(localizedErrors.contains { error.contains($0) }, error)
        XCTAssertFalse(error.contains("could not load resource bundle"), error)
    }
}
