import Foundation

@main
struct MeetingLanguageStateTest {
    @MainActor
    static func main() {
        let savedLocale = UserDefaults.standard.string(forKey: "locale")
        let savedAutoDownload = UserDefaults.standard.object(forKey: "autoDownloadModels")
        defer {
            if let savedLocale { UserDefaults.standard.set(savedLocale, forKey: "locale") }
            else { UserDefaults.standard.removeObject(forKey: "locale") }
            if let savedAutoDownload { UserDefaults.standard.set(savedAutoDownload, forKey: "autoDownloadModels") }
            else { UserDefaults.standard.removeObject(forKey: "autoDownloadModels") }
        }

        let state = CaptionState()
        state.autoDownloadModels = false
        state.localeID = "en_US"
        state.selectMeetingLanguage("ja_JP")

        precondition(state.localeID == "ja_JP", "Selecting a language before a meeting should update the next meeting locale immediately")
        precondition(!state.switchingMeetingLanguage)
        print("PASS: idle meeting language selection uses the shared state entry point")
    }
}
