import SwiftUI
import Observation
import Speech

@MainActor final class CaptionPanelController: ObservableObject {
    static let shared = CaptionPanelController()
    @Published var hasVisibleCaptions = false
    func toggleVisible(mode: String) {}
}

@MainActor func tr(_ key: String) -> String { key }
@MainActor func tr(_ key: String, _ args: Any...) -> String { key }
func localeName(_ id: String) -> String { id }
struct UILang {
    var code: String
    var locale: String
    static let all: [UILang] = []
}
@MainActor @Observable final class CaptionState {
    var effectiveMode = "meeting"
    var captionSurface = "island"
    var captionDisplay = "both"
    var captionWidthLevel = "medium"
    var islandHeightLevel = "medium"
    var chunkLength = "medium"
    var captionFontLevel = "medium"
    var captionFontFamily = "system"
    var islandCollapseLevel = "medium"
    var captionOpacity = 0.8
    var captionClickThrough = false
    var captionsVisibleInScreenShare = false
    var supportsIslandSizing = true
    var meetingLocales: [String] = []
    var modelProgress: [String: Double] = [:]
    var autoDownloadModels = false
    var localeID = "en_US"
    var uiLanguage = "zh-Hans"
    func selectCaptionSurface(_ value: String) { captionSurface = value }
    func predownloadModels(_ locales: [String]) {}
    func modelReady(_ locale: String) -> Bool { false }
    func refreshModelInstallation() async {}
}

// r16d: localization-only stub; production vocabulary is checked by kk033_offline.
@MainActor func captionDisplayText(_ key: String) -> String { key }
