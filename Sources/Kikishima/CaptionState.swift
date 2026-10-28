// 状态与编排：tap 音频 → 转写 → 切块 → 翻译 → UI
import Foundation
import SwiftUI
import AVFoundation
import AudioToolbox
import Speech
import Translation
import AuthenticationServices

struct CaptionChunk: Identifiable {
    let id = UUID()
    var en: String
    var zh: String = ""
    var isDraft: Bool = false   // true = Apple 本地机翻草稿，等 GPT 定稿替换
    var isMarker: Bool = false  // true = 分隔标记（如「暂停了 5 分钟」），不翻译，记录里单独一行
    let createdAt = Date()      // 延迟计量 + 记录时间戳
    let timingCreatedAt = ProcessInfo.processInfo.systemUptime
    var timingPendingAt: TimeInterval?
    var timingMetadata: TranslationTimingMetadata?
    var sourceFinal = false
    var translationComplete = false
    var previousSource: String?
    var translationAttempts = 0
    var retryAfter = Date.distantPast
    var translationExhausted = false
    var captionFinalized: Bool { translationComplete || translationExhausted }
    var captionTranslation: String { translationExhausted ? "" : displayTranslation }
    var displaySource: String { TranslationText.acknowledgement(en) ?? en }
    var displayTranslation: String { zh.isEmpty || translationComplete ? zh : zh + " …" }
}

/// 音频线程写、主线程读；锁保护整组电平与时间戳，snapshot 一次读取一致状态。
final class AudioMeter: @unchecked Sendable {
    struct Snapshot { let level: Double; let lastLoudAt: CFAbsoluteTime; let lastIOAt: CFAbsoluteTime; let audibleTime: TimeInterval }
    private let lock = NSLock()
    private var level: Double = 0
    private var lastLoudAt: CFAbsoluteTime = 0
    private var lastIOAt: CFAbsoluteTime = 0
    private var lastCalc: CFAbsoluteTime = 0
    private var audibleTime: TimeInterval = 0
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(level: level, lastLoudAt: lastLoudAt, lastIOAt: lastIOAt, audibleTime: audibleTime)
    }
    func reset() { lock.lock(); defer { lock.unlock() }; level = 0; lastLoudAt = CFAbsoluteTimeGetCurrent(); lastIOAt = 0; lastCalc = 0; audibleTime = 0 }
    /// 音频回调里调：取第一路的 RMS，10Hz 节流，每 8 个采样取一个
    func ingest(_ list: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        lock.lock(); defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        lastIOAt = now
        guard now - lastCalc > 0.1, format.commonFormat == .pcmFormatFloat32, list.pointee.mNumberBuffers > 0 else { return }
        let elapsed = lastCalc > 0 ? min(0.25, max(0, now - lastCalc)) : 0
        lastCalc = now
        let buf = list.pointee.mBuffers
        let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
        guard let data = buf.mData, n > 0 else { return }
        let p = data.assumingMemoryBound(to: Float.self)
        var sum: Float = 0
        var i = 0
        while i < n { sum += p[i] * p[i]; i += 8 }
        let rms = sqrt(sum / Float(max(1, n / 8)))
        level = Double(min(1, rms * 6))
        #if DEBUG || SHOOT
        CaptionLevelLog.append(level: level)
        #endif
        if level > 0.02 { lastLoudAt = now; audibleTime += elapsed }
    }
}

/// 字幕状态行：只显示需要用户处理且带动作的错误。保留类型名供现有调用方使用。
struct CaptionBanner: Equatable {
    enum Severity { case info, error }
    enum Action: Equatable {
        case retry, openSettings, settings
        var title: String {
            switch self {
            case .retry, .openSettings: return trAny("修复")
            case .settings: return trAny("打开设置")
            }
        }
    }
    var text: String
    var severity: Severity = .error
    var action: Action? = nil
    var settingsURL: String? = nil
    var shortText: String { CaptionStatusCopy.resolve(fullText: text, translate: { trAny($0) }).shortText }
    var fullText: String { text }
    var showsStatusLine: Bool { severity == .error }
}

/// 字幕位置场景：会议（贴屏幕顶部、摄像头下方，看字幕 = 看镜头）/ 视频（贴底部，像普通字幕）/ 自动（麦克风在用 = 开会）
enum CaptionMode: String, CaseIterable, Identifiable {
    case auto, meeting, video
    var id: String { rawValue }
    var title: String {
        switch self { case .auto: return trAny("自动"); case .meeting: return trAny("会议"); case .video: return trAny("视频") }
    }
    var explain: String {
        switch self {
        case .auto: return trAny("麦克风被占用时判定为会议（字幕在上方），否则当作看视频（字幕贴在发声窗口底部）。")
        case .meeting: return trAny("字幕贴在屏幕顶部、摄像头正下方：读字幕时视线仍对着镜头。")
        case .video: return trAny("字幕贴在正在发声的窗口底部，像视频自带字幕。")
        }
    }
}
enum EffectiveMode { case meeting, video }

/// Producers send immutable request values. Only the MainActor consumer owns
/// mutable status buffers; completion shares the same ordered event stream.
enum TranslationCallbackEvent: Sendable {
    case status(TranslationConnectivityRequest, String)
    case failure(TranslationConnectivityRequest, TranslateFailure)
    case completion(TranslationConnectivityRequest, @MainActor @Sendable () async -> Void)

    var request: TranslationConnectivityRequest {
        switch self {
        case .status(let request, _), .failure(let request, _), .completion(let request, _): return request
        }
    }
}

@MainActor
@Observable
final class CaptionState {
    static let shared = CaptionState()

    @ObservationIgnored let calendarCoordinator = CalendarCoordinator(
        providers: [MacCalendarProvider()]
    )

    init() {
#if SHOOT
        if ShootAudioOnly.requested { return }
#endif
#if SHOOT || DEBUG
        if ShootSimulation.requestedMode != nil { return }
#endif
        // 引擎偏好和已保存的 Key 要在第一次预热前生效。
        translator.engine = translationEngine
        refreshOpenAIKeyHint()
        if let saved = UserDefaults.standard.string(forKey: TranslationEnginePolicy.storageKey),
           let engine = TranslationEnginePolicy.Engine(rawValue: saved) {
            translationEngine = engine
        } else {
            let oldProxy = UserDefaults.standard.object(forKey: "useProxy") as? Bool
            translationEngine = TranslationEnginePolicy.migratedEngine(useProxy: oldProxy, hasKey: hasOpenAIKey)
            UserDefaults.standard.set(translationEngine.rawValue, forKey: TranslationEnginePolicy.storageKey)
        }
        translator.engine = translationEngine
        // 首次启动：界面语言与译文语言跟随系统语言（引导第一页就已是用户的语言，之后由「你最熟悉的语言」页改）
        if uiLanguage.isEmpty {
            let d = UILang.systemDefault
            uiLanguage = d.code
            if UserDefaults.standard.string(forKey: "targetLang") == nil { targetLang = d.prompt }
        }
        // 扩展打招呼（装好 / 浏览器启动 / 打开视频页）：设置页显示「已连接」
        DistributedNotificationCenter.default().addObserver(forName: NativeHost.helloNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.extensionLastHello = Date()
                self?.extensionVersion = UserDefaults.standard.string(forKey: "chromeExtVersion") ?? ""   // 宿主进程刚写的
            }
        }
        UserDefaults.standard.set(false, forKey: "bubbleMode")
    }

    /// Chrome 扩展正在网页上显示字幕（有字幕轨的视频）
    var youtubeActive = false
    var youtubeTitle = ""
    /// 字幕送到网页里显示（扩展要的实时听译）：此时 app 自己的字幕窗不出现
    var captionsToExtension = false
    private var extensionSeq = 0
    /// 扩展最近一次打招呼（本次启动内实时；启动前的从 UserDefaults 兜底）
    var extensionLastHello: Date? = {
        let t = UserDefaults.standard.double(forKey: "chromeHostLastHello")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }()
    /// 24 小时内打过招呼就算装了（扩展只在装好 / 浏览器启动 / 打开视频页时联系 app，不常驻）
    var chromeExtensionConnected: Bool {
        guard let t = extensionLastHello else { return false }
        return Date().timeIntervalSince(t) < 24 * 3600
    }
    /// 装着的扩展版本；比这一版 app 期望的旧就提示去更新
    var extensionVersion: String = UserDefaults.standard.string(forKey: "chromeExtVersion") ?? "" {
        didSet { UserDefaults.standard.set(extensionVersion, forKey: "chromeExtVersion") }
    }
    var extensionOutdated: Bool {
        guard chromeExtensionConnected, !extensionVersion.isEmpty else { return false }
        return extensionVersion.compare(NativeHost.expectedExtensionVersion, options: .numeric) == .orderedAscending
    }
    var extensionLastHelloText: String {
        guard let t = extensionLastHello else { return "" }
        return t.formatted(date: .abbreviated, time: .shortened)
    }

    /// app 只提供会议场景，网页视频由 Chrome 扩展处理；保留字段以便扩展听译时临时贴发声窗口
    var captionMode: CaptionMode = .meeting {
        didSet { applyPlacement(force: true) }   // 不再持久化：这是内部状态，不是用户设置
    }
    private(set) var effectiveMode: EffectiveMode = .meeting
    private var micPollTimer: Timer?
    /// 紧凑字幕：只显示最近两句译文、大字、无原文
    var compactCaptions: Bool = UserDefaults.standard.bool(forKey: "compactCaptions") {
        didSet {
#if SHOOT || DEBUG
            if ShootSimulation.requestedMode != nil { CaptionPanelController.shared.applyAppearance(); return }
#endif
 UserDefaults.standard.set(compactCaptions, forKey: "compactCaptions"); CaptionPanelController.shared.applyAppearance(); applyPlacement(force: true) }
    }
    /// Meeting captions start as a camera-housing island, then expand when text arrives.
    var islandExpanded = false
    var hasIslandContent: Bool {
        errorBanner != nil || paused || !visibleCaptionChunks.isEmpty || !pendingEn.isEmpty || !pendingDraft.isEmpty
    }
    /// 会前 / 会中快速加一条术语（菜单栏弹窗里的一行输入框）：追加到术语表，立即生效
    func addGlossaryTerm(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        glossary = glossary.isEmpty ? t : glossary.trimmingCharacters(in: .newlines) + "\n" + t
    }
    /// 字幕内容：both = 原文 + 译文；translation = 仅译文；source = 仅原文（转写）
    var captionDisplay: String = UserDefaults.standard.string(forKey: "captionDisplay") ?? "both" {
        didSet {
#if SHOOT || DEBUG
            if ShootSimulation.requestedMode != nil { return }
#endif
            UserDefaults.standard.set(captionDisplay, forKey: "captionDisplay")
        }
    }
    var showSource: Bool { captionDisplay != "translation" }
    var showTranslation: Bool { captionDisplay != "source" }
    /// 字幕窗宽度档：small / medium / large（窄 / 中 / 宽）。滑杆每格都重排，播放时会闪。
    var captionWidthLevel: String = CaptionAppearance.storedWidthLevel(
        widthLevel: UserDefaults.standard.string(forKey: CaptionAppearance.widthLevelKey),
        fraction: UserDefaults.standard.object(forKey: "captionWidthFraction") as? Double
    ).rawValue {
        didSet {
            UserDefaults.standard.set(captionWidthLevel, forKey: CaptionAppearance.widthLevelKey)
            CaptionPanelController.shared.applyWidthSelection()
        }
    }
    var captionWidthFraction: Double { CaptionAppearance.widthFraction(CaptionSizeLevel(rawValue: captionWidthLevel) ?? .medium) }
    /// 字幕窗背景不透明度：读取时钳制到 WCAG 计算下限，不回写旧偏好。
    var captionOpacity: Double = CaptionOpacityPolicy.clamped(UserDefaults.standard.object(forKey: "captionOpacity") as? Double ?? CaptionOpacityPolicy.defaultValue) {
        didSet {
            let normalized = CaptionOpacityPolicy.clamped(captionOpacity)
            if captionOpacity != normalized { captionOpacity = normalized }
#if SHOOT || DEBUG
            if ShootSimulation.requestedMode != nil { CaptionPanelController.shared.applyAppearance(); return }
#endif
            UserDefaults.standard.set(captionOpacity, forKey: "captionOpacity")
            CaptionPanelController.shared.applyAppearance()
        }
    }
    /// 紧凑模式点击穿透：字幕窗不拦鼠标（Wakaru 式）。开着就拖不动，用「重置字幕位置」/ 场景切换摆位
    var captionClickThrough: Bool = UserDefaults.standard.bool(forKey: "captionClickThrough") {
        didSet { UserDefaults.standard.set(captionClickThrough, forKey: "captionClickThrough"); CaptionPanelController.shared.applyAppearance() }
    }
    /// Legacy capture preference; turning it off does not guarantee sharing exclusion.
    var captionsVisibleInScreenShare: Bool = UserDefaults.standard.bool(forKey: "captionsInScreenShare") {
        didSet { UserDefaults.standard.set(captionsVisibleInScreenShare, forKey: "captionsInScreenShare"); CaptionPanelController.shared.applySharing() }
    }
    /// 字幕长度档：short / medium / long（默认 medium）。越长越连贯，每句晚出 1～2 秒
    var chunkLength: String = UserDefaults.standard.string(forKey: "chunkLength") ?? "medium" {
        didSet { UserDefaults.standard.set(chunkLength, forKey: "chunkLength") }
    }
    private var tuning: ChunkTuning { ChunkTuning.named(chunkLength) }
    /// 主窗口当前分区（菜单「设置…」/ 未登录提示要切过去）
    var mainSection: MainSection? = .captions

    /// 正在采集麦克风的进程（Zoom/Meet 开会一定开麦；看视频不会）。字幕窗会落在这些进程的窗口所在的屏幕
    /// 不看默认输入设备的 IsRunningSomewhere：AirPods/USB 耳机是同一个设备，放视频也算「在跑」，我们自己的 tap 聚合设备也会命中
    nonisolated static func micUsers() -> [pid_t] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objs) == noErr else { return [] }
        let me = getpid()
        var pids: [pid_t] = []
        for o in objs {
            var pidAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0; var psz = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(o, &pidAddr, 0, nil, &psz, &pid) == noErr, pid != me, pid > 0 else { continue }
            var inAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0; var rsz = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(o, &inAddr, 0, nil, &rsz, &running) == noErr, running != 0 { pids.append(pid) }
        }
        return pids
    }
    nonisolated static func micInUse() -> Bool { !micUsers().isEmpty }

    /// 计算当前应生效的场景，变化时挪字幕窗
    /// force = 用户明确切场景 / 重置（会覆盖用户拖过的位置）；always = 开始字幕时按场景摆一次，但尊重用户拖过的位置
    func applyPlacement(force: Bool = false, always: Bool = false) {
        let target: EffectiveMode
        switch captionMode {
        case .meeting: target = .meeting
        case .video: target = .video
        case .auto: target = Self.micInUse() ? .meeting : .video
        }
        if target != effectiveMode || force || always {
            let wasIsland = usesIslandCaptions
            effectiveMode = target
            if wasIsland != usesIslandCaptions {
                CaptionPanelController.shared.switchSurface(showIfRunning: false, force: force)
            }
            CaptionPanelController.shared.place(for: target, force: force)
        }
    }

    private var pollTick = 0
    /// 运行期唯一的轮询 timer（0.25 秒）：电平 / 静音 / 停摆；每 2 秒场景判定与跟随发声窗口；每 60 秒刷一次额度（会中剩余分钟也在动）
    private func startMicPolling() {
        micPollTimer?.invalidate()
        pollTick = 0
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running else { return }
                self.pollTick += 1
                if !self.paused { self.pollMeter() }
                self.updateTranslationConnectivity()
                if self.pollTick % 8 == 0 {
                    if self.captionMode == .auto { self.applyPlacement() }
                    if self.effectiveMode == .video { CaptionPanelController.shared.followSourceIfMoved() }
                    else if self.usesIslandCaptions { CaptionPanelController.shared.place(for: .meeting) }
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        micPollTimer = t
    }
    private func stopMicPolling() { micPollTimer?.invalidate(); micPollTimer = nil }

    var chunks: [CaptionChunk] = []
    var pendingEn: String = "" {   // 未翻的定稿尾巴 + volatile 未定稿
        didSet { if pendingEn.isEmpty { pendingClock = PendingTextClock() } }
    }
    var running = false { didSet { updateTranslationConnectivity() } }
    var starting = false           // start() 已发出、tap/引擎尚未就绪：期间再按 = 取消
    private var statusMessage: String?
    // Resolve the idle status after uiLanguage exists, without reading shared during init.
    var status: String {
        get { statusMessage ?? (L10nTables.table(uiLanguage)["就绪"] ?? "就绪") }
        set {
            statusMessage = newValue
            if CaptionStatusCopy.resolve(fullText: newValue, translate: { tr($0) }).isSaveFailure {
                errorStatusVisibility.receive()
            }
        }
    }
    var errorBanner: CaptionBanner? {
        didSet { errorStatusVisibility.receive() }
    }
    private var errorStatusVisibility = CaptionErrorStatusVisibility()
    var desktopErrorStatus: CaptionBanner? {
        guard errorStatusVisibility.isVisible else { return nil }
        return errorBanner.flatMap { $0.showsStatusLine ? $0 : nil }
    }
    func dismissDesktopErrorStatus() {
        if desktopErrorStatus != nil { errorStatusVisibility.dismiss() }
        else if audioRepairStatus != nil { audioRepairVisibility.dismiss() }
        else if CaptionStatusCopy.resolve(fullText: status, translate: { tr($0) }).isSaveFailure { errorStatusVisibility.dismiss() }
        else { noticeVisibility.dismiss(captionDisplayStatus) }
    }
    var translationConnectivity = TranslationConnectivityPolicy()
    var translationOffline: Bool { translationConnectivity.isOffline }
    var offlineStatus: CaptionBanner? {
        translationOffline ? CaptionBanner(text: tr("离线，正在重连"), severity: .info) : nil
    }
    var audioInterruption: CaptionAudioInterruption = .none {
        didSet {
            if oldValue != audioInterruption { audioRepairVisibility.receive() }
        }
    }
    private var audioRepairVisibility = CaptionErrorStatusVisibility()
    private var noticeVisibility = CaptionNoticeVisibility()
    var audioRepairStatus: CaptionBanner? {
        guard audioRepairVisibility.isVisible, audioInterruption.requiresRepair,
              let text = audioInterruption.sourceText else { return nil }
        return CaptionBanner(text: tr(text), action: .openSettings, settingsURL: audioInterruption.settingsURL)
    }
    var selectedCaptionError: CaptionBanner? {
        if var existing = desktopErrorStatus {
            // Keep KK-034's error text first. A known capture cause makes Fix
            // open its settings instead of blindly restarting capture.
            if existing.action == .retry, let repair = audioRepairStatus {
                existing.action = .openSettings
                existing.settingsURL = repair.settingsURL
            }
            return existing
        }
        if let repair = audioRepairStatus { return repair }
        let copy = CaptionStatusCopy.resolve(fullText: status, translate: { tr($0) })
        return copy.isSaveFailure && errorStatusVisibility.isVisible ? CaptionBanner(text: status) : nil
    }
    var desktopCaptionStatusBanner: CaptionBanner? {
        noticeVisibility.isVisible(captionDisplayStatus) ? captionStatusBanner : nil
    }
    var canDismissDesktopCaptionStatus: Bool {
        desktopCaptionStatusBanner != nil && captionDisplayStatus != .offline
    }
    var captionDisplayStatus: CaptionStatusPriority {
        CaptionStatusPriority.resolve(hasError: selectedCaptionError != nil,
            offline: translationOffline, silentTooLong: silentTooLong,
            audioStalled: audioStalled, running: running, paused: paused,
            sourceOnly: CaptionStatusCopy.resolve(fullText: selectedCaptionError?.text ?? status, translate: { tr($0) }).isSourceOnly)
    }
    var captionStatusText: String {
        if captionDisplayStatus == .error || captionDisplayStatus == .sourceOnly { return selectedCaptionError?.text ?? status }
        return captionDisplayStatus.sourceText.map { tr($0) } ?? status
    }
    var captionStatusShortText: String { CaptionStatusCopy.resolve(fullText: captionStatusText, translate: { tr($0) }).shortText }
    var captionStatusBanner: CaptionBanner? {
        if captionDisplayStatus == .error { return selectedCaptionError }
        // Presentation only: keep the original banner action for menu/full error UI.
        if captionDisplayStatus == .sourceOnly { return CaptionBanner(text: captionStatusText, severity: .info) }
        return captionDisplayStatus.isWarning ? CaptionBanner(text: captionStatusText, severity: .info) : nil
    }
    private var connectivityAvailable: Bool {
        running && !paused && !translationPaused
    }
    private var connectivityEnabled: Bool {
        connectivityAvailable && (rateLimitedUntil.map { $0 <= Date() } ?? true)
    }
    private func updateTranslationConnectivity() {
        translationConnectivity.advance(audioTime: meter.snapshot().audibleTime, enabled: connectivityEnabled)
    }
    private func translationSucceeded() {
        updateTranslationConnectivity()
        translationConnectivity.succeeded(audioTime: meter.snapshot().audibleTime)
    }
    private func translationFailed(chunk: UUID?) {
        updateTranslationConnectivity()
        if let chunk { translationConnectivity.failed(chunk: chunk, enabled: connectivityAvailable) }
    }
    /// 翻译暂停（额度用完 / 需订阅 / 会话失效）：继续转写显示原文，不再发请求
    var translationPaused = false { didSet { updateTranslationConnectivity() } }
    enum PauseReason { case quota, payment, freePool, session, key, local }
    private(set) var pauseReason: PauseReason?
    private var pausedAt: Date?
    private func pause(_ r: PauseReason) { translationPaused = true; pauseReason = r; pausedAt = Date() }
    #if SHOOT || DEBUG
    func simulateTranslationPause(_ reason: PauseReason) { pause(reason) }
#endif
    private func unpause() { translationPaused = false; pauseReason = nil; pausedAt = nil }
    /// 会话代数：stop/start 各 +1；异步回调用它判断自己是否已过期
    private var sessionGen = 0
    var sessionGeneration: Int { sessionGen }
    @ObservationIgnored private let transcriptWriter = TranscriptWriter()
    @ObservationIgnored private let meetingSessionContext = MeetingSessionContext()
    @ObservationIgnored private let meetingSummaryStore = MeetingSummaryStore()
    @ObservationIgnored private lazy var meetingSummaryCoordinator = MeetingSummaryCoordinator(
        client: LocalMeetingSummaryClient(
            engine: {
                UserDefaults.standard.string(forKey: TranslationEnginePolicy.storageKey)
                    .flatMap(TranslationEnginePolicy.Engine.init(rawValue:)) ?? .apple
            },
            openAIKey: { KeychainStore.loadKey() }
        ),
        store: meetingSummaryStore,
        onChange: { snapshot in
            Task { @MainActor in
                let state = CaptionState.shared
                let generation: Int?
                switch snapshot.state {
                case .idle: generation = nil
                case .active(let value), .finalizing(let value), .finished(let value), .failed(let value, _): generation = value
                }
                if generation == state.meetingSummaryGeneration {
                    state.meetingSummarySnapshot = snapshot
                } else {
                    state.summaryDiskRevision += 1
                }
            }
        }
    )
    @ObservationIgnored private var meetingSummaryBuffer: MeetingSummaryLifecycleBuffer?
    @ObservationIgnored private var meetingSummaryIngressTask: Task<Void, Never>?
    @ObservationIgnored private var meetingSummaryFinalizationTask: Task<Void, Never>?
    @ObservationIgnored private var meetingSummaryRetryTask: Task<Void, Never>?
    @ObservationIgnored private var finalTranscriptTask: Task<Result<URL?, Error>, Never>?
    private var busySummaryRecordIDs: Set<String> = []
    private var meetingSummaryFinalizationOwner: Int?
    private var finalTranscriptOwner: Int?
    private var meetingSummaryGeneration: Int?
    // Summary retries allocate an owner without invalidating translation callbacks.
    private var meetingSummaryRetryGeneration = 0
    private var meetingSummaryRecordID: String?
    private var meetingSummarySessionBegan = false
    private var lastMeetingSummaryEvaluationAt: Date?
    private(set) var meetingSummarySnapshot: MeetingSummaryCoordinatorSnapshot?
    /// Bumped when a previous meeting's sidecar may have changed while a newer
    /// session owns `meetingSummarySnapshot`, so History can reload from disk.
    private(set) var summaryDiskRevision = 0
    private(set) var transcriptDiskRevision = 0
    var captionFontLevel: String = CaptionAppearance.storedFontLevel(
        fontLevel: UserDefaults.standard.string(forKey: CaptionAppearance.fontLevelKey),
        fontPoints: UserDefaults.standard.double(forKey: "zhFont")
    ).rawValue {
        didSet { UserDefaults.standard.set(captionFontLevel, forKey: CaptionAppearance.fontLevelKey) }
    }
    var zhFontSize: Double { CaptionAppearance.fontSize(CaptionSizeLevel(rawValue: captionFontLevel) ?? .medium) }
    /// 字幕落在哪：island = 摄像头下的岛；window = 普通桌面浮窗（可拖、可改大小、贴屏幕底部）
    var captionSurface: String = CaptionSurfacePreference.load(from: .standard) {
        didSet {
#if SHOOT || DEBUG
            if ShootSimulation.requestedMode != nil { CaptionPanelController.shared.switchSurface(); return }
#endif
 UserDefaults.standard.set(captionSurface, forKey: "captionSurface"); CaptionPanelController.shared.switchSurface() }
    }
    func selectCaptionSurface(_ value: String) {
#if SHOOT || DEBUG
        if ShootSimulation.requestedMode != nil { captionSurface = value; return }
#endif
        CaptionSurfacePreference.select(value, in: .standard)
        captionSurface = value
    }
    var usesIslandCaptions: Bool {
        effectiveMode == .meeting && CaptionSurfacePreference.usesIsland(surface: captionSurface)
    }
    var supportsIslandSizing: Bool {
        usesIslandCaptions
    }
    /// 字幕字体族：system / rounded / serif / mono（中日韩由系统按族回落到苹方 / 圆体等）
    var captionFontFamily: String = UserDefaults.standard.string(forKey: "captionFontFamily") ?? "system" {
        didSet { UserDefaults.standard.set(captionFontFamily, forKey: "captionFontFamily") }
    }
    func captionFont(_ size: Double, weight: Font.Weight = .regular) -> Font {
        let design: Font.Design = switch captionFontFamily {
        case "rounded": .rounded
        case "serif": .serif
        case "mono": .monospaced
        default: .default
        }
        return .system(size: size, weight: weight, design: design)
    }
    /// 岛展开高度档：small / medium / large（低 / 中 / 高）
    var islandHeightLevel: String = CaptionAppearance.storedHeightLevel(
        heightLevel: UserDefaults.standard.string(forKey: CaptionAppearance.heightLevelKey),
        points: UserDefaults.standard.object(forKey: "islandHeight") as? Double
    ).rawValue {
        didSet {
            UserDefaults.standard.set(islandHeightLevel, forKey: CaptionAppearance.heightLevelKey)
            applyCaptionGeometry()
        }
    }
    var islandHeight: Double { CaptionAppearance.islandHeight(CaptionSizeLevel(rawValue: islandHeightLevel) ?? .medium) }
    /// 岛：无人说话后收回胶囊。off = 不收。有横幅 / 暂停时不收
    var islandCollapseLevel: String = CaptionAppearance.storedCollapseLevel(
        collapseLevel: UserDefaults.standard.string(forKey: CaptionAppearance.collapseLevelKey),
        seconds: UserDefaults.standard.object(forKey: "islandAutoCollapse") as? Double
    ).rawValue {
        didSet {
            UserDefaults.standard.set(islandCollapseLevel, forKey: CaptionAppearance.collapseLevelKey)
            islandDormant = false
            IslandNotchController.shared.noteActivity()
        }
    }
    var islandAutoCollapseSeconds: Double { CaptionAppearance.collapseSeconds(CaptionCollapseLevel(rawValue: islandCollapseLevel) ?? .medium) }
    var islandDormant = false   // 自动收回中（有新句就翻回 false）
    var wantsIslandExpanded: Bool {
#if SHOOT || DEBUG
        if ShootSimulation.requestedIslandExpanded { return true }
#endif
        return CaptionAppearance.wantsExpanded(hasContent: hasIslandContent, dormant: islandDormant,
            paused: paused, hasBanner: errorBanner != nil)
    }
    var model: String = UserDefaults.standard.string(forKey: "model") ?? "gpt-5.6-luna" {
        didSet {
#if SHOOT || DEBUG
            if ShootSimulation.requestedMode != nil { return }
#endif
 UserDefaults.standard.set(model, forKey: "model"); if !finishingCaptions { translator.model = model } }
    }
    var localeID: String = UserDefaults.standard.string(forKey: "locale") ?? "en_US" {
        didSet { UserDefaults.standard.set(localeID, forKey: "locale") }
    }
    /// 界面语言偏好（onboarding 第一问「你最熟悉的语言」）：zh-Hans / zh-Hant / ja / en / ko。五语 UI 落地后据此切界面
    var uiLanguage: String = UserDefaults.standard.string(forKey: "uiLanguage") ?? "" {
        didSet { AppLanguagePreference.persist(uiLanguage) }
    }
    /// 常用会议语言（onboarding 第二问，多选，locale id）；第一个作默认会议语言，全部预下载模型
    var meetingLocales: [String] = UserDefaults.standard.stringArray(forKey: "meetingLocales") ?? [] {
        didSet { UserDefaults.standard.set(meetingLocales, forKey: "meetingLocales") }
    }
    /// 各 locale 转写模型下载进度；安装状态单独从 Speech 查询。
    var modelProgress: [String: Double] = [:]
    private var installedModelLocales: Set<String> = []
    private var predownloadTask: Task<Void, Never>?

    /// 选了会议语言就立刻后台下载模型（默认开）；关掉 = 开始字幕时再按需下载当前语言
    var autoDownloadModels: Bool = UserDefaults.standard.object(forKey: "autoDownloadModels") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoDownloadModels, forKey: "autoDownloadModels")
            if autoDownloadModels { predownloadModels(OnboardingController.needed ? [localeID] : meetingLocales) } else { predownloadTask?.cancel(); predownloadTask = nil; for (k, v) in modelProgress where v < 1 { modelProgress[k] = nil } }
        }
    }
    /// 只认系统实际安装的模型；进度完成或选中了语言均不能代替安装状态。
    func modelReady(_ locale: String) -> Bool {
        installedModelLocales.contains(TranscribeEngine.modelLocaleKey(locale))
    }

    func refreshModelInstallation() async {
        installedModelLocales = await TranscribeEngine.installedModelLocales()
    }

    /// Remove immediately; a failed asynchronous release never restores the row.
    func removeMeetingLocale(_ identifier: String) {
        meetingLocales.removeAll { $0 == identifier }
        modelProgress[identifier] = nil
#if SHOOT || DEBUG
        if ShootSimulation.requestedMode != nil { return }
#endif
        Task {
            let key = TranscribeEngine.modelLocaleKey(identifier)
            guard !meetingLocales.contains(where: { TranscribeEngine.modelLocaleKey($0) == key }) else { return }
            _ = await TranscribeEngine.releaseModelLocale(identifier)
            await refreshModelInstallation()
        }
    }

    /// 后台预下载所选会议语言的转写模型（不阻塞引导，可重复调用；正在下载的不重复起）
    func predownloadModels(_ locales: [String]) {
        guard autoDownloadModels else { return }
        let todo = locales.filter { !modelReady($0) && modelProgress[$0] == nil }
        guard !todo.isEmpty else { return }
        for l in todo { modelProgress[l] = 0 }
        predownloadTask = Task {
            for l in todo {
                guard !Task.isCancelled else { return }
                let transcriber = SpeechTranscriber(locale: Locale(identifier: l), transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
                do {
                    if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                        let obs = req.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
                            Task { @MainActor in
                                let state = CaptionState.shared
                                if state.modelProgress[l] != nil {
                                    state.modelProgress[l] = min(0.99, p.fractionCompleted)
                                }
                            }
                        }
                        defer { obs.invalidate() }
                        try await req.downloadAndInstall()
                    }
                    await refreshModelInstallation()
                    modelProgress[l] = nil
                } catch {
                    modelProgress[l] = nil   // 失败：允许再试
                }
            }
        }
    }
    // 术语表：每行一条。纯词条 = 保留原文（人名/项目名）；「原词 → 译法」= 指定译法
    var glossary: String = UserDefaults.standard.string(forKey: "glossary") ?? "" {
        didSet {
#if SHOOT || DEBUG
            if ShootSimulation.requestedMode != nil { return }
#endif

            UserDefaults.standard.set(glossary, forKey: "glossary")
            meetingSessionContext.updatePermanentGlossary(glossary)
            if !finishingCaptions { translator.glossary = meetingSessionContext.effectiveGlossary }
        }
    }
    // 目标语言（英文名进 prompt）
    var targetLang: String = UserDefaults.standard.string(forKey: "targetLang") ?? "Simplified Chinese" {
        didSet {
#if SHOOT || DEBUG
            if ShootSimulation.requestedMode != nil { return }
#endif
 UserDefaults.standard.set(targetLang, forKey: "targetLang"); if !finishingCaptions { translator.targetLanguage = targetLang } }
    }
    var summaryConsent: MeetingSummaryConsent = MeetingSummaryConsent(
        rawValue: UserDefaults.standard.string(forKey: "meetingSummaryConsent") ?? ""
    ) ?? .undecided {
        didSet { UserDefaults.standard.set(summaryConsent.rawValue, forKey: "meetingSummaryConsent") }
    }
    var meetingSummariesEnabled: Bool = UserDefaults.standard.bool(forKey: "meetingSummaryEnabled") {
        didSet { UserDefaults.standard.set(meetingSummariesEnabled, forKey: "meetingSummaryEnabled") }
    }
    var summaryAliasesText: String = UserDefaults.standard.string(forKey: "meetingSummaryAliases") ?? "" {
        didSet { UserDefaults.standard.set(summaryAliasesText, forKey: "meetingSummaryAliases") }
    }
    var summaryAliases: [String] { MeetingSummaryPreferences.normalizedAliases(from: summaryAliasesText) }
    func setMeetingSummariesEnabled(_ enabled: Bool) {
        summaryConsent = enabled ? .enabled : .disabled
        meetingSummariesEnabled = enabled
    }
    // 翻译引擎：本机 Apple（默认）/ 可选 MLX / 自带 OpenAI Key。
    var translationEngine: TranslationEnginePolicy.Engine = .apple {
        didSet {
#if SHOOT || DEBUG
            if ShootSimulation.requestedMode != nil { return }
#endif
            UserDefaults.standard.set(translationEngine.rawValue, forKey: TranslationEnginePolicy.storageKey)
            translator.engine = translationEngine
        }
    }
    /// Legacy flag kept for code paths that still mention the hosted service.
    /// The local-first build never routes translation through Kikishima.
    var useProxy: Bool { false }
    /// 只保留掩码提示，界面不回显全文，也不把 Key 写进日志。
    private(set) var openAIKeyHint = ""
    var hasOpenAIKey: Bool { !openAIKeyHint.isEmpty }

    func refreshOpenAIKeyHint() {
        openAIKeyHint = TranslationEnginePolicy.maskedHint(KeychainStore.loadKey())
    }

    func selectTranslationEngine(_ engine: TranslationEnginePolicy.Engine) {
        guard translationEngine != engine else { return }
        translationEngine = engine
        if engine == .openAI, !hasOpenAIKey, running || starting {
            pause(.key)
            errorBanner = CaptionBanner(text: tr("还没有填写 OpenAI API Key，翻译已暂停"), action: .settings)
            status = tr("缺少 OpenAI Key")
        } else if engine != .openAI, pauseReason == .key {
            clearUpgradePause()
        }
    }

    private func clearUpgradePause() {
        unpause()
        if errorBanner?.action == .settings { errorBanner = nil }
        retryFailedChunks()
    }

    /// 返回 false 表示粘贴的内容不像一个可用的 Key。
    @discardableResult
    func saveOpenAIKey(_ raw: String) -> Bool {
        let key = TranslationEnginePolicy.normalizedKey(raw)
        guard TranslationEnginePolicy.isValidKey(key) else { return false }
        Keychain.saveKey(key)
        refreshOpenAIKeyHint()
        if pauseReason == .key { clearUpgradePause() }
        return true
    }

    func clearOpenAIKey() {
        Keychain.deleteKey()
        openAIKeyHint = ""
        guard translationEngine == .openAI, running || starting else { return }
        pause(.key)
        errorBanner = CaptionBanner(text: tr("还没有填写 OpenAI API Key，翻译已暂停"), action: .settings)
        status = tr("缺少 OpenAI Key")
    }

    private func pauseForInvalidOpenAIKey() {
        pause(.key)
        errorBanner = CaptionBanner(text: tr("OpenAI API Key 无效或已撤销，更新 Key 后继续翻译"), action: .settings)
        status = tr("OpenAI Key 无效")
    }
    /// 横幅动作
    func performBanner(_ action: CaptionBanner.Action) {
        switch action {
        case .retry:
            if finishingCaptions { return }
            // retry now belongs only to actionable capture/engine errors.
            // Incomplete translations must not redirect Fix into transcript retry.
            if !running && !starting { toggle(); return }          // 启动失败 / 已停止：重新开始
            if !tap.isRunning {                                     // 设备切换后 tap 没起来：再试一次
                do { try startTap(); status = tr("音频已恢复"); errorBanner = nil }
                catch { errorBanner = CaptionBanner(text: tr("音频仍无法捕获：%@", error.localizedDescription), action: .retry) }
                return
            }
            for index in chunks.indices where !chunks[index].translationComplete {
                chunks[index].translationAttempts = 0; chunks[index].retryAfter = .distantPast
            }
            if pauseReason == .key {
                if hasOpenAIKey { clearUpgradePause() }
            } else {
                retryFailedChunks()
            }
        case .openSettings:
            if let url = URL(string: selectedCaptionError?.settingsURL ?? "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                NSWorkspace.shared.open(url)
            }
        case .settings:
            AppDelegate.enter(section: .settings)
        }
    }

    private let tap = SystemAudioTap()
    private let engine = TranscribeEngine()
#if SHOOT || DEBUG
    @ObservationIgnored private lazy var translator = Translator()
#else
    private var translator = Translator()
#endif

    // Apple 本地机翻草稿层：session 只能活在 translationTask 闭包里，用流转发请求
    // 草稿层用本机翻译处理正在说的句子，GPT 正式译文到达后替换灰色草稿
    var translationConfig: TranslationSession.Configuration?
    /// Apple 本地翻译草稿已关闭，避免低质量草稿与正式译文交替干扰阅读；保留代码但不接 UI
    let instantDraft = false
    /// 正在说的这句（pendingEn）的草稿译文，灰色显示在译文位
    var pendingDraft = ""
    static let pendingDraftID = UUID()
    private var lastDraftReq: (text: String, at: Date)?
    private var draftContinuation: AsyncStream<(UUID, String)>.Continuation?
    @ObservationIgnored private(set) lazy var draftRequests: AsyncStream<(UUID, String)> = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { [weak self] cont in self?.draftContinuation = cont }

    private func makeDraftConfig() -> TranslationSession.Configuration? {
        let src = localeID.split(separator: "_").first.map(String.init) ?? localeID
        let dst = targetCode(targetLang)
        guard src != dst else { return nil }
        return TranslationSession.Configuration(source: Locale.Language(identifier: src), target: Locale.Language(identifier: dst))
    }

    /// 待翻文本变了就请求一版草稿：≥4 字、与上次不同、间隔 ≥0.5 秒；说到一半停顿时 0.55 秒后补一次，尾巴不丢
    private func scheduleDraft() {
        guard instantDraft, translationConfig != nil, running, !paused, showTranslation else { return }
        let text = pendingEn
        if text.count < 4 { pendingDraft = ""; lastDraftReq = nil; return }
        if let last = lastDraftReq {
            if last.text == text { return }
            if Date().timeIntervalSince(last.at) < 0.5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in self?.scheduleDraft() }
                return
            }
        }
        lastDraftReq = (text, Date())
        draftContinuation?.yield((Self.pendingDraftID, text))
    }

    /// 草稿到了：pendingDraftID = 正在说的这句；其他 id = 某个块（现未使用）
    func applyDraft(_ id: UUID, for source: String, _ zh: String) {
        if id == Self.pendingDraftID {
            // 待翻文本还是那句（或在它基础上继续说）才用；已经切块走人的丢掉
            guard !pendingEn.isEmpty, pendingEn.hasPrefix(source) || source.hasPrefix(pendingEn) else { return }
            pendingDraft = zh
            return
        }
        guard let idx = chunks.firstIndex(where: { $0.id == id }), chunks[idx].zh.isEmpty else { return }
        chunks[idx].zh = zh
        chunks[idx].isDraft = true
        lastDraftMs = Int(Date().timeIntervalSince(chunks[idx].createdAt) * 1000)
    }

    // 延迟仪表（调试用，菜单不再显示毫秒）
    private(set) var lastDraftMs: Int?
    private(set) var lastFinalMs: Int?
    private let timingRecorder = TranslationTimingRecorder.shared
    private var pendingClock = PendingTextClock()
    private var translationClock = PendingTextClock()
    private var sourceLedger = TranslationSourceLedger()
    private var asrSourceLedger: ASRSourceLedger?
    private var activeTranslationAttempts: [UUID: UUID] = [:]
    @ObservationIgnored private var translationCallbackContinuation: AsyncStream<TranslationCallbackEvent>.Continuation?
    @ObservationIgnored private var translationCallbackTask: Task<Void, Never>?

    /// Compress only adjacent identical pure acknowledgements in a short window.
    /// Original records retain every source chunk; a question/content/marker resets it.
    var visibleCaptionChunks: [CaptionChunk] {
        var result: [CaptionChunk] = []
        var previous: CaptionChunk?
        for chunk in chunks.suffix(120) {
            let duplicate = previous.map { prior in
                !chunk.isMarker && !prior.isMarker && chunk.translationComplete && prior.translationComplete &&
                TranslationText.repeatedAcknowledgement(chunk.en, after: prior.en,
                    interval: chunk.createdAt.timeIntervalSince(prior.createdAt))
            } ?? false
            if !duplicate { result.append(chunk) }
            previous = chunk
        }
        return result
    }
    var compactCaptionChunks: [CaptionChunk] { Array(visibleCaptionChunks.suffix(2)) }

    var latencyText: String {
        var parts: [String] = []
        if let d = lastDraftMs { parts.append("草稿 \(d)ms") }
        if let f = lastFinalMs { parts.append("定稿 \(f)ms") }
        return parts.joined(separator: " · ")
    }
    private func updateRunningStatus() {
        guard running, !paused, !switchingMeetingLanguage else { return }
        status = tr("字幕运行中")
    }

    // 定稿原文累积 + 已翻位置
    private var committedEn = ""
    private var doneChars = 0
    private var volatileEn = "" {
        didSet {
            if volatileEn.isEmpty {
                stableVolatilePrefix = ""
                lastVolatileEn = ""
                pauseCutRequested = false
                if committedEn.isEmpty { translationClock = PendingTextClock() }
            }
        }
    }
    // LocalAgreement: only the prefix two consecutive volatile results agree on
    // may enter the translation source. The unstable tail stays preview-only.
    private var stableVolatilePrefix = ""
    private var lastVolatileEn = ""
    // A long enough silence asks tickChunks to flush the agreed tail at an
    // acoustic boundary instead of waiting for text stability.
    private var pauseCutRequested = false
    private var inflight = 0
    private var chunkTimer: Timer?
    private var startTask: Task<Void, Never>?
    private var activityToken: NSObjectProtocol?
    private var sessionStartedAt: Date?
    private var meetingLanguageTimeline = MeetingLanguageTimeline(initialLocaleID: "en_US")
    private var translationRetryQueue = TranslationRetryQueue()
    private var rateLimitedUntil: Date?

    /// 全局快捷键 / 菜单调用：开关字幕 + 悬浮窗
    func toggle() {
        switch SessionControls.hotkeyAction(running: running, starting: starting, paused: paused, resuming: resuming) {
        case .resume:
            resume()
        case .stop:
            stop()
            CaptionPanelController.shared.hide()
        case .start:
            startCaptionSession()
        }
    }

    /// Trial and normal UI starts share the meter/silence lifecycle.
    @discardableResult
    func startCaptionSession(showPanel: Bool = true) -> Bool {
        guard start() else { return false }
        if showPanel {
            CaptionPanelController.shared.show()
            applyPlacement(always: true)
        }
        startMicPolling()
        return true
    }

    // ==== 会中暂停 / 继续：休息、私聊、不想被记的片段。不结束会话、记录不切成两个文件 ====
    var paused = false { didSet { updateTranslationConnectivity() } }
    /// True while resume() is restarting the transcriber; a second Continue must no-op.
    private(set) var resuming = false
    private(set) var switchingMeetingLanguage = false
    private var pausedSince: Date?
    private var resumeTask: Task<Void, Never>?
    private var resumeStart = ExclusiveEngineStart()
    private var languageSwitchTask: Task<Void, Never>?
    /// Bumped when the transcriber is replaced so late ASR callbacks cannot land on a new engine.
    private var engineEpoch = 0

    func pause() {
#if SHOOT || DEBUG
        if ShootSimulation.requestedMode != nil { ShootSimulation.pause(self); return }
#endif
        guard running, !paused else { return }
        guard SessionControls.canPause(switchingMeetingLanguage: switchingMeetingLanguage, resuming: resuming) else { return }
        restartTask?.cancel(); restartTask = nil
        deviceChangeWork?.cancel()
        paused = true
        pausedSince = Date()
        engineEpoch += 1
        // 停 tap 与引擎（引擎会把尾巴吐完），在途翻译照常完成；chunks / 记录文件 / 代数都保留
        tap.stop()
        flushPendingTail(translate: true)
        engine.stop()
        volatileEn = ""; pendingEn = ""
        audioLevel = 0; silentTooLong = false; audioStalled = false
        status = tr("已暂停")
        scheduleTranscriptSave()
    }

    func resume() {
#if SHOOT || DEBUG
        if ShootSimulation.requestedMode != nil { ShootSimulation.resume(self); return }
#endif
        guard running, paused, !switchingMeetingLanguage else { return }
        guard resumeStart.begin() else { return }
        restartTask?.cancel(); restartTask = nil
        resuming = true
        engineEpoch += 1
        let gen = sessionGen
        let epoch = engineEpoch
        let mins = pausedSince.map { max(1, Int(Date().timeIntervalSince($0) / 60 + 0.5)) } ?? 0
        pausedSince = nil
        // 记录里留一条分隔：暂停了几分钟（不翻译）
        var marker = CaptionChunk(en: tr("（暂停了 %@ 分钟）", mins))
        marker.isMarker = true
        chunks.append(marker)
        committedEn = ""; volatileEn = ""; doneChars = 0; pendingEn = ""; sourceLedger = TranslationSourceLedger()
        asrSourceLedger = nil
        status = tr("继续中…")
        resumeTask = Task {
            defer {
                if self.sessionGen == gen {
                    self.resumeStart.end()
                    self.resuming = false
                    self.resumeTask = nil
                }
            }
            do {
                try await engine.start(localeID: localeID) { [weak self] event in
                    guard let self, self.sessionGen == gen, self.engineEpoch == epoch else { return }; self.handle(event, resultGeneration: gen)
                }
                try Task.checkCancellation()
                guard running, sessionGen == gen else { engine.stop(); return }
                meter.reset()
                try startTap()
                paused = false
                updateRunningStatus()
            } catch {
                let cancelled = error is CancellationError || Task.isCancelled
                guard ExclusiveEngineStart.shouldStopMeeting(
                    cancelled: cancelled,
                    sessionStillCurrent: sessionGen == gen
                ) else { return }
                errorBanner = CaptionBanner(text: tr("无法继续：%@", error.localizedDescription), action: .retry)
                stop(reason: tr("继续失败，已停止"))
            }
        }
    }

    /// 会前直接改默认语言；会中只重启转写引擎，保留同一份字幕、记录与会议总结。
    func selectMeetingLanguage(_ newLocaleID: String) {
#if SHOOT || DEBUG
        if ShootSimulation.requestedMode != nil { localeID = newLocaleID; return }
#endif
        guard newLocaleID != localeID,
              SessionControls.canChangeMeetingLanguage(
                starting: starting,
                switchingMeetingLanguage: switchingMeetingLanguage,
                resuming: resuming
              ) else { return }
        if !running {
            localeID = newLocaleID
            if autoDownloadModels { predownloadModels([newLocaleID]) }
            return
        }

        if paused {
            localeID = newLocaleID
            if meetingLanguageTimeline.recordSwitch(to: newLocaleID) != nil {
                var marker = CaptionChunk(en: tr("已切换为%@", localeName(newLocaleID)))
                marker.isMarker = true
                chunks.append(marker)
                scheduleTranscriptSave()
            }
            return
        }

        let generation = sessionGen
        restartTask?.cancel(); restartTask = nil
        switchingMeetingLanguage = true
        engineEpoch += 1
        let epoch = engineEpoch
        status = tr("正在切换为%@…", localeName(newLocaleID))
        tap.stop()
        flushPendingTail(translate: true)
        engine.stop()
        volatileEn = ""; pendingEn = ""
        // Reset the ledger now, not after the new engine starts. tickChunks can
        // fire on the next runloop while the model is still downloading.
        committedEn = ""; doneChars = 0; pendingEn = ""; sourceLedger = TranslationSourceLedger()
        asrSourceLedger = nil
        audioLevel = 0; silentTooLong = false; audioStalled = false

        languageSwitchTask = Task {
            defer {
                if self.sessionGen == generation {
                    self.languageSwitchTask = nil
                }
            }
            do {
                try await engine.start(localeID: newLocaleID) { [weak self] event in
                    guard let self, self.sessionGen == generation, self.engineEpoch == epoch else { return }
                    self.handle(event, resultGeneration: generation)
                }
                try Task.checkCancellation()
                guard running, sessionGen == generation, switchingMeetingLanguage else {
                    engine.stop()
                    return
                }
                localeID = newLocaleID
                if meetingLanguageTimeline.recordSwitch(to: newLocaleID) != nil {
                    var marker = CaptionChunk(en: tr("已切换为%@", localeName(newLocaleID)))
                    marker.isMarker = true
                    chunks.append(marker)
                }
                committedEn = ""; volatileEn = ""; doneChars = 0; pendingEn = ""; sourceLedger = TranslationSourceLedger()
                asrSourceLedger = nil
                meter.reset()
                try startTap()
                switchingMeetingLanguage = false
                updateRunningStatus()
                scheduleTranscriptSave()
            } catch {
                let cancelled = error is CancellationError || Task.isCancelled
                guard ExclusiveEngineStart.shouldStopMeeting(
                    cancelled: cancelled,
                    sessionStillCurrent: sessionGen == generation
                ) else {
                    if sessionGen == generation { switchingMeetingLanguage = false }
                    return
                }
                switchingMeetingLanguage = false
                stop(reason: tr("切换会议语言失败，字幕已停止"))
            }
        }
    }

    // ==== 为浏览器扩展做的实时听译：网页没有字幕轨时，app 听系统声音翻译，结果推回网页原地显示 ====
    /// 为扩展开实时听译。spoken = 网页指定的原声语言（转写 locale，如 ja_JP），target = 网页选的译文语言；空则沿用 app 的设置
    /// 用户自己已经在开着字幕时不抢：回一个 busy，网页显示提示
    /// The audit-run constraint applies to video too; ignore legacy preferences.
    let localForVideo = false
    func startLiveForExtension(title: String, spoken: String = "", target: String = "") {
        if (running || starting) && !captionsToExtension {
            pushStatus(["kind": "status", "state": "busy"])   // 用户自己开的会话，不接管
            return
        }
        let wantLocale = spoken.isEmpty ? localeID : spoken
        if (running || starting), wantLocale != localeID { stop() }   // 换了原声语言：重开引擎
        captionsToExtension = true
        youtubeActive = true
        youtubeTitle = title
        CaptionPanelController.shared.hide()   // 字幕在网页里显示，app 自己的窗不弹
        if !running && !starting {
            if wantLocale != localeID { savedLocale = savedLocale ?? localeID; localeID = wantLocale }
            if !target.isEmpty, target != targetLang { savedTarget = savedTarget ?? targetLang; targetLang = target }
            if savedCaptionMode == nil { savedCaptionMode = captionMode }
            captionMode = .video
            guard start() else {   // 起不来（权限 / 上一次还在收尾）：告诉网页，别让它一直转圈
                captionsToExtension = false; youtubeActive = false
                restoreUserPrefs()
                pushStatus(["kind": "status", "state": "error", "error": "start_failed", "detail": status])
                return
            }
            startMicPolling()
        } else if !target.isEmpty, target != targetLang {
            savedTarget = savedTarget ?? targetLang; targetLang = target
        }
        if localForVideo {
            LocalTranslator.shared.prepare(source: LocalTranslator.langCode(localeID), target: LocalTranslator.langCode(targetLang))
        }
        pushStatus(["kind": "status", "state": "live"])
    }
    func stopLiveForExtension() {
        guard captionsToExtension else { youtubeActive = false; return }
        pushStatus(["kind": "status", "state": "stopped"])   // 先说再清，否则被 captionsToExtension 门挡掉
        captionsToExtension = false
        youtubeActive = false
        youtubeTitle = ""
        if running || starting { stop() }
        LocalTranslator.shared.teardown()
        restoreUserPrefs()
    }
    /// 扩展会话结束后把被临时改掉的偏好还回去（这些设置是用户的，不该被网页永久改写）
    private var savedCaptionMode: CaptionMode?
    private var savedLocale: String?
    private var savedTarget: String?
    private func restoreUserPrefs() {
        if let m = savedCaptionMode { captionMode = m; savedCaptionMode = nil }
        if let l = savedLocale { localeID = l; savedLocale = nil }
        if let t = savedTarget { targetLang = t; savedTarget = nil }
    }
    /// 把一句字幕推给宿主进程（宿主转给扩展）。seq 让网页端知道是新句还是同一句在更新
    private func pushToExtension(_ info: [String: Any]) {
        guard captionsToExtension else { return }
        pushStatus(info)
    }
    /// 状态类消息不受 captionsToExtension 门控：busy / error / stopped 都得能送出去
    private func pushStatus(_ info: [String: Any]) {
        DistributedNotificationCenter.default().postNotificationName(NativeHost.captionNotification, object: nil, userInfo: info, deliverImmediately: true)
    }
    private func pushChunk(_ chunk: CaptionChunk, index: Int) {
        pushToExtension(["kind": "chunk", "seq": index, "en": chunk.en, "zh": chunk.zh])
    }

    /// 探测系统音频权限（onboarding 用）：起一次 tap 立刻停；成功即已授权（会触发系统弹窗）
    func probeAudioPermission() async -> Bool {
        let probe = SystemAudioTap(watchesDevice: false)
        do {
            try probe.start { _, _, _, _, _ in }
            probe.stop()
            return true
        } catch {
            return false
        }
    }

    /// 返回是否真的开始了（未登录 → 转去登录，不起 tap）
    @discardableResult
    func start() -> Bool {
#if SHOOT || DEBUG
        if ShootSimulation.requestedMode != nil { ShootSimulation.start(self); return true }
#endif
        guard !running, !starting else { return false }
        if finishingCaptions { status = tr("已停止采音，正在完成最后一句…"); return false }
        if !SessionControls.canStartNewMeeting(
            previousStartInFlight: startTask != nil,
            previousTranscriptPending: finalTranscriptTask != nil
        ) {
            status = tr("上一次启动还在收尾，请稍后再试"); return false
        }
        if translationEngine == .openAI && !hasOpenAIKey {
            status = tr("未填写 OpenAI Key")
            AppDelegate.enter(section: .settings)
            return false
        }
        if translationEngine == .apple {
            LocalTranslator.shared.prepare(source: localeID, target: LocalTranslator.langCode(targetLang))
        }
        if translationEngine == .mlx {
            guard UserDefaults.standard.bool(forKey: "mlxModelReady") else {
                status = tr("请先在设置里下载高质量本机模型")
                AppDelegate.enter(section: .settings)
                return false
            }
            Task { try? await MLXModelController.shared.load() }
        }
        meetingSessionContext.begin(
            selected: captionsToExtension ? nil : calendarCoordinator.selectedContext,
            permanentGlossary: glossary
        )
        // The coordinator orders generations; a new live session must follow retries.
        sessionGen = max(sessionGen, meetingSummaryRetryGeneration) + 1
        let gen = sessionGen
        engineEpoch += 1
        let epoch = engineEpoch
        engineRestarts = 0; lastRestartAt = nil
        timingRecorder.clearAttempts()
        timingRecorder.beginSession()
        pendingClock = PendingTextClock()
        chunks = []; committedEn = ""; doneChars = 0; volatileEn = ""; pendingEn = ""; sourceLedger = TranslationSourceLedger(); activeTranslationAttempts = [:]
        asrSourceLedger = nil
        translationRetryQueue = TranslationRetryQueue(); inflight = 0; rateLimitedUntil = nil
        if pauseReason != .session { unpause() }
        // Keep capture errors visible until the replacement engine and tap work.
        if errorBanner?.action != .retry && errorBanner?.action != .openSettings { errorBanner = nil }
        lastDraftMs = nil; lastFinalMs = nil
        let startedAt = Date()
        sessionStartedAt = startedAt
        meetingLanguageTimeline = MeetingLanguageTimeline(initialLocaleID: localeID)
        transcriptURL = nil
        meetingSummaryIngressTask = nil
        meetingSummarySessionBegan = false
        lastMeetingSummaryEvaluationAt = nil
        meetingSummarySnapshot = nil
        if MeetingSummaryPreferences.shouldGenerate(consent: summaryConsent, enabled: meetingSummariesEnabled),
           !captionsToExtension {
            meetingSummaryGeneration = gen
            meetingSummaryRecordID = UUID().uuidString.lowercased()
            meetingSummaryBuffer = MeetingSummaryLifecycleBuffer(startedAt: startedAt)
        } else {
            meetingSummaryGeneration = nil
            meetingSummaryRecordID = nil
            meetingSummaryBuffer = nil
        }
        paused = false; pausedSince = nil; switchingMeetingLanguage = false
        resumeTask?.cancel(); resumeTask = nil
        resumeStart.end()
        resuming = false
        languageSwitchTask?.cancel(); languageSwitchTask = nil
        translationConnectivity = TranslationConnectivityPolicy()
        meter.reset(); audioLevel = 0; silentTooLong = false; audioStalled = false
        // Old requests retain their old callbacks, including failures.
        translator.cancelAll()
        translator = Translator()
        translator.model = model
        translator.glossary = meetingSessionContext.effectiveGlossary
        translator.targetLanguage = targetLang
        translator.sourceLanguage = localeID
        translator.engine = translationEngine
        translationCallbackContinuation?.finish()
        translationCallbackTask?.cancel()
        let callbacks = AsyncStream<TranslationCallbackEvent>.makeStream()
        let continuation = callbacks.continuation
        translationCallbackContinuation = continuation
        translator.onStatus = { msg in
            guard let request = TranslationConnectivityRequest.current else { return }
            continuation.yield(.status(request, msg))
        }
        translator.onFailure = { f in
            guard let request = TranslationConnectivityRequest.current else { return }
            continuation.yield(.failure(request, f))
        }
        translationCallbackTask = Task { @MainActor [weak self] in
            guard let s = self else { return }
            guard s.sessionGen == gen else { return }
            await s.consumeTranslationCallbacks(callbacks.stream, generation: gen)
        }
        translator.reset()
        translationConfig = nil   // 本地翻译草稿已永久关闭（见 instantDraft）
        pendingDraft = ""; lastDraftReq = nil
        starting = true
        status = tr("启动中…")
        engine.onDownloadProgress = { p in Task { @MainActor in
            let s = CaptionState.shared
            if s.starting { s.status = tr("下载转写模型 %@%", Int(p * 100)) }
        } }
        tap.onDefaultDeviceChanged = { [weak self] in self?.handleDeviceChange() }
        startTask = Task {
            defer { if self.sessionGen == gen || self.startGenOwner == gen { if self.startGenOwner == gen { self.startTask = nil } } }
            startGenOwner = gen
            do {
                try await engine.start(localeID: localeID) { [weak self] event in
                    guard let self, self.sessionGen == gen, self.engineEpoch == epoch else { return }; self.handle(event, resultGeneration: gen)
                }
                try Task.checkCancellation()
                try startTap()
                try Task.checkCancellation()
                running = true
                starting = false
                if errorBanner?.action == .retry || errorBanner?.action == .openSettings { errorBanner = nil }
                activityToken = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Live captions")
                let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in Task { @MainActor in self?.tickChunks() } }
                RunLoop.main.add(t, forMode: .common)   // 拖窗口时也走 tick
                chunkTimer = t
                translator.warmup()   // 预热 TLS/HTTP2 连接，首句提速
                updateRunningStatus()
            } catch is CancellationError {
                engine.stop()   // 引擎可能已在取消点之后建好：确保释放
            } catch {
                guard !Task.isCancelled, self.sessionGen == gen else { engine.stop(); return }   // 本任务已被 stop() 取消：别去拆新会话
                failStart(error)
            }
        }
        return true
    }
    private var startGenOwner = 0

    private func failStart(_ error: Error) {
        let toExtension = captionsToExtension
        stop(reason: nil)
        volatileEn = ""; pendingEn = ""
        let tapErr = error as? AudioTapError
        let msg = error.localizedDescription
        status = tr("启动失败：%@", msg)
        if let tapErr, tapErr.isPermission {
            errorBanner = CaptionBanner(text: tr("没有「系统录音」权限，听不到会议声音。系统设置 › 隐私与安全性 › 屏幕录制与系统录音 里允许 Kikishima。"), action: .openSettings)
        } else {
            errorBanner = CaptionBanner(text: tr("启动失败：%@", msg), action: .retry)
        }
        if toExtension { pushStatus(["kind": "status", "state": "error", "error": "start_failed", "detail": msg]) }
        else { CaptionPanelController.shared.show() }
    }

    /// 音频电平（0~1）与静音 / 停摆判定：音频线程通过锁写入 meter，主线程 timer 每 0.25 秒读一次写进这三个可观察属性
    var audioLevel: Double = 0
    var silentTooLong = false {
        didSet { noticeVisibility.receive(silent: silentTooLong, stopped: audioStalled) }
    }     // 运行中连续 20 秒没声音（会议本来有安静段，只改状态行不弹横幅）
    var audioStalled = false {
        didSet { noticeVisibility.receive(silent: silentTooLong, stopped: audioStalled) }
    }      // IO 回调本身停了 5 秒以上（设备被拔 / 聚合设备卡死而默认设备没变，之前这种情况反而报不出来）
    private let meter = AudioMeter()

    private var audioPermissionFailed = false
    private var rebuildingAudioTap = false
    private func startTap() throws {
        do {
            try startTapCapture()
            audioPermissionFailed = false
            rebuildingAudioTap = false
            audioInterruption = .none
        } catch {
            audioPermissionFailed = (error as? AudioTapError)?.isPermission == true
            audioInterruption = CaptionAudioInterruption.resolve(ioStopped: true, rebuilding: rebuildingAudioTap,
                hasUsableDevice: AudioDevices.defaultOutput() != nil || !AudioDevices.outputDevices().isEmpty,
                systemPermissionFailed: audioPermissionFailed)
            throw error
        }
    }
    private func startTapCapture() throws {
        var format: AVAudioFormat?
        let meter = self.meter, engine = self.engine, tap = self.tap
        try tap.start { _, inInputData, _, _, _ in
            if format == nil, var desc = tap.streamDescription {
                format = AVAudioFormat(streamDescription: &desc)
            }
            guard let format else { return }
            engine.feed(bufferList: inInputData, sourceFormat: format)
            meter.ingest(inInputData, format: format)
        }
    }
    private func pollMeter() {
        let now = CFAbsoluteTimeGetCurrent()
        let sample = meter.snapshot()
        audioLevel = sample.level
        let ioStopped = sample.lastIOAt > 0 && now - sample.lastIOAt > 5
        audioInterruption = CaptionAudioInterruption.resolve(ioStopped: ioStopped, rebuilding: rebuildingAudioTap,
            hasUsableDevice: AudioDevices.defaultOutput() != nil || !AudioDevices.outputDevices().isEmpty,
            systemPermissionFailed: audioPermissionFailed)
        audioStalled = audioInterruption == .recovering
        silentTooLong = sample.lastLoudAt > 0 && now - sample.lastLoudAt > 20
    }

    /// 默认输出设备变了：只重建 tap（转写引擎与已出字幕都保留），0.6 秒去抖
    private var deviceChangeWork: DispatchWorkItem?
    private func handleDeviceChange() {
        guard SessionControls.shouldRebuildAudioTap(
            running: running, paused: paused, resuming: resuming,
            switchingMeetingLanguage: switchingMeetingLanguage, tapAlreadyRunning: false
        ) else { return }
        deviceChangeWork?.cancel()
        rebuildingAudioTap = true
        let w = DispatchWorkItem { [weak self] in
            guard let self, SessionControls.shouldRebuildAudioTap(
                running: self.running, paused: self.paused, resuming: self.resuming,
                switchingMeetingLanguage: self.switchingMeetingLanguage, tapAlreadyRunning: false
            ) else { return }
            self.tap.stop()
            self.engine.resetConverter()
            do {
                try self.startTap()
                self.status = tr("输出设备已切换，继续字幕")
            } catch {
                // 设备切换瞬间可能还没就绪：1 秒后再试一次；仍失败就诚实停止
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self, SessionControls.shouldRebuildAudioTap(
                        running: self.running, paused: self.paused, resuming: self.resuming,
                        switchingMeetingLanguage: self.switchingMeetingLanguage,
                        tapAlreadyRunning: self.tap.isRunning
                    ) else { return }
                    do { try self.startTap(); self.status = tr("输出设备已切换，继续字幕") }
                    catch {
                        self.errorBanner = CaptionBanner(text: tr("输出设备切换后无法继续捕获音频：%@", error.localizedDescription), action: .retry)
                        self.stop(reason: tr("音频设备切换失败，已停止"))
                    }
                }
            }
        }
        deviceChangeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    private var drainingTranscription = false
    private(set) var finishingCaptions = false
    private var stopTask: Task<Void, Never>?

    /// reason: nil = 失败路径，不覆盖 status；否则写入 status
    func stop(reason: String? = trAny("已停止")) {
#if SHOOT || DEBUG
        if ShootSimulation.requestedMode != nil { ShootSimulation.stop(self); return }
#endif
        guard !finishingCaptions, running || starting else { return }
        // Capture ends synchronously, before any asynchronous drain.
        tap.stop()
        audioLevel = 0; silentTooLong = false; audioStalled = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        let generation = sessionGen
        let meetingContextSnapshot = meetingSessionContext.selected
        startTask?.cancel()                   // 不置 nil：由任务自己的 defer 清，start() 在它退出前不重入
        restartTask?.cancel(); restartTask = nil
        resumeTask?.cancel(); resumeTask = nil
        resumeStart.end()
        resuming = false
        languageSwitchTask?.cancel(); languageSwitchTask = nil
        chunkTimer?.invalidate(); chunkTimer = nil
        stopMicPolling()
        deviceChangeWork?.cancel()
        let wasRunning = running
        if reason != nil { status = tr("已停止采音，正在完成最后一句…") }
        finishingCaptions = true
        drainingTranscription = true
        running = false
        starting = false
        stopTask = Task { @MainActor in
            defer { stopTask = nil }
            await CaptionFinalization.drain(
                deadline: deadline,
                finishASR: { await self.engine.finish() },
                freezeASR: {
                    self.drainingTranscription = false
                    self.engineEpoch += 1
                    self.engine.stop()
                },
                flushTail: { mayTranslate in
                    if wasRunning { self.flushPendingTail(translate: mayTranslate) }
                },
                pumpTranslations: {
                    self.retryFailedChunks()
                    return self.inflight > 0 || (!self.translationPaused && self.chunks.contains {
                        !$0.isMarker && !$0.translationComplete && $0.translationAttempts < 3
                    })
                }
            )
            completeStop(generation: generation, meetingContextSnapshot: meetingContextSnapshot,
                         wasRunning: wasRunning, reason: reason)
        }
    }

    private func completeStop(generation: Int, meetingContextSnapshot: MeetingContext?, wasRunning: Bool, reason: String?) {
        // Revoke attempts before cancellation can enqueue callbacks.
        activeTranslationAttempts.removeAll()
        translationCallbackContinuation?.finish()
        translationCallbackContinuation = nil
        translationCallbackTask?.cancel()
        translationCallbackTask = nil
        translator.cancelAll()
        timingRecorder.clearAttempts()
        finishingCaptions = false
        let recoverySettings = TranscriptRecovery.Settings(targetLanguage: translator.targetLanguage,
            glossary: translator.glossary, model: translator.model, useProxy: false)
        asrSourceLedger = nil
        timingRecorder.endSession()
        let finalChunks = chunks
        let finalMeetingLocaleIDs = meetingLanguageTimeline.localeIDs
        let summaryEligible = meetingSummaryGeneration == generation && !captionsToExtension
        let summaryRecordID = meetingSummaryRecordID
        let summaryStartedAt = sessionStartedAt
        let summaryTargetLanguage = recoverySettings.targetLanguage
        let summaryAliases = self.summaryAliases
        let summarySessionBegan = meetingSummarySessionBegan
        let summaryIngressTask = meetingSummaryIngressTask
        var finalSummarySegments: [SummarySourceSegment] = []
        if summaryEligible, var buffer = meetingSummaryBuffer {
            let candidates = finalChunks.compactMap { chunk -> MeetingSummaryCandidate? in
                guard !chunk.isMarker, chunk.en.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
                let preferred = chunk.translationComplete && !chunk.zh.isEmpty && !chunk.isDraft && !chunk.zh.hasPrefix("⚠") ? chunk.zh : nil
                return MeetingSummaryCandidate(
                    id: chunk.id.uuidString.lowercased(),
                    createdAt: chunk.createdAt,
                    preferredText: preferred,
                    fallbackText: chunk.en
                )
            }
            finalSummarySegments = buffer.finalize(candidates)
            meetingSummaryBuffer = buffer
        }
        meetingSessionContext.end(permanentGlossary: glossary)
        calendarCoordinator.clearSelection()
        translator.glossary = meetingSessionContext.effectiveGlossary
        sessionGen += 1                       // 让在途回调（翻译 onDone / 重启任务 / 转写事件）自动作废
        engine.stop()
        running = false
        starting = false
        switchingMeetingLanguage = false
        paused = false; pausedSince = nil
        if captionsToExtension { pushStatus(["kind": "status", "state": "stopped"]); captionsToExtension = false; youtubeActive = false; restoreUserPrefs() }
        inflight = 0
        audioLevel = 0; silentTooLong = false; audioStalled = false
        if let token = activityToken { ProcessInfo.processInfo.endActivity(token); activityToken = nil }
        if let reason { status = reason }
        volatileEn = ""; pendingEn = ""; pendingDraft = ""
        translationConfig = nil
        stopBubble()

        let transcriptTask = Task {
            await self.saveTranscript(
                final: true,
                snapshot: finalChunks,
                generation: generation,
                meetingLocaleIDs: finalMeetingLocaleIDs,
                meetingContextSnapshot: meetingContextSnapshot,
                recoverySettings: recoverySettings
            )
        }
        finalTranscriptTask = transcriptTask
        finalTranscriptOwner = generation
        let coordinator = meetingSummaryCoordinator
        meetingSummaryFinalizationOwner = generation
        if summaryEligible, let summaryRecordID {
            busySummaryRecordIDs.insert(summaryRecordID)
        }
        meetingSummaryFinalizationTask = Task {
            let transcriptResult = await transcriptTask.value
            var savedURL: URL?
            switch transcriptResult {
            case .success(let url):
                savedURL = url
                if let url, self.sessionGen == generation + 1, !self.running, !self.starting {
                    self.status = tr("已停止 · 记录已存 %@", url.lastPathComponent)
                }
            case .failure(let error):
                if self.sessionGen == generation + 1, !self.running, !self.starting {
                    self.status = tr("已停止 · 记录保存失败: %@", error.localizedDescription)
                }
            }
            if self.finalTranscriptOwner == generation {
                self.finalTranscriptTask = nil
                self.finalTranscriptOwner = nil
            }

            if summaryEligible,
               let savedURL,
               let summaryRecordID,
               let summaryStartedAt {
                await summaryIngressTask?.value
                if !summarySessionBegan {
                    await coordinator.begin(
                        generation: generation,
                        recordID: summaryRecordID,
                        transcriptURL: savedURL,
                        startedAt: summaryStartedAt,
                        targetLanguage: summaryTargetLanguage,
                        aliases: summaryAliases
                    )
                }
                await coordinator.finalize(
                    remaining: finalSummarySegments,
                    transcriptURL: savedURL,
                    generation: generation
                )
            }
            if self.meetingSummaryFinalizationOwner == generation {
                self.meetingSummaryFinalizationTask = nil
                self.meetingSummaryFinalizationOwner = nil
            }
            if let summaryRecordID {
                self.busySummaryRecordIDs.remove(summaryRecordID)
            }
            self.summaryDiskRevision += 1
        }
    }
    private var restartTask: Task<Void, Never>?
    private var engineRestarts = 0
    private var lastRestartAt: Date?

    // ==== 字幕记录：会中增量写、停止时收尾 ====
    nonisolated static var transcriptDir: URL {
        #if SHOOT || DEBUG
        if let path = ProcessInfo.processInfo.environment["KIKISHIMA_RECORDS_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        if let p = UserDefaults.standard.string(forKey: "transcriptDir"), !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Kikishima", isDirectory: true)
    }
    nonisolated static func setTranscriptDir(_ url: URL) { UserDefaults.standard.set(url.path, forKey: "transcriptDir") }
    private var transcriptURL: URL?
    private var lastSaveAt: Date?

    private static let fileStamp: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX"); df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return df
    }()

    private func relativeStamp(_ d: Date) -> String {
        let secs = Int(d.timeIntervalSince(sessionStartedAt ?? d))
        return String(format: "%02d:%02d:%02d", secs / 3600, (secs % 3600) / 60, secs % 60)
    }

    /// final=false：节流 10 秒一次的中途保存（崩溃/强退不丢）；final=true：停止时必写
    /// Autosaves keep the existing length gate; a final stop preserves even one sentence.
    private var worthSaving: Bool {
        guard let startedAt = sessionStartedAt else { return false }
        return worthSaving(chunks, startedAt: startedAt, now: Date())
    }

    private func worthSaving(_ snapshot: [CaptionChunk], startedAt: Date, now: Date) -> Bool {
        let real = snapshot.filter { !$0.isMarker && $0.en.contains(where: { $0.isLetter || $0.isNumber }) }
        guard real.count >= 3 else { return false }
        return now.timeIntervalSince(startedAt) >= 30
    }

    private func ensureTranscriptURL(
        for snapshot: [CaptionChunk],
        startedAt: Date,
        meetingContextSnapshot: MeetingContext?,
        targetLanguage: String? = nil
    ) -> URL {
        if let transcriptURL { return transcriptURL }
        let initialLocaleID = meetingLanguageTimeline.initialLocaleID
        let src = initialLocaleID.split(separator: "_").first.map(String.init) ?? initialLocaleID
        let dst = targetCode(targetLanguage ?? targetLang)
        let firstLine = snapshot.first(where: { !$0.isMarker && !$0.en.isEmpty })?.en ?? ""
        var fallbackTitle = String(firstLine.prefix(28)).replacingOccurrences(of: "[/:\\\\\n\r\t\"*?<>|]", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if firstLine.count > 28 { fallbackTitle += "…" }
        let calendarTitle = meetingContextSnapshot.map { MeetingContextTerms.recordTitle(from: $0.title) } ?? ""
        let title = calendarTitle.isEmpty ? fallbackTitle : calendarTitle
        let name = "Kikishima \(Self.fileStamp.string(from: startedAt)) · \(src)→\(dst)" + (title.isEmpty ? "" : " · \(title)")
        let url = Self.transcriptDir.appendingPathComponent(name + ".md")
        transcriptURL = url
        return url
    }

    private func scheduleTranscriptSave() {
        let generation = sessionGen
        let snapshot = chunks
        let meetingLocaleIDs = meetingLanguageTimeline.localeIDs
        let meetingContextSnapshot = meetingSessionContext.selected
        Task {
            _ = await self.saveTranscript(
                final: false,
                snapshot: snapshot,
                generation: generation,
                meetingLocaleIDs: meetingLocaleIDs,
                meetingContextSnapshot: meetingContextSnapshot
            )
        }
    }

    @discardableResult
    private func saveTranscript(
        final: Bool,
        snapshot: [CaptionChunk]? = nil,
        generation: Int,
        meetingLocaleIDs: [String]? = nil,
        meetingContextSnapshot: MeetingContext?,
        recoverySettings: TranscriptRecovery.Settings? = nil
    ) async -> Result<URL?, Error> {
        if !final, generation != sessionGen { return .success(nil) }
        let snapshot = snapshot ?? chunks
        guard snapshot.contains(where: { !$0.isMarker && $0.en.contains(where: { $0.isLetter || $0.isNumber }) }),
              let startedAt = sessionStartedAt,
              final || worthSaving(snapshot, startedAt: startedAt, now: Date()) else { return .success(nil) }
        if !final, let t = lastSaveAt, Date().timeIntervalSince(t) < 10 { return .success(nil) }
        lastSaveAt = Date()
        let url = ensureTranscriptURL(
            for: snapshot,
            startedAt: startedAt,
            meetingContextSnapshot: meetingContextSnapshot,
            targetLanguage: recoverySettings?.targetLanguage
        )
        let meetingLanguageValue = (meetingLocaleIDs ?? meetingLanguageTimeline.localeIDs).joined(separator: " → ")
        let meetingTitle = meetingContextSnapshot.map { MeetingContextTerms.recordTitle(from: $0.title) } ?? ""
        let meetingLine = meetingTitle.isEmpty ? "" : "- \(tr("会议")): \(meetingTitle)\n"
        let settings = recoverySettings ?? TranscriptRecovery.Settings(targetLanguage: translator.targetLanguage,
            glossary: translator.glossary, model: translator.model, useProxy: false)
        let header = "# \(tr("会议字幕记录"))\n\n- \(tr("开始")): \(Self.fileStamp.string(from: startedAt))\n\(meetingLine)- \(tr("会议语言")): \(meetingLanguageValue)\n- \(tr("译文语言")): \(settings.targetLanguage)\n\n---\n\n"
        let stamps = snapshot.map { chunk in
            let seconds = max(0, Int(chunk.createdAt.timeIntervalSince(startedAt)))
            return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        let rows = snapshot.indices.map { index in
            let chunk = snapshot[index]
            return TranscriptRecovery.Row(source: chunk.en,
                translation: chunk.zh.hasPrefix("⚠") || chunk.isDraft ? "" : chunk.zh,
                complete: chunk.translationComplete && !chunk.isDraft && !chunk.zh.hasPrefix("⚠")
                    && !chunk.zh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                marker: chunk.isMarker, stamp: stamps[index],
                previousSource: chunk.previousSource ?? TranslationText.frozenPreviousSource(
                    immediatePredecessorIsMarker: index > 0 && snapshot[index - 1].isMarker,
                    lastNonMarker: snapshot[..<index].last(where: { !$0.isMarker })?.en))
        }
        let record = TranscriptRecovery(header: header, incompleteLabel: tr("译文未完成，原文已保留"),
            settings: settings, rows: rows)
        do {
            let markdown = try record.markdown()
            try await transcriptWriter.write(markdown: markdown, to: url)
            transcriptDiskRevision += 1
            return .success(url)
        } catch {
            return .failure(error)
        }
    }

    private func queueTranslatedChunksForMeetingSummary(now: Date = Date()) {
        guard meetingSummaryGeneration == sessionGen,
              var buffer = meetingSummaryBuffer,
              let startedAt = sessionStartedAt,
              let recordID = meetingSummaryRecordID,
              worthSaving else { return }

        let url = ensureTranscriptURL(
            for: chunks,
            startedAt: startedAt,
            meetingContextSnapshot: meetingSessionContext.selected
        )
        if !meetingSummarySessionBegan {
            meetingSummarySessionBegan = true
            let coordinator = meetingSummaryCoordinator
            let generation = sessionGen
            let targetLanguage = targetLang
            let aliases = summaryAliases
            let previousTask = meetingSummaryIngressTask
            meetingSummaryIngressTask = Task {
                await previousTask?.value
                await coordinator.begin(
                    generation: generation,
                    recordID: recordID,
                    transcriptURL: url,
                    startedAt: startedAt,
                    targetLanguage: targetLanguage,
                    aliases: aliases
                )
            }
        }

        var segments: [SummarySourceSegment] = []
        for chunk in chunks where chunk.sourceFinal && chunk.translationComplete && !chunk.isMarker && !chunk.zh.isEmpty && !chunk.isDraft && !chunk.zh.hasPrefix("⚠") {
            if let segment = buffer.acceptTranslated(
                id: chunk.id.uuidString.lowercased(),
                createdAt: chunk.createdAt,
                text: chunk.zh
            ) {
                segments.append(segment)
            }
        }
        meetingSummaryBuffer = buffer
        if !segments.isEmpty {
            let coordinator = meetingSummaryCoordinator
            let generation = sessionGen
            let previousTask = meetingSummaryIngressTask
            meetingSummaryIngressTask = Task {
                await previousTask?.value
                for segment in segments { await coordinator.accept(segment, generation: generation) }
            }
        }

        guard now.timeIntervalSince(lastMeetingSummaryEvaluationAt ?? .distantPast) >= 5 else { return }
        lastMeetingSummaryEvaluationAt = now
        let coordinator = meetingSummaryCoordinator
        let generation = sessionGen
        let ingressTask = meetingSummaryIngressTask
        Task {
            await ingressTask?.value
            await coordinator.tick(now: now, generation: generation)
        }
    }

    var hasPendingMeetingFinalization: Bool {
        stopTask != nil || finalTranscriptTask != nil || meetingSummaryFinalizationTask != nil || meetingSummaryRetryTask != nil || transcriptRetryTask != nil
    }

    func waitForPendingMeetingFinalization() async {
        await stopTask?.value
        if let finalTranscriptTask { _ = await finalTranscriptTask.value }
        await meetingSummaryFinalizationTask?.value
        await meetingSummaryRetryTask?.value
        await transcriptRetryTask?.value
    }

    @ObservationIgnored private var transcriptRetryTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptRetryTranslator: Translator?
    private(set) var retryingTranscriptURL: URL?
    private(set) var transcriptRetryMessage: String?
    private(set) var transcriptRetryMessageURL: URL?

    func transcriptIsBusy(_ url: URL) -> Bool {
        retryingTranscriptURL == url || (transcriptURL == url &&
            (running || starting || finishingCaptions || finalTranscriptTask != nil || meetingSummaryFinalizationTask != nil))
    }

    func canRetryTranscript(at url: URL) -> Bool {
        retryingTranscriptURL == nil && !finishingCaptions && finalTranscriptTask == nil
            && meetingSummaryFinalizationTask == nil && meetingSummaryRetryTask == nil
            && !(transcriptURL == url && (running || starting))
    }

    func retryTranscript(at url: URL) {
        guard canRetryTranscript(at: url) else { return }
        let client = Translator()
        client.engine = translationEngine
        transcriptRetryTranslator = client
        retryingTranscriptURL = url
        transcriptRetryMessageURL = url
        transcriptRetryMessage = tr("正在补翻未完成字幕…")
        transcriptRetryTask = Task { @MainActor in
            defer {
                client.cancelAll()
                if Task.isCancelled { transcriptRetryMessage = tr("补翻已停止，已完成的译文已保存。") }
                transcriptRetryTranslator = nil
                retryingTranscriptURL = nil
                transcriptRetryTask = nil
                transcriptDiskRevision += 1
            }
            do {
                let markdown = try await Task.detached(priority: .utility) {
                    try String(contentsOf: url, encoding: .utf8)
                }.value
                guard !Task.isCancelled else { return }
                guard let record = TranscriptRecovery.decode(markdown) else {
                    transcriptRetryMessage = TranscriptRecovery.exceedsRowLimit(markdown)
                        ? tr("记录过长，暂不支持补翻。")
                        : tr("记录已改变或不支持补翻，请打开原始记录。")
                    return
                }
                client.model = record.settings.model
                client.glossary = record.settings.glossary
                client.targetLanguage = record.settings.targetLanguage
                client.sourceLanguage = localeID
                client.engine = translationEngine
                let deadline = ContinuousClock.now.advanced(by: .seconds(20))
                try await TranscriptRecoveryRun.run(
                    record: record, markdown: markdown, url: url, deadline: deadline,
                    translate: { row, _, deadline in
                        await CaptionDeadline.value(until: deadline) { done in
                            client.translate(chunk: row.source, previous: row.previousSource, onDelta: { _ in }) { result in
                                Task { @MainActor in done(result) }
                            }
                        }
                    },
                    replace: { expected, replacement, url in
                        try await self.meetingSummaryStore.replaceTranscript(expected: expected, with: replacement, at: url)
                    },
                    flush: { expected, replacement, url in
                        // Cancellation still flushes completed rows; the
                        // external-edit check remains active.
                        try await self.meetingSummaryStore.replaceTranscript(
                            expected: expected, with: replacement, at: url,
                            checkingCancellation: false
                        )
                    },
                    didSave: { self.transcriptDiskRevision += 1 }
                )
                transcriptRetryMessage = tr("补翻已结束，已完成的译文已保存；未完成部分可再次重试。")
            } catch {
                transcriptRetryMessage = tr("记录已改变或无法保存，补翻已停止。")
            }
        }
    }

    func canRetryMeetingSummary(recordID: String?) -> Bool {
        guard let recordID,
              retryingTranscriptURL == nil, !finishingCaptions,
              MeetingSummaryPreferences.shouldGenerate(consent: summaryConsent, enabled: meetingSummariesEnabled) else { return false }
        let recordBusy = busySummaryRecordIDs.contains(recordID)
            || meetingSummarySnapshot?.workingRecordIDs.contains(recordID) == true
        return SessionControls.canRetryMeetingSummary(running: running, starting: starting, recordBusy: recordBusy)
    }

    func retryMeetingSummary(document: MeetingSummaryDocument, transcriptURL: URL) {
        guard (document.status == .failed || document.status == .interrupted),
              canRetryMeetingSummary(recordID: document.recordID) else { return }

        if meetingSummarySnapshot?.document?.recordID == document.recordID,
           let generation = meetingSummaryGeneration,
           meetingSummarySnapshot?.state.isFailed == true {
            let coordinator = meetingSummaryCoordinator
            let owner = generation
            busySummaryRecordIDs.insert(document.recordID)
            meetingSummaryRetryTask = Task {
                await coordinator.retryFinal(transcriptURL: transcriptURL, generation: owner)
                if self.meetingSummaryGeneration == owner {
                    self.meetingSummaryRetryTask = nil
                }
                self.busySummaryRecordIDs.remove(document.recordID)
                self.summaryDiskRevision += 1
            }
            return
        }

        let segments = document.sourceIndex.values.sorted {
            ($0.startSeconds, $0.id) < ($1.startSeconds, $1.id)
        }
        guard !segments.isEmpty else { return }
        let startedAt = document.updatedAt.addingTimeInterval(-Double(segments.last?.startSeconds ?? 0))
        let coordinator = meetingSummaryCoordinator
        let aliases = summaryAliases
        let targetLanguage = targetLang
        busySummaryRecordIDs.insert(document.recordID)
        meetingSummaryRetryTask = Task {
            if await coordinator.isWorking(recordID: document.recordID) {
                self.busySummaryRecordIDs.remove(document.recordID)
                self.meetingSummaryRetryTask = nil
                self.summaryDiskRevision += 1
                return
            }
            self.meetingSummaryRetryGeneration = max(self.sessionGen, self.meetingSummaryRetryGeneration) + 1
            let generation = self.meetingSummaryRetryGeneration
            self.meetingSummaryGeneration = generation
            self.meetingSummaryRecordID = document.recordID
            self.meetingSummarySnapshot = nil
            await coordinator.begin(
                generation: generation,
                recordID: document.recordID,
                transcriptURL: transcriptURL,
                startedAt: startedAt,
                targetLanguage: targetLanguage,
                aliases: aliases
            )
            for segment in segments { await coordinator.accept(segment, generation: generation) }
            await coordinator.finalize(remaining: [], transcriptURL: transcriptURL, generation: generation)
            if self.meetingSummaryGeneration == generation {
                self.meetingSummaryRetryTask = nil
            }
            self.busySummaryRecordIDs.remove(document.recordID)
            self.summaryDiskRevision += 1
        }
    }

    private func handle(_ event: TranscriptEvent, resultGeneration: Int) {
        guard TranscriptionResultPolicy.accepts(resultGeneration: resultGeneration, currentGeneration: sessionGen,
                                                draining: drainingTranscription,
                                                finished: !running && !starting && !drainingTranscription) else { return }
        guard !paused, !switchingMeetingLanguage else { return }   // 切换期间旧引擎尾巴与新模型下载提示都不进入会议正文
        switch event {
        case .volatile(let t, let timing):
            stableVolatilePrefix = stableCommonPrefix(lastVolatileEn, t)
            lastVolatileEn = t
            volatileEn = t
            observeASR(timing, committedPrefix: committedEn)
        case .finalized(let t, let timing):
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                // A silent range can still produce an empty final; never add a
                // stray separator to committed text.
                volatileEn = ""
                observeASR(timing, committedPrefix: committedEn)
                refreshPending()
                return
            }
            let prefix = committedEn
            committedEn += (committedEn.isEmpty ? "" : " ") + trimmed
            volatileEn = ""
            observeASR(timing, committedPrefix: prefix)
            refreshPending()
            if !drainingTranscription { tickChunks() }   // 收尾只记录，不新发翻译
            trimCommitted()
        case .pause:
            // Acoustic endpoint: flush the agreed prefix on the next tick even
            // without punctuation. Pending text below the agreement stays put.
            pauseCutRequested = true
            if !drainingTranscription { tickChunks() }
        case .error(let msg):
            guard running, !paused, restartTask == nil else { return }
            // 转写流断了：tap 还在喂，引擎已死 → 自动重启，30 秒内只允许一次，避免死循环
            if let last = lastRestartAt, Date().timeIntervalSince(last) < 30 {
                errorBanner = CaptionBanner(text: tr("转写引擎反复中断：%@", msg), action: .retry)
                stop(reason: tr("转写中断"))
                return
            }
            lastRestartAt = Date(); engineRestarts += 1
            status = tr("转写重连中…")
            let gen = sessionGen
            engineEpoch += 1
            let epoch = engineEpoch
            restartTask = Task {
                defer { if self.sessionGen == gen { self.restartTask = nil } }
                engine.stop()
                try? await Task.sleep(for: .milliseconds(600))
                guard running, sessionGen == gen, !Task.isCancelled else { return }
                guard SessionControls.shouldRunReconnect(
                    paused: paused,
                    switchingMeetingLanguage: switchingMeetingLanguage,
                    resuming: resuming
                ) else { return }
                do {
                    try await engine.start(localeID: localeID) { [weak self] e in
                        guard let self, self.sessionGen == gen, self.engineEpoch == epoch else { return }; self.handle(e, resultGeneration: gen)
                    }
                    try Task.checkCancellation()
                    guard running, sessionGen == gen else { engine.stop(); return }
                    guard SessionControls.shouldRunReconnect(
                        paused: paused,
                        switchingMeetingLanguage: switchingMeetingLanguage,
                        resuming: resuming
                    ) else { engine.stop(); return }
                    engine.resetConverter()
                    updateRunningStatus()
                } catch {
                    let cancelled = error is CancellationError || Task.isCancelled
                    guard ExclusiveEngineStart.shouldStopMeeting(
                        cancelled: cancelled,
                        sessionStillCurrent: sessionGen == gen
                    ) else { return }
                    errorBanner = CaptionBanner(text: tr("转写引擎中断：%@", msg), action: .retry)
                    stop(reason: tr("转写中断"))
                }
            }
        }
        refreshPending()
    }

    private func observeASR(_ result: ASRResultTiming?, committedPrefix: String) {
        guard timingRecorder.enabled else { return }
        if asrSourceLedger == nil { asrSourceLedger = ASRSourceLedger() }
        var source: ASRSourceID?
        if let timing = result?.row, timing.sessionID == timingRecorder.sessionID,
           let analyzer = timing.analyzerID, let revision = timing.asrRevisionID {
            source = ASRSourceID(analyzerID: analyzer, revisionID: revision)
            timingRecorder.recordASR(timing)
        }
        asrSourceLedger?.update(fullText, committedPrefix: committedPrefix, result: source)
    }

    private func flushPendingTail(translate: Bool) {
        let chars = Array(fullText)
        let start = min(doneChars, chars.count)
        let tail = String(chars[start...]).trimmingCharacters(in: .whitespaces)
        guard tail.contains(where: { $0.isLetter || $0.isNumber }) else { return }
        let committedCount = Array(committedEn).count
        var cursor = start
        var timingCursor = timingRecorder.enabled ? ASRSourceCursor(source: fullText, range: start..<chars.count) : nil
        for part in TranslationText.parts(tail) {
            var chunk = CaptionChunk(en: part)
            let partChars = Array(part).count
            cursor += partChars
            chunk.sourceFinal = TranslationText.tailPartIsSourceFinal(partEnd: cursor, committedCount: committedCount)
            if timingRecorder.enabled {
                chunk.timingMetadata = chunkTiming(text: part, reason: .forced, finalized: chunk.sourceFinal,
                                                   sourceRange: timingCursor?.consume(part))
                // Keep the existing pending timestamp untouched: acknowledgement
                // suppression also reads it, independently of diagnostics.
                chunk.timingMetadata?.row.pendingAgeMs = pendingClock.firstAt.map {
                    TranslationTiming.milliseconds(chunk.timingCreatedAt - $0)
                }
            }
            chunks.append(chunk)
            if let row = chunk.timingMetadata?.row { timingRecorder.event(.created, metadata: row) }
            if translate { requestTranslation(for: chunk.id, text: part) }
        }
        doneChars = chars.count
    }

    /// 切块源 = 定稿 + 未定稿合并流：不等 Apple 引擎慢吞吞定稿，逗号一到就切
    private var fullText: String {
        (committedEn + " " + volatileEn).trimmingCharacters(in: .whitespaces)
    }

    /// Translation source excludes the unstable volatile tail. `fullText` still
    /// feeds the preview and the source ledger.
    private var translationText: String {
        (committedEn + " " + stableVolatilePrefix).trimmingCharacters(in: .whitespaces)
    }

    /// 已翻完的前缀不再需要：定期裁掉，避免两小时会议里每 200ms 全量重扫
    private func trimCommitted() {
        guard volatileEn.isEmpty, doneChars > 2000 else { return }
        let chars = Array(committedEn)
        guard doneChars <= chars.count else { return }
        committedEn = String(chars[doneChars...]).trimmingCharacters(in: .whitespaces)
        doneChars = 0
        sourceLedger.trim(chars.count - committedEn.count, source: fullText)
        asrSourceLedger?.trim(chars.count - committedEn.count, source: fullText)
    }

    private func refreshPending() {
        let revision = sourceLedger.reconcile(fullText)
        if let rewind = revision.rewind {
            doneChars = rewind
            for id in revision.removed {
                if let row = chunks.first(where: { $0.id == id })?.timingMetadata?.row {
                    timingRecorder.event(.retracted, metadata: row)
                }
                translator.cancel(id)
                if let attempt = activeTranslationAttempts.removeValue(forKey: id) {
                    inflight = max(0, inflight - 1); timingRecorder.discard(attempt)
                }
            }
            chunks.removeAll { revision.removed.contains($0.id) }
            translationRetryQueue.remove(revision.removed)
            let removedIDs = Set(revision.removed.map { $0.uuidString.lowercased() })
            if var buffer = meetingSummaryBuffer {
                buffer.retract(removedIDs)
                meetingSummaryBuffer = buffer
            }
            let generation = sessionGen
            let coordinator = meetingSummaryCoordinator
            let previousTask = meetingSummaryIngressTask
            meetingSummaryIngressTask = Task {
                await previousTask?.value
                await coordinator.retract(removedIDs, generation: generation)
            }
            pendingClock = PendingTextClock()
            translationClock = PendingTextClock()
            scheduleTranscriptSave()
        }
        let finalIDs = sourceLedger.finalizedIDs(through: committedEn.count)
        for index in chunks.indices where finalIDs.contains(chunks[index].id) { chunks[index].sourceFinal = true }
        let chars = Array(fullText)
        doneChars = min(doneChars, chars.count)   // 定稿替换未定稿时长度可能缩，钳住
        let now = ProcessInfo.processInfo.systemUptime
        pendingClock.update(String(chars[doneChars...]), now: now)
        let translationChars = Array(translationText)
        let translationStart = min(doneChars, translationChars.count)
        translationClock.update(String(translationChars[translationStart...]), now: now)
        let newPending = String(chars[doneChars...]).trimmingCharacters(in: .whitespaces)
        if newPending != pendingEn {
            // 切块后待翻文本被截短：旧草稿不再对应，清掉等新草稿
            if !newPending.isEmpty, !pendingEn.hasPrefix(newPending), !newPending.hasPrefix(pendingEn) { pendingDraft = "" }
            if newPending.isEmpty { pendingDraft = "" }
            pendingEn = newPending
            pushToExtension(["kind": "pending", "en": newPending])
            scheduleDraft()
        }
    }

    private func tickChunks() {
        guard SessionControls.shouldTickChunks(
            running: running,
            paused: paused,
            switchingMeetingLanguage: switchingMeetingLanguage
        ) else { return }
        // 翻译名额满也照常切块：原文先滚动，译文排队补
        refreshPending()
        retryFailedChunks()
        queueTranslatedChunksForMeetingSummary()
        let source = translationText
        let chars = Array(source)
        let start = min(doneChars, chars.count)
        guard start < chars.count else {
            pauseCutRequested = false
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        var pauseFlushed = false
        var cutoff: Int
        if pauseCutRequested {
            pauseCutRequested = false
            let tail = String(chars[start...]).trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty, !endsSentenceTerminal(tail) {
                // Flush the agreed prefix at an acoustic boundary, never inside
                // a Latin word, and never as a one-word bubble.
                cutoff = pauseCutBoundary(source, start: start)
                let piece = cutoff > start ? String(chars[start..<cutoff]).trimmingCharacters(in: .whitespaces) : ""
                pauseFlushed = cutoff > start && !isShortTranslationFragment(piece)
                if !pauseFlushed { cutoff = start }
            } else {
                cutoff = translationCutoff(source, doneChars: start, tuning: tuning,
                    age: translationClock.firstAt.map { now - $0 } ?? 0,
                    stableFor: translationClock.changedAt.map { now - $0 } ?? 0,
                    finalized: volatileEn.isEmpty)
            }
        } else {
            cutoff = translationCutoff(source, doneChars: start, tuning: tuning,
                age: translationClock.firstAt.map { now - $0 } ?? 0,
                stableFor: translationClock.changedAt.map { now - $0 } ?? 0,
                finalized: volatileEn.isEmpty)
        }
        guard cutoff > start else { return }
        let chunkText = String(chars[start..<cutoff]).trimmingCharacters(in: .whitespaces)
        guard !chunkText.isEmpty else { return }
        // A short fragment at the very end of the stable prefix is likely to be
        // joined by the next stable words. Wait instead of translating a
        // one-word bubble; a real pause arrives as a final result.
        guard !(isShortTranslationFragment(chunkText) && !volatileEn.isEmpty && cutoff >= chars.count) else { return }
        let observedPendingAt = translationClock.firstAt
        let timingStableAt = timingRecorder.enabled ? translationClock.changedAt : nil
        pendingClock.consume(cutoff - doneChars)
        translationClock.consume(cutoff - start)
        doneChars = cutoff
        refreshPending()
        // ASR 在音乐/静音段会吐连串标点垃圾：不含任何字母/文字的块直接丢弃
        guard chunkText.contains(where: { $0.isLetter || $0.isNumber }) else { return }

        var chunk = CaptionChunk(en: chunkText)
        chunk.timingPendingAt = observedPendingAt
        // 这句的灰色草稿跟着块走（块拿走了整段待翻文本时才对得上），GPT 定稿到了在原地变白，不闪不跳
        if instantDraft, !pendingDraft.isEmpty, cutoff >= chars.count - 1 { chunk.zh = pendingDraft; chunk.isDraft = true; pendingDraft = "" }
        chunk.sourceFinal = cutoff <= committedEn.count
        if timingRecorder.enabled {
            let reason = translationCutReason(source, doneChars: start, tuning: tuning,
                age: observedPendingAt.map { now - $0 } ?? 0,
                stableFor: timingStableAt.map { now - $0 } ?? 0, finalized: volatileEn.isEmpty,
                forced: pauseFlushed)
            var cursor = ASRSourceCursor(source: source, range: start..<cutoff)
            chunk.timingMetadata = chunkTiming(text: chunkText, reason: reason, finalized: chunk.sourceFinal,
                                               sourceRange: cursor.consume(chunkText))
        }
        sourceLedger.register(chunk.id, range: start..<cutoff)
        chunks.append(chunk)
        if let metadata = chunk.timingMetadata {
            metadata.row.pendingAgeMs = observedPendingAt.map { TranslationTiming.milliseconds(now - $0) }
            timingRecorder.event(.created, metadata: metadata.row)
        }
        pushChunk(chunk, index: chunks.count - 1)
        scheduleTranscriptSave()
        // 翻译暂停（额度/登录）或限频退避中：只显示原文，不发请求；排进补翻队列，额度回来后补最近几块
        if translationPaused { translationRetryQueue.enqueue(chunk.id); return }
        if let until = rateLimitedUntil, until > Date() { translationRetryQueue.enqueue(chunk.id); return }
        if inflight >= 3 { translationRetryQueue.enqueue(chunk.id); return }   // 名额满：排进补发队列，成功一块就补一块
        // Apple 草稿层已停用，避免草稿在正式译文到达前短暂闪烁
        // 要恢复：draftContinuation?.yield((id, chunkText))
        requestTranslation(for: chunk.id, text: chunkText)
    }

    private func chunkTiming(text: String, reason: TranslationCutReason?, finalized: Bool,
                             sourceRange: Range<Int>?) -> TranslationTimingMetadata {
        var row = TranslationTiming.sample(pending: nil, chunk: 0, request: 0, first: nil, end: 0, succeeded: true)
        row.cutReason = reason?.rawValue; row.characterCount = text.count
        row.utf16Count = text.utf16.count; row.sourceFinal = finalized; row.inflightAtCut = inflight
        row.subrequestCount = TranslationText.parts(TranslationText.acknowledgement(text) ?? text).count
        row.sessionID = timingRecorder.sessionID; row.chunkID = timingRecorder.nextID()
        row.shortFragment = isShortTranslationFragment(text)
        if let asrSourceLedger {
            asrSourceLedger.attach(to: &row, range: sourceRange)
        } else {
            row.asrSourceRangeExact = false
        }
        return TranslationTimingMetadata(row)
    }

    private func requestTranslation(for id: UUID, text: String) {
        guard let index = chunks.firstIndex(where: { $0.id == id }), !chunks[index].translationComplete,
              activeTranslationAttempts[id] == nil else { return }
        chunks[index].translationExhausted = false
        if chunks[index].previousSource == nil {
            let immediate = chunks[..<index].last
            chunks[index].previousSource = TranslationText.frozenPreviousSource(
                immediatePredecessorIsMarker: immediate?.isMarker == true,
                lastNonMarker: chunks[..<index].last(where: { !$0.isMarker })?.en
            )
        }
        if let prior = chunks[..<index].last(where: { !$0.isMarker }), prior.translationComplete,
           TranslationText.repeatedAcknowledgement(text, after: prior.en, interval: {
               if let currentAt = chunks[index].timingPendingAt, let priorAt = prior.timingPendingAt {
                   return currentAt - priorAt
               }
               return chunks[index].createdAt.timeIntervalSince(prior.createdAt)
           }()) {
            chunks[index].zh = prior.zh
            chunks[index].translationComplete = true
            translationSucceeded()
            timingRecorder.event(.reused, metadata: chunks[index].timingMetadata?.row)
            scheduleTranscriptSave()
            return
        }
        guard !translationPaused, inflight < 3, rateLimitedUntil.map({ $0 <= Date() }) ?? true else {
            translationRetryQueue.enqueue(id); return
        }
        // 网页视频听译：先用本机翻译（几十毫秒），拿不到再走 GPT
        if captionsToExtension, localForVideo, !LocalTranslator.shared.unavailable {
            inflight += 1
            let gen = sessionGen
            Task { @MainActor in
                let local = await LocalTranslator.shared.translate(text)
                inflight = TranslationCompletionPolicy.remainingInflight(inflight, requestGeneration: gen, currentGeneration: sessionGen)
                guard gen == sessionGen else { return }
                if let local, !local.isEmpty {
                    if let idx = chunks.firstIndex(where: { $0.id == id }) {
                        chunks[idx].zh = local
                        chunks[idx].isDraft = false
                        chunks[idx].translationComplete = true
                        translationSucceeded()
                        pushChunk(chunks[idx], index: idx)
                        updateRunningStatus()
                    }
                } else {
                    requestTranslationViaProxy(for: id, text: text)   // 本机不行：回落 GPT
                }
            }
            return
        }
        requestTranslationViaProxy(for: id, text: text)
    }

    private func requestTranslationViaProxy(for id: UUID, text: String) {
        inflight += 1
        let gen = sessionGen
        let attempt = UUID()
        guard let sourceIndex = chunks.firstIndex(where: { $0.id == id }) else { inflight -= 1; return }
        activeTranslationAttempts[id] = attempt
        chunks[sourceIndex].translationAttempts += 1
        let previous = chunks[sourceIndex].previousSource ?? ""
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let timing: (@Sendable (TranslationNetworkTiming) -> Void)?
        if timingRecorder.enabled {
            // Manual retry resets the retry budget, never the diagnostic count.
            let attemptNumber = (chunks[sourceIndex].timingMetadata?.row.attemptNumber ?? 0) + 1
            chunks[sourceIndex].timingMetadata?.row.attemptNumber = attemptNumber
            chunks[sourceIndex].timingMetadata?.row.requestID = timingRecorder.nextID()
            let metadata = chunks[sourceIndex].timingMetadata?.row
            if let metadata { timingRecorder.beginAttempt(attempt, metadata: metadata) }
            timing = { network in
                Task { @MainActor in
                    var row = TranslationTiming.sample(pending: nil, chunk: 0, request: 0, first: nil, end: 0, succeeded: true)
                    row.sampleKind = 2; row.attemptNumber = attemptNumber
                    row.sessionID = metadata?.sessionID; row.chunkID = metadata?.chunkID
                    row.requestID = metadata?.requestID
                    row.subrequestIndex = network.subrequestIndex; row.subrequestCount = network.subrequestCount
                    row.networkRetry = network.retry; row.connectionReused = network.connectionReused
                    row.transactionCount = network.transactionCount; row.requestToHeadersMs = network.requestToHeadersMs
                    row.headersToFirstMs = network.headersToFirstMs; row.headersToEndMs = network.headersToEndMs
                    row.networkRequestToEndMs = network.requestToEndMs
                    row.worker = network.worker
                    TranslationTimingRecorder.shared.record(row)
                }
            }
        } else { timing = nil }
        let request = TranslationConnectivityRequest(chunk: id, attempt: attempt)
        let callbackContinuation = translationCallbackContinuation
        TranslationConnectivityRequest.context.withValue(request) {
        translator.translate(id: id, chunk: text, previous: previous, timing: timing) { [weak self] live in
            Task { @MainActor in
                guard let self, gen == self.sessionGen, self.activeTranslationAttempts[id] == attempt, let idx = self.chunks.firstIndex(where: { $0.id == id }) else { return }
                if !self.chunks[idx].isDraft, !self.chunks[idx].translationComplete {
                    self.chunks[idx].zh = live
                    if !live.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.timingRecorder.first(attempt, at: ProcessInfo.processInfo.systemUptime)
                    }
                }
            }
        } onDone: { [weak self] final in
            callbackContinuation?.yield(.completion(request) { [weak self] in
                await Task { @MainActor in
                guard let self, gen == self.sessionGen, self.activeTranslationAttempts[id] == attempt else { return }
                self.activeTranslationAttempts.removeValue(forKey: id)
                self.inflight = max(0, self.inflight - 1)
                guard let idx = self.chunks.firstIndex(where: { $0.id == id }) else { return }
                if let final {
                    self.chunks[idx].zh = final
                    if !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.timingRecorder.first(attempt, at: ProcessInfo.processInfo.systemUptime)
                    }
                }
                self.timingRecorder.finish(attempt, pending: self.chunks[idx].timingPendingAt,
                    chunk: self.chunks[idx].timingCreatedAt, request: requestedAt,
                    end: ProcessInfo.processInfo.systemUptime, succeeded: final != nil,
                    metadata: self.chunks[idx].timingMetadata?.row)
                if final != nil {
                    self.chunks[idx].isDraft = false
                    self.chunks[idx].translationComplete = true
                    self.translationSucceeded()
                    self.pushChunk(self.chunks[idx], index: idx)
                    self.lastFinalMs = Int(Date().timeIntervalSince(self.chunks[idx].createdAt) * 1000)
                    self.updateRunningStatus()
                    self.queueTranslatedChunksForMeetingSummary()
                    if !self.translationRetryQueue.isEmpty { self.retryFailedChunks() }   // 网络恢复：把失败的补翻
                } else if self.running || self.finishingCaptions {
                    self.chunks[idx].translationComplete = false
                    self.chunks[idx].retryAfter = Date().addingTimeInterval(pow(2, Double(self.chunks[idx].translationAttempts)))
                    self.chunks[idx].translationExhausted = self.chunks[idx].translationAttempts == 3
                    if self.chunks[idx].translationExhausted {
                        self.chunks[idx].zh = ""
                        self.chunks[idx].isDraft = false
                        self.scheduleTranscriptSave()
                    }
                    self.translationRetryQueue.enqueue(id)
                }
                }.value
            })
        }
        }
    }

    private func consumeTranslationCallbacks(_ events: AsyncStream<TranslationCallbackEvent>, generation: Int) async {
        var buffers: [UUID: TranslationConnectivityStatusBuffer] = [:]
        for await event in events {
            guard !Task.isCancelled, sessionGen == generation else { return }
            let request = event.request
            guard activeTranslationAttempts[request.chunk] == request.attempt else {
                buffers[request.attempt] = nil
                continue
            }
            switch event {
            case .status(_, let text):
                let message = buffers[request.attempt, default: .init()].receiveStatus(text)
                if let message, (running || starting), !switchingMeetingLanguage { status = message }
            case .failure(_, let failure):
                let transient: Bool
                switch failure { case .network, .server, .cancelled: transient = true; default: transient = false }
                let message = buffers[request.attempt, default: .init()].classifyStatus(transient: transient)
                if let message, (running || starting), !switchingMeetingLanguage { status = message }
                handleFailure(failure, chunk: request.chunk)
            case .completion(_, let finish):
                await finish()
                buffers[request.attempt] = nil
            }
        }
    }

    /// 翻译失败分类处理：本机不可用/Key 失效 → 停翻 + 横幅；限频 → 退避；网络 → 等重试
    private func handleFailure(_ f: TranslateFailure, chunk: UUID? = nil) {
        guard running || starting || finishingCaptions else { return }
        switch f {
        case .unauthorized:
            pauseForInvalidOpenAIKey()
        case .localUnavailable(let message):
            pause(.local)
            errorBanner = CaptionBanner(text: message, action: .settings)
            status = tr("本机翻译不可用")
        case .rateLimited:
            rateLimitedUntil = Date().addingTimeInterval(4)
            updateTranslationConnectivity()
            status = tr("请求太频繁，稍等片刻")
            let gen = sessionGen
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) { [weak self] in
                guard let self, self.sessionGen == gen else { return }
                self.retryFailedChunks()
            }
        case .network:
            translationFailed(chunk: chunk)
        case .server:
            translationFailed(chunk: chunk)
        case .cancelled:
            break
        }
    }

    /// 补翻时优先最近可重试的块；跳过退避/耗尽项，不阻塞更旧的块。
    private func retryFailedChunks() {
        guard running || finishingCaptions, !translationPaused else { return }
        if let until = rateLimitedUntil, until > Date() { return }
        var ids = Array(translationRetryQueue.takeRecent(limit: chunks.count).reversed())
        while inflight < 3, !ids.isEmpty {
            let id = ids.removeFirst()
            guard let idx = chunks.firstIndex(where: { $0.id == id }), !chunks[idx].translationComplete else { continue }
            guard activeTranslationAttempts[id] == nil else { continue }
            guard chunks[idx].translationAttempts < 3 else {
                continue
            }
            guard chunks[idx].retryAfter <= Date() else {
                translationRetryQueue.enqueue(id); continue
            }
            requestTranslation(for: id, text: chunks[idx].en)
        }
        translationRetryQueue.requeue(ids)   // 本轮名额不够的留到下次成功时再补
    }

    // ==== 气泡模式（实验）：发言者格子上浮漫画气泡 ====
    var bubbleMode: Bool = false {
        didSet {
            if SessionControls.resolvedBubbleMode(stored: bubbleMode) { return }
            if bubbleMode {
                bubbleMode = false
                return
            }
            UserDefaults.standard.set(false, forKey: "bubbleMode")
            if running { stopBubble() }
        }
    }
    var debugBubble = false           // 调试：覆盖窗画出格子/人脸检测框（发行版关）
    var speakerTile: CGRect?          // 发言者格子（归一化，相对覆盖窗）
    var speakerFace: CGRect?          // 发言者人脸（归一化），气泡优先锚这里
    var bubbleText: String {          // 气泡内容 = 最近两块译文（切块碎，两块才够一口气）
        let recent = chunks.suffix(6).filter { !$0.zh.isEmpty && !$0.zh.hasPrefix("⚠") }.suffix(2)
        let joined = recent.map(\.zh).joined(separator: " ")
        return joined.count > 90 ? String(joined.suffix(90)) : joined
    }
    private let locator = SpeakerLocator()

    private var lastTileAt: Date?
    private var pendingTile: CGRect?
    private var pendingFace: CGRect?
    private var pendingCount = 0

    private func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.midX - b.midX) < 0.08 && abs(a.midY - b.midY) < 0.08
    }

    func startBubble() {
        locator.onLocation = { [weak self] loc in
            guard let self else { return }
            if let loc {
                BubbleOverlayController.shared.align(to: loc.windowFrame)
                if let cur = speakerTile, near(cur, loc.tileRect) {
                    if speakerFace == nil { speakerFace = loc.faceRect }
                    pendingTile = nil; pendingCount = 0
                } else {
                    if let p = pendingTile, near(p, loc.tileRect) {
                        pendingCount += 1
                        if loc.faceRect != nil { pendingFace = loc.faceRect }
                    } else {
                        pendingTile = loc.tileRect; pendingFace = loc.faceRect; pendingCount = 1
                    }
                    if pendingCount >= 3 || speakerTile == nil {
                        speakerTile = pendingTile ?? loc.tileRect
                        speakerFace = pendingFace ?? loc.faceRect
                        pendingTile = nil; pendingCount = 0
                    }
                }
                lastTileAt = Date()
                BubbleOverlayController.shared.show()
            } else {
                if let t = lastTileAt, Date().timeIntervalSince(t) > 3 { speakerTile = nil; speakerFace = nil }
            }
        }
        Task { await locator.start() }
    }

    /// 调试快照：把检测器眼里的当前帧 + 检测框存 PNG（开发用，存 Caches 不进文稿）
    func saveBubbleSnapshot() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kikishima/debug", isDirectory: true)
        if let url = locator.saveDebugSnapshot(to: dir) {
            status = tr("快照已存 %@", url.lastPathComponent)
        } else {
            status = tr("没有可存的帧（气泡模式开着且会议窗口在吗？）")
        }
    }

    func stopBubble() {
        locator.stop()
        speakerTile = nil
        BubbleOverlayController.shared.hide()
    }

    // 用户点开菜单即预热连接（意图信号），30 秒节流
    private var lastPrewarm: Date?
    func prewarm() {
#if SHOOT || DEBUG
        if ShootSimulation.requestedMode != nil { return }
#endif
        if let t = lastPrewarm, Date().timeIntervalSince(t) < 30 { return }
        lastPrewarm = Date()
        translator.warmup()
    }

    /// 岛高度分档只改内容尺寸；桌面窗高度由用户拖动调整。
    func applyCaptionGeometry() {
        if supportsIslandSizing {
            CaptionPanelController.shared.applyWidthSelection()
        }
    }
}


#if SHOOT
import AVFoundation

/// Isolated hardware probe: no CaptionState, transcription engine or Translator.
@MainActor
enum ShootAudioOnly {
    nonisolated static var requested: Bool {
        ProcessInfo.processInfo.environment["KIKISHIMA_SHOOT_AUDIO_ONLY"] == "1"
    }
    private static var capture: SystemAudioTap?
    private static let meter = AudioMeter()
    static func start() {
        guard capture == nil else { return }
        let tap = SystemAudioTap(), meter = meter
        var format: AVAudioFormat?
        do {
            try tap.start { _, input, _, _, _ in
                if format == nil, var description = tap.streamDescription {
                    format = AVAudioFormat(streamDescription: &description)
                }
                guard let format else { return }
                meter.ingest(input, format: format)
            }
            capture = tap
        } catch {
            FileHandle.standardError.write(Data("Audio-only capture failed: \(error.localizedDescription)\n".utf8))
        }
    }
    static func stop() { capture?.stop(); capture = nil }
}
#endif

#if DEBUG || SHOOT
/// Opt-in numerical diagnostics only; release contains neither code nor trigger.
private enum CaptionLevelLog {
    private static let path = ProcessInfo.processInfo.environment["KIKISHIMA_LEVEL_LOG"]
    private static let writer = DispatchQueue(label: "com.kikishima.level-log")
    static func append(level: Double) {
        guard let path, !path.isEmpty else { return }
        let timestamp = Date()
        writer.async {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let line = "\(formatter.string(from: timestamp)) level=\(level) voiceDetected=\(level > 0.02)\n"
            let url = URL(fileURLWithPath: path)
            if !FileManager.default.fileExists(atPath: path) {
                guard FileManager.default.createFile(atPath: path, contents: nil) else { return }
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } catch { /* Diagnostics must never interrupt audio or translation. */ }
        }
    }
}
#endif
