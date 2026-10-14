import Foundation

@main
struct AppLanguageTests {
    @MainActor
    static func main() {
        let defaults = UserDefaults.standard
        let oldUILanguage = defaults.object(forKey: "uiLanguage")
        let oldAppleLanguages = defaults.object(forKey: "AppleLanguages")
        defer {
            if let oldUILanguage {
                defaults.set(oldUILanguage, forKey: "uiLanguage")
            } else {
                defaults.removeObject(forKey: "uiLanguage")
            }
            if let oldAppleLanguages {
                defaults.set(oldAppleLanguages, forKey: "AppleLanguages")
            } else {
                defaults.removeObject(forKey: "AppleLanguages")
            }
        }

        defaults.set(["zh-Hans"], forKey: "AppleLanguages")
        CaptionState.shared.uiLanguage = "ja"

        guard defaults.stringArray(forKey: "AppleLanguages") == ["ja"] else {
            fputs("FAIL: changing the Kikishima UI language did not update the app language used by Sparkle\n", stderr)
            exit(1)
        }

        defaults.set("ko", forKey: "uiLanguage")
        defaults.set(["zh-Hans"], forKey: "AppleLanguages")
        guard AppLanguagePreference.synchronizeSavedLanguage(defaults: defaults) == "ko",
              defaults.stringArray(forKey: "AppleLanguages") == ["ko"] else {
            fputs("FAIL: an existing UI language preference was not migrated for Sparkle\n", stderr)
            exit(1)
        }

        print("PASS: app language follows Kikishima UI language")
    }
}
