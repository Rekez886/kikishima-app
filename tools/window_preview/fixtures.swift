import SwiftUI
import Observation
// Synthetic state only: no singleton from the app, credentials, disk records or network.
@Observable final class CaptionState {
    static let shared = CaptionState()
    var mainSection: MainSection? = .captions
    var sessionToken = "fixture"; var accountEmail = "long.sample.address@example.com"; var plan = "free"
    var subscriptionStatus = ""; var trialDaysLeft: Int? = nil
    var usageQuota = 240000; var usageTokens = 72000
    var remainingMinutes: Int? = 42
    var remainingText = "42 minutes"
    var focusInvite = false
    var meetingLocales = ["en_US", "ja_JP"]; var localeID = "en_US"; var targetLang = "Japanese"
    var running = false; var starting = false; var paused = false; var switchingMeetingLanguage = false; var resuming = false
    var compactCaptions = true; var captionDisplay = "both"; var captionSurface = "island"
    var status = "Ready"; var loginHint = ""; var pendingEn = ""
    struct Chunk { var isMarker = false; var en = "Let's review the next steps."; var displayTranslation = "次の予定を一緒に確認しましょう。"; var displaySource: String { en } }
    var visibleCaptionChunks: [Chunk] = []
    var compactCaptionChunks: [Chunk] { Array(visibleCaptionChunks.suffix(2)) }
    var pendingDraft = ""
    var translationPaused = false
    enum Consent { case undecided, enabled }
    var summaryConsent = Consent.undecided
    var calendarCoordinator = 0
    func refreshPlan() {}
    func openUpgrade() {}
    func signOut() { sessionToken = "" }
    func toggle() { running.toggle() }
    func pause() { paused = true }
    func resume() { paused = false }
    func modelReady(_ id: String) -> Bool { true }
    func selectMeetingLanguage(_ id: String) { localeID = id }
    func setMeetingSummariesEnabled(_ value: Bool) { summaryConsent = .enabled }
}
enum SpeechTranscriber { static var supportedLocales: [Locale] { get async { [Locale(identifier: "en_US"), Locale(identifier: "ja_JP")] } } }
enum GlobalHotkey { static var displayText: String { "⌘ ⌘" } }
let targetLanguages = [(display: "日本語", prompt: "Japanese"), (display: "English", prompt: "English")]
func localeName(_ id: String) -> String { Locale(identifier: "en").localizedString(forIdentifier: id) ?? id }
struct CalendarMeetingCard: View {
    var coordinator: Int; var isRunning: Bool
    var body: some View { GroupBox(tr("日历会议")) { Text(tr("接下来没有找到会议。")).frame(maxWidth: .infinity, alignment: .leading) } }
}
struct RecentTranscripts: View {
    var limit: Int
    var body: some View { GroupBox(tr("最近记录")) { Text(tr("还没有会议记录。停止字幕时会自动保存到「文稿 › Kikishima」。")) } }
}
struct HistoryView: View { var body: some View { Text("Fixture: not rendered") } }
struct HelpView: View { var body: some View { Text("Fixture: not rendered") } }
struct SettingsPane: View { var state: CaptionState; var body: some View { Text("Fixture: not rendered") } }
struct LanguagesView: View { var state: CaptionState; var body: some View { Text("Fixture: not rendered") } }
struct GlossarySettings: View { var state: CaptionState; var body: some View { Text("Fixture: not rendered") } }
