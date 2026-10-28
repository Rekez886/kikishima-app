import Foundation

final class InMemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    override func set(_ value: Any?, forKey key: String) {
        values[key] = value
    }

    override func object(forKey key: String) -> Any? {
        values[key]
    }

    override func string(forKey key: String) -> String? {
        values[key] as? String
    }

    override func stringArray(forKey key: String) -> [String]? {
        values[key] as? [String]
    }

    override func removeObject(forKey key: String) {
        values.removeValue(forKey: key)
    }

    override func synchronize() -> Bool {
        true
    }
}

@main
struct AppLanguageTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        let suiteName = "kikishima-test-inmemory-\(UUID().uuidString)"
        let isolated = InMemoryDefaults(suiteName: suiteName)!
        defer { isolated.removePersistentDomain(forName: suiteName) }

        AppLanguagePreference.persist("ja", defaults: isolated)
        expect(isolated.string(forKey: "uiLanguage") == "ja", "persist stores the UI language")
        expect(isolated.stringArray(forKey: "AppleLanguages") == ["ja"], "persist sets the supported app language")

        isolated.removeObject(forKey: "AppleLanguages")
        AppLanguagePreference.persist("xx", defaults: isolated)
        expect(isolated.string(forKey: "uiLanguage") == "xx", "persist stores unsupported UI language codes")
        expect(isolated.object(forKey: "AppleLanguages") == nil, "unsupported codes do not set app languages")
        isolated.set(["ja"], forKey: "AppleLanguages")
        AppLanguagePreference.persist("xx", defaults: isolated)
        expect(isolated.stringArray(forKey: "AppleLanguages") == ["ja"], "unsupported codes preserve existing app languages")

        isolated.set("ko", forKey: "uiLanguage")
        isolated.set(["zh-Hans"], forKey: "AppleLanguages")
        expect(AppLanguagePreference.synchronizeSavedLanguage(defaults: isolated) == "ko", "saved supported language is migrated")
        expect(isolated.stringArray(forKey: "AppleLanguages") == ["ko"], "migration updates app languages")
        expect(AppLanguagePreference.synchronizeSavedLanguage(defaults: isolated) == nil, "matching app languages need no migration")
        expect(isolated.stringArray(forKey: "AppleLanguages") == ["ko"], "matching app languages remain unchanged")

        isolated.set("xx", forKey: "uiLanguage")
        expect(AppLanguagePreference.synchronizeSavedLanguage(defaults: isolated) == nil, "unsupported saved language is not migrated")
        expect(isolated.stringArray(forKey: "AppleLanguages") == ["ko"], "unsupported saved language preserves app languages")
        isolated.removeObject(forKey: "uiLanguage")
        isolated.removeObject(forKey: "AppleLanguages")
        expect(AppLanguagePreference.synchronizeSavedLanguage(defaults: isolated) == nil, "missing saved language is not migrated")
        expect(isolated.object(forKey: "AppleLanguages") == nil, "missing saved language does not create app languages")

        // Unsupported codes short-circuit before reading the process language.
        expect(!AppLanguagePreference.requiresRelaunch(for: "xx"), "unsupported languages never require relaunch")
        print("PASS: app language preferences stay in memory")
    }
}
