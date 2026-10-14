import AppKit
import Foundation

enum AppLanguagePreference {
    private static let supported = Set(["zh-Hans", "zh-Hant", "ja", "en", "ko"])

    /// Capture before changing defaults so the settings screen can tell whether this process needs a restart.
    static let processLanguage: String = normalized(Locale.preferredLanguages.first ?? "en")

    static func persist(_ code: String, defaults: UserDefaults = .standard) {
        defaults.set(code, forKey: "uiLanguage")
        guard supported.contains(code) else { return }
        defaults.set([code], forKey: "AppleLanguages")
        defaults.synchronize()
    }

    /// Migrates existing installs that already have uiLanguage but not the matching per-app AppleLanguages value.
    @discardableResult
    static func synchronizeSavedLanguage(defaults: UserDefaults = .standard) -> String? {
        guard let code = defaults.string(forKey: "uiLanguage"), supported.contains(code) else { return nil }
        guard defaults.stringArray(forKey: "AppleLanguages") != [code] else { return nil }
        defaults.set([code], forKey: "AppleLanguages")
        defaults.synchronize()
        return code
    }

    static func requiresRelaunch(for code: String) -> Bool {
        supported.contains(code) && normalized(code) != processLanguage
    }

    private static func normalized(_ language: String) -> String {
        if language.hasPrefix("zh-Hant") || language.hasPrefix("zh-TW") || language.hasPrefix("zh-HK") { return "zh-Hant" }
        if language.hasPrefix("zh") { return "zh-Hans" }
        if language.hasPrefix("ja") { return "ja" }
        if language.hasPrefix("ko") { return "ko" }
        return "en"
    }
}

enum AppRelauncher {
    static func launchNewInstance() -> Bool {
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", appURL.path]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    @MainActor
    static func restart() {
        guard launchNewInstance() else { return }
        NSApplication.shared.terminate(nil)
    }
}
