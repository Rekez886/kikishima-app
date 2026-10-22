import Foundation
func tr(_ text: String) -> String { text }
struct CaptionChunk { let id = UUID(); var en: String; var zh: String; var translationComplete=false; var translationAttempts=0; var translationExhausted=false }
struct CaptionBanner { enum Action { case openSettings, login, upgrade }; var text: String; var action: Action }
@MainActor final class CaptionState {
 static let shared = CaptionState()
    enum PauseReason { case payment, session, quota, freePool }
    var translationPaused = false, compactCaptions = false
    var captionDisplay = "both"
    func simulateTranslationPause(_ reason: PauseReason) { translationPaused = true }

 var errorBanner: CaptionBanner?
 var audioInterruption = CaptionAudioInterruption.none
 var translationConnectivity = TranslationConnectivityPolicy()
 var captionSurface="original", uiLanguage="en", localeID="en_US", targetLang="English"
 var meetingLocales: [String]=[]
 var autoDownloadModels=true, running=false, starting=false, paused=false, silentTooLong=false, audioStalled=false
 var audioLevel=0.0, status=""
 var chunks: [CaptionChunk]=[]
}
enum EffectiveMode { case meeting }
@MainActor enum CaptionListeningStatus {
 static func text(silentTooLong: Bool, audioStalled: Bool) -> String { silentTooLong ? "没听到声音" : "正在听…" }
}
@MainActor enum CaptionPanelController {
 static let shared = CaptionPanelControllerValue()
}
@MainActor struct CaptionPanelControllerValue {
 func show() {}
 func place(for mode: EffectiveMode, force: Bool) {}
}
@MainActor enum IslandNotchController {
 static let shared = IslandNotchControllerValue()
}
@MainActor struct IslandNotchControllerValue { func noteActivity() {} }
enum KikishimaApp { static func main() { fatalError("must not start app") } }
