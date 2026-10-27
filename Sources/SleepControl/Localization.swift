import Foundation

/// One catalog for SwiftUI, AppKit and the standalone event helper.
enum L10n {
    static let resourceBundleName = "SleepControl_SleepControl.bundle"

    static let resourceBundle: Bundle = {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(resourceBundleName),
            Bundle.main.bundleURL.appendingPathComponent(resourceBundleName),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(resourceBundleName)
        ].compactMap { $0 }
        for candidate in candidates {
            if let bundle = Bundle(url: candidate), bundle.url(forResource: "en", withExtension: "lproj") != nil {
                return bundle
            }
        }
        return .module
    }()

    static var preferences: [String] {
        UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages
    }

    static func language(for preferences: [String]) -> String {
        for preference in preferences {
            let language = preference.replacingOccurrences(of: "_", with: "-")
                .lowercased().split(separator: "-").first
            if language == "zh" { return "zh-Hans" }
            if language == "en" { return "en" }
        }
        return "en"
    }

    static var language: String { language(for: preferences) }
    static var panelWidth: CGFloat { language == "en" ? 390 : 320 }

    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        localized(key, arguments: arguments, preferences: preferences)
    }

    static func localized(_ key: String, arguments: [CVarArg] = [], preferences: [String]) -> String {
        let language = language(for: preferences)
        // SwiftPM normalizes localization directory names to lowercase.
        let url = resourceBundle.url(forResource: language.lowercased(), withExtension: "lproj")
            ?? resourceBundle.url(forResource: language, withExtension: "lproj")
        let bundle = url.flatMap(Bundle.init(url:)) ?? resourceBundle
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        return arguments.isEmpty ? format
            : String(format: format, locale: Locale(identifier: language), arguments: arguments)
    }
}
