#if SHOOT || DEBUG
import SwiftUI
import AppKit

/// Synthetic input for the real app, state, menu and caption surfaces.
@MainActor
enum ShootSimulation {
    enum Mode: String { case scrolling, desktop, silent, paused }
    nonisolated static var requestedMode: Mode? {
        ProcessInfo.processInfo.environment["KIKISHIMA_SHOOT_SIM"].flatMap(Mode.init(rawValue:))
    }
    private static var feed: Task<Void, Never>?
    private static var mode: Mode?
    private static var interfaceLanguage = "en"
    private static var sourceIsJapanese = true
    private static var translationIsJapanese = false
    nonisolated static func argument(_ key: String, in arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        guard let i = arguments.firstIndex(of: key), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
    nonisolated static func selectedInterfaceLanguage(arguments: [String], saved: String) -> String {
        let explicit = argument("-AppleLanguages", in: arguments)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "()[]\" "))
            .split(separator: ",").first.map(String.init)
        let code = explicit ?? (saved.isEmpty ? Locale.preferredLanguages.first ?? "en" : saved)
        if code.hasPrefix("ja") { return "ja" }
        if code.hasPrefix("zh-Hant") { return "zh-Hant" }
        if code.hasPrefix("zh") { return "zh-Hans" }
        if code.hasPrefix("ko") { return "ko" }
        return "en"
    }
    static var previewSource: String { sample(0).en }
    static var previewTranslation: String { sample(0).zh }
    static func applyRequestedAppearance() {
        guard requestedMode != nil else { return }
        switch argument("-AppleInterfaceStyle") {
        case "Dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "Light": NSApp.appearance = NSAppearance(named: .aqua)
        default: return
        }

    }
    static func runIfRequested() -> Bool {
        guard let requested = requestedMode else { return false }
        mode = requested
        configure(CaptionState.shared, mode: requested)
        KikishimaApp.main()
        return true
    }
    static func configure(_ state: CaptionState, mode: Mode) {
        feed?.cancel()
        self.mode = mode
        interfaceLanguage = selectedInterfaceLanguage(arguments: ProcessInfo.processInfo.arguments, saved: state.uiLanguage)
        state.uiLanguage = interfaceLanguage
        // Screenshot-only language settings. Never ask the speech framework for assets.
        state.autoDownloadModels = false
        state.localeID = argument("-KikishimaMeetingLanguage") ?? (interfaceLanguage == "ja" ? "en_US" : "ja_JP")
        state.targetLang = argument("-KikishimaCaptionLanguage") ?? (interfaceLanguage == "ja" ? "Japanese" : "English")
        state.meetingLocales = [state.localeID]
        sourceIsJapanese = state.localeID.hasPrefix("ja")
        translationIsJapanese = state.targetLang == "Japanese"
        state.captionSurface = mode == .desktop ? "window" : "island"
        state.running = true
        state.starting = false
        state.paused = mode == .paused
        state.silentTooLong = mode == .silent
        state.audioStalled = false
        state.audioLevel = mode == .silent || mode == .paused ? 0 : 0.55
        state.status = mode == .paused ? tr("已暂停") : CaptionListeningStatus.text(silentTooLong: state.silentTooLong, audioStalled: false)
        state.chunks = mode == .silent ? [] : [sample(0)]
        if mode == .scrolling || mode == .desktop {
            feed = Task { @MainActor in
                var index = 1
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard state.running, !state.paused else { continue }
                    state.chunks.append(sample(index))
                    index += 1
                    if state.chunks.count > 40 { state.chunks.removeFirst() }
                    IslandNotchController.shared.noteActivity()
                }
            }
        }
    }
    static func showCaptions() {
        CaptionPanelController.shared.show()
        CaptionPanelController.shared.place(for: .meeting, force: true)
    }
    static func pause(_ state: CaptionState) {
        state.paused = true
        state.audioLevel = 0
        state.status = tr("已暂停")
    }
    static func resume(_ state: CaptionState) {
        state.paused = false
        state.status = CaptionListeningStatus.text(silentTooLong: state.silentTooLong, audioStalled: false)
    }
    static func stop(_ state: CaptionState) {
        feed?.cancel()
        feed = nil
        state.running = false
        state.paused = false
        state.silentTooLong = false
        state.audioLevel = 0
        state.status = tr("已停止")
    }
    static func start(_ state: CaptionState) {
        configure(state, mode: mode ?? requestedMode ?? .scrolling)
        showCaptions()
    }
    private static func sample(_ index: Int) -> CaptionChunk {
        let english = ["Let's review the next steps together.",
            "The first draft will be ready on Friday.",
            "We can discuss the details at our next meeting."]
        let japanese = ["次の予定を一緒に確認しましょう。",
            "最初の案は金曜日に完成する予定です。",
            "詳しい内容は次の会議で話し合いましょう。"]
        let i = index % english.count
        let pair = ((sourceIsJapanese ? japanese : english)[i], (translationIsJapanese ? japanese : english)[i])
        var chunk = CaptionChunk(en: pair.0, zh: pair.1)
        chunk.translationComplete = true
        return chunk
    }
}
#endif
