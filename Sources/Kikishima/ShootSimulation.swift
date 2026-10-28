#if SHOOT || DEBUG
import SwiftUI
import AppKit

/// Synthetic input for the real app, state, menu and caption surfaces.
@MainActor
enum ShootSimulation {
    enum Mode: String, CaseIterable { case scrolling, desktop, rapid, silent, paused, error, offline, exhausted
        case sourceOnlyPro = "source-only-pro-required", sourceOnlySession = "source-only-signed-out"
        case sourceOnlyPool = "source-only-free-pool", sourceOnlyQuota = "source-only-weekly-quota"
        case sourceOnlyQuotaText = "source-only-quota-transcription", sourceOnlyPoolText = "source-only-pool-transcription"
        case longSentence = "long-sentence"
        case menuProcess = "menu-process"
        case sourceOnlyTransition = "source-only-transition"
        case errorLogin = "error-login", errorQuota = "error-quota"
        case errorDevice = "error-device", errorPermission = "error-permission", audioStopped = "audio-stopped"
    }
    nonisolated static var requestedMode: Mode? {
        ProcessInfo.processInfo.environment["KIKISHIMA_SHOOT_SIM"].flatMap(Mode.init(rawValue:))
    }
    nonisolated static var requestedIslandExpanded: Bool {
        guard let value = ProcessInfo.processInfo.environment["KIKISHIMA_SHOOT_ISLAND_EXPANDED"] else { return false }
        guard value == "1" else {
            fputs("Invalid KIKISHIMA_SHOOT_ISLAND_EXPANDED: require 1\n", stderr)
            exit(1)
        }
        return true
    }
    nonisolated static var requestedOpenMenu: Bool {
        guard let value = ProcessInfo.processInfo.environment["KIKISHIMA_SHOOT_OPEN_MENU"] else { return false }
        guard value == "1" else {
            fputs("Invalid KIKISHIMA_SHOOT_OPEN_MENU: require 1\n", stderr)
            exit(1)
        }
        return true
    }
    nonisolated static var requestedIslandTransition: Double? {
        guard let value = ProcessInfo.processInfo.environment["KIKISHIMA_SHOOT_ISLAND_TRANSITION"] else { return nil }
        guard let seconds = Double(value), seconds.isFinite, seconds > 0 else {
            fputs("Invalid KIKISHIMA_SHOOT_ISLAND_TRANSITION: require positive finite seconds\n", stderr)
            exit(1)
        }
        return seconds
    }
    nonisolated static var requestedPlacement: String? {
        guard let value = ProcessInfo.processInfo.environment["KIKISHIMA_SHOOT_PLACEMENT"] else { return nil }
        switch value {
        case "desktop": return "window"
        case "island": return "island"
        default:
            fputs("Invalid KIKISHIMA_SHOOT_PLACEMENT: require desktop or island\n", stderr)
            exit(1)
        }
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
        _ = requestedPlacement // Validate before any app state or startup.
        _ = requestedIslandExpanded
        _ = requestedOpenMenu
        _ = requestedIslandTransition
        if ProcessInfo.processInfo.environment["KIKISHIMA_SHOOT_MODES"] == "1" {
            let data = try! JSONSerialization.data(withJSONObject: Mode.allCases.map(\.rawValue), options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return true
        }
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
        let rendering = ProcessInfo.processInfo.environment["KIKISHIMA_SHOOT_RENDER"] != nil
        // Render state was initialized from the volatile domain. Assigning these
        // properties would trigger production didSet persistence, including the
        // shared uiLanguage/AppleLanguages race. Normal SHOOT behavior is unchanged.
        if !rendering {
            state.uiLanguage = interfaceLanguage
            // Screenshot-only language settings. Never ask the speech framework for assets.
            state.autoDownloadModels = false
            state.localeID = argument("-KikishimaMeetingLanguage") ?? (interfaceLanguage == "ja" ? "en_US" : "ja_JP")
            state.targetLang = argument("-KikishimaCaptionLanguage") ?? (interfaceLanguage == "ja" ? "Japanese" : "English")
            state.meetingLocales = [state.localeID]
        }
        sourceIsJapanese = state.localeID.hasPrefix("ja")
        translationIsJapanese = state.targetLang == "Japanese"
        state.captionSurface = mode == .desktop ? "window" : "island"
        if mode == .error || mode == .errorLogin || mode == .errorQuota { state.captionSurface = "window" }
        if let placement = requestedPlacement { state.captionSurface = placement }
        // Screenshot-diff renders each scene in both placements; the placement argument wins.
        if rendering { state.captionSurface = argument("-KikishimaShotPlacement") == "desktop" ? "window" : "island" }
        state.errorBanner = mode == .error ? CaptionBanner(text: tr("没有「系统录音」权限，听不到会议声音。系统设置 › 隐私与安全性 › 屏幕录制与系统录音 里允许 Kikishima。"), action: .openSettings) : nil
        if mode == .errorLogin {
            state.errorBanner = CaptionBanner(text: tr("OpenAI API Key 无效或已撤销，更新 Key 后继续翻译"), action: .settings)
        } else if mode == .errorQuota {
            // Existing PlanQuotaPolicy free-plan key; fixed screenshot-only reset.
            state.errorBanner = CaptionBanner(text: tr("本机翻译暂不可用，请下载语言包或换一个引擎"), action: .settings)
        }
        state.running = true
        state.starting = false
        state.paused = mode == .paused
        state.silentTooLong = mode == .silent
        state.audioInterruption = mode == .errorDevice ? .deviceMissing : mode == .errorPermission ? .systemPermission : mode == .audioStopped ? .recovering : .none
        state.audioStalled = mode == .audioStopped
        state.audioLevel = mode == .silent || mode == .paused ? 0 : 0.55
        state.status = mode == .paused ? tr("已暂停") : CaptionListeningStatus.text(silentTooLong: state.silentTooLong, audioStalled: false)
        if mode == .menuProcess { state.status = tr("输出设备已切换，继续字幕") }
        state.chunks = mode == .silent ? [] : [sample(0)]
        state.translationConnectivity = TranslationConnectivityPolicy()
        if mode == .offline {
            for _ in 0..<3 { state.translationConnectivity.failed(chunk: UUID(), enabled: true) }
        }
        if mode == .exhausted {
            state.chunks[0].zh = ""
            state.chunks[0].translationComplete = false
            state.chunks[0].translationAttempts = 3
            state.chunks[0].translationExhausted = true
        }
        if mode.rawValue.hasPrefix("source-only-") && mode != .sourceOnlyTransition {
            state.compactCaptions = true
            state.captionDisplay = "both"
            let reason: CaptionState.PauseReason = mode == .sourceOnlyPro ? .payment : mode == .sourceOnlySession ? .session :
                (mode == .sourceOnlyPool || mode == .sourceOnlyPoolText) ? .freePool : .quota
            state.simulateTranslationPause(reason)
            var source = sample(1)
            source.zh = ""
            source.translationComplete = false
            // Keep the translated history as data; only the newest source-only segment is current.
            state.chunks = [sample(0), source]
            switch mode {
            case .sourceOnlyPro:
                state.errorBanner = CaptionBanner(text: tr("翻译已暂停"), action: .settings)
            case .sourceOnlySession:
                state.errorBanner = CaptionBanner(text: tr("翻译已暂停"), action: .settings)
            case .sourceOnlyPool:
                state.errorBanner = CaptionBanner(text: tr("翻译已暂停"), action: .settings)
            case .sourceOnlyQuota:
                state.errorBanner = CaptionBanner(text: tr("本机翻译暂不可用，请下载语言包或换一个引擎"), action: .settings)
            case .sourceOnlyQuotaText: state.status = tr("额度已用完 · 仅转写")
            case .sourceOnlyPoolText: state.status = tr("免费额度今日用尽 · 仅转写")
            default: break
            }
        }
        if mode == .sourceOnlyTransition {
            state.compactCaptions = true
            state.captionDisplay = "both"
            state.chunks = [sample(0)]
            if !rendering {
                feed = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(requestedIslandTransition ?? 3)) } catch { return }
                    guard !Task.isCancelled else { return }
                    applySourceOnlyTransition(state)
                }
            }
        }
        if mode == .longSentence {
            var sentence = CaptionChunk(en: "We will review the draft together at the next meeting.",
                zh: "We will review the complete draft together at the next meeting and agree on the remaining changes before Friday.")
            sentence.translationComplete = true
            state.chunks = [sentence]
        }
        if mode == .rapid {
            state.chunks = []
            if !rendering {
                feed = Task { @MainActor in
                    var deadlines: [UUID: Int] = [:]
                    var next = 0
                    for tick in 0..<1200 {
                        guard !Task.isCancelled else { return }
                        for index in state.chunks.indices {
                            let id = state.chunks[index].id
                            if let deadline = deadlines[id], tick >= deadline {
                                state.chunks[index].zh = sample(index).zh
                                state.chunks[index].translationComplete = true
                                deadlines.removeValue(forKey: id)
                            }
                        }
                        if tick % 15 == 0 && next < 60 && deadlines.count < 3 {
                            var chunk = sample(next)
                            chunk.zh = ""
                            chunk.translationComplete = false
                            deadlines[chunk.id] = tick + (next == 3 ? 300 : [18, 36].contains(next) ? 65 : 4 + (next * 17 % 25))
                            state.chunks.append(chunk)
                            next += 1
                            IslandNotchController.shared.noteActivity()
                        }
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    }
                }
            }
        }
        if !rendering && (mode == .scrolling || mode == .desktop) {
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
    static func applySourceOnlyTransition(_ state: CaptionState) {
        state.simulateTranslationPause(.quota)
        state.chunks[0].zh = ""
        state.chunks[0].translationComplete = false
        state.status = tr("额度已用完 · 仅转写")
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
