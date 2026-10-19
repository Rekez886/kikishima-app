// 首次启动引导：欢迎 → 语言 → 会议语言 → 权限 → 登录 → 开始
// 只有走到「完成 / 现在就试」才标记 onboarded；中途关窗下次启动还会再来（帮助页也能手动重跑）
import SwiftUI
import AppKit
import Speech
import IOKit.hid

@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    static let shared = OnboardingController()
    private var window: NSWindow?

    static var needed: Bool { !UserDefaults.standard.bool(forKey: "onboarded") }
    static func markDone() { UserDefaults.standard.set(true, forKey: "onboarded") }

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            w.title = tr("欢迎使用 Kikishima")
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            w.contentView = NSHostingView(rootView: OnboardingView(state: CaptionState.shared, finish: { [weak self] enterMain in
                Self.markDone()
                self?.window?.orderOut(nil)
                if enterMain { AppDelegate.enter() }   // 引导结束进主窗口；「现在就试」不进（主窗会挡在字幕前）
            }))
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 帮助页「重新运行首次引导」：从第一页重来
    func restart() {
        window?.orderOut(nil)
        window = nil
        show()
    }
}

struct OnboardingView: View {
    @Bindable var state: CaptionState
    var finish: (_ enterMain: Bool) -> Void
    @State private var page = 0
    @State private var email = ""
    @State private var code = ""
    @State private var showEmailSignIn = false
    private let total = 6
    private let signInPage = 4

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                // Keep the system key loop open to the page controls, not just the footer.
                ScrollView {
                    Group {
                        switch page {
                        case 0: welcome
                        case 1: LanguagePage(state: state)
                        case 2: MeetingLanguagesPage(state: state)
                        case 3: PermissionsPage(state: state)
                        case 4: signIn
                        default: ready
                        }
                    }
                    .kkKeyboardPage("onboarding-\(page)")
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .id(page)
            }
            .clipped()

            HStack {
                if page > 0 { Button(tr("上一步")) { page -= 1 }.accessibilityIdentifier("kk-onboarding-previous") }
                Spacer()
                Text("\(page + 1) / \(total)").font(.caption).foregroundStyle(KKColor.textTertiary)
                Spacer()
                if page < total - 1 {
                    if page == signInPage && state.sessionToken.isEmpty {
                        Button(tr("以后再说")) { page += 1 }.accessibilityIdentifier("kk-onboarding-skip").buttonStyle(.bordered)   // 跳过不能是全页最显眼的按钮
                    } else {
                        Button(tr("下一步")) { page += 1 }.accessibilityIdentifier("kk-onboarding-next").kkPrimaryButton()
                    }
                } else {
                    Button(tr("完成")) { finish(true) }.accessibilityIdentifier("kk-onboarding-finish")
                        .kkPrimaryButton()
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .background(KKColor.textPrimary.opacity(0.03))
        }
        .buttonStyle(KKQuietButtonStyle())
        .kkNeutralControls()
    }

    private var welcome: some View {
        OnboardingWelcome(privacy: privacyStatement)
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("登录")).font(.title2.bold())
            if !state.sessionToken.isEmpty {
                Label(tr("已登录：%@", state.accountEmail.isEmpty ? tr("账号") : state.accountEmail), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(KKColor.textSecondary)
                Text(state.plan == "pro" ? tr("Pro 档") : tr("免费版：每周 60 分钟翻译字幕，付费后同一邮箱自动升级 Pro。"))
                    .font(.callout).foregroundStyle(KKColor.textSecondary)
            } else if state.codeSent {
                Text(tr("验证码已发到 %@，10 分钟内有效。", state.accountEmail)).font(.callout).foregroundStyle(KKColor.textSecondary)
                HStack {
                    TextField(tr("6 位验证码"), text: $code).kkFocusRing()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { state.verifyEmailCode(code: code) }
                    Button(state.activating ? tr("验证中…") : tr("登录")) { state.verifyEmailCode(code: code) }
                        .kkPrimaryButton()
                        .disabled(code.filter(\.isNumber).count != 6 || state.activating)
                }
                HStack {
                    Button(tr("换个邮箱")) { state.codeSent = false; code = "" }
                    Button(tr("重新发送")) { state.requestEmailCode(email: state.accountEmail) }.disabled(state.activating)
                }.font(.caption)
            } else {
                Text(tr("免费版每周 60 分钟，登录即用，不需要信用卡。")).font(.callout).foregroundStyle(KKColor.textSecondary)
                let hasSocial = state.serverProviders.google || state.canSignInWithApple
                VStack(spacing: 8) {
                    if state.serverProviders.google {
                        SignInTile(title: tr("使用 Google 登录"), icon: "globe") { state.signInWithGoogle() }
                            .disabled(state.activating)
                    }
                    if state.canSignInWithApple {
                        SignInTile(title: tr("通过 Apple 登录"), icon: "apple.logo") { state.signInWithApple() }
                            .disabled(state.activating)
                    }
                    if hasSocial {
                        SignInTile(title: tr("使用邮箱登录"), icon: "envelope") { showEmailSignIn.toggle() }
                            .disabled(state.activating)
                    }
                }
                if showEmailSignIn || !hasSocial {
                    HStack {
                        TextField(tr("邮箱"), text: $email).kkFocusRing()
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.emailAddress)
                            .onSubmit { state.requestEmailCode(email: email) }
                        Button(state.activating ? tr("发送中…") : tr("发送验证码")) { state.requestEmailCode(email: email) }
                            .kkPrimaryButton()
                            .disabled(!email.contains("@") || state.activating)
                    }
                }
                if state.activating {
                    Button(tr("取消")) { state.cancelSignIn() }.font(.caption)
                }
            }
            if !state.activationError.isEmpty {
                Text(state.activationError).font(.caption).foregroundStyle(KKColor.error)
            }
        }
        .padding(30)
    }

    private var readyPreviewSource: String {
#if SHOOT || DEBUG
        if ShootSimulation.requestedMode != nil { return ShootSimulation.previewSource }
#endif
        return "Let's review the next steps together."
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("可以开会了")).font(.title2.bold())
            HomeCaptionPreview(source: readyPreviewSource,
                translation: HomeCaptionPreview.sampleTranslation(for: state.targetLang), status: "",
                compact: true, display: state.captionDisplay,
                desktop: state.captionSurface == "window", isExample: true)
            Text(.init(tr("开会时：菜单栏点图标 → 开始字幕，或者 **%@**。字幕窗会浮在会议窗口上面，全屏也能看到。", GlobalHotkey.displayText)))
                .font(.callout)
            Text(tr("会议是日语或其他语言？在「打开 Kikishima」里改会议语言。人名、产品名总被翻错？把它们加进术语表。"))
                .font(.callout).foregroundStyle(KKColor.textSecondary)
            Button {
                finish(false)
                state.toggle()
            } label: {
                Label(tr("现在就试一下（开始字幕）"), systemImage: "play.fill")
            }
            .kkPrimaryButton()
            .disabled(state.sessionToken.isEmpty)
            if state.sessionToken.isEmpty {
                HStack(spacing: 8) {
                    Text(tr("还没登录，登录后才能开始翻译。")).font(.caption).foregroundStyle(KKColor.warning)
                    Button(tr("去登录")) { page = signInPage }.font(.caption)
                }
            }
        }
        .padding(30)
    }
}


// MARK: - 权限页（参考 Screenflare：一页列清楚，每项一个「允许」，必需/可选打标，状态实时更新）

enum PermissionStatus { case unknown, prompted, granted, denied, needsSettings, unconfirmed }

struct PermissionsPage: View {
    @Bindable var state: CaptionState
    @State private var audioProbeInFlight = false
    @State private var audio: PermissionStatus = .unknown
    @State private var speech: PermissionStatus = .unknown
    @State private var input: PermissionStatus = .unknown
    @State private var busyItem: String?      // 只禁用正在处理的那一行，别让整页像卡死
    @State private var hintFor: String?       // 拖拽提示条当前是给哪一项开的：该项拿到权限就收
    @State private var autoAsked = false      // 进页自动申请一次（顺序：系统音频 → 语音识别），别叠两个系统弹窗

    /// 系统音频：起一次 tap 探测（首次会触发系统授权框）。done 在结果落定后调用
    private func requestAudio(done: (() -> Void)? = nil) {
        guard !audioProbeInFlight else { return }
        audioProbeInFlight = true
        busyItem = "audio"
        audio = .prompted
        Task {
            let evidence = await SystemAudioTap.probePermission()
            applyAudioEvidence(evidence)
            audioProbeInFlight = false
            if busyItem == "audio" { busyItem = nil }
            done?()
        }
    }
    /// 语音识别：系统授权框
    private func requestSpeech() {
        busyItem = "speech"
        SFSpeechRecognizer.requestAuthorization { st in
            DispatchQueue.main.async {
                speech = st == .authorized ? .granted : .needsSettings
                if st != .authorized { openSettings("Privacy_SpeechRecognition", item: "speech") }
                busyItem = nil
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("几项权限")).font(.title2.bold())
            Text(tr("macOS 会在 app 听声音之前先问一次。Kikishima 只在字幕运行时使用它们，音频不会离开你的 Mac。"))
                .font(.callout).foregroundStyle(KKColor.textSecondary)

            PermissionRow(id: "system-audio", icon: "speaker.wave.2.circle.fill", title: tr("系统音频录制"), required: true,
                          why: tr("听到会议里对方的声音。这是唯一途径。"), status: audio, busy: busyItem == "audio") {
                if audio == .needsSettings || audio == .unconfirmed {
                    openSettings("Privacy_AudioCapture", item: "audio")
                } else { requestAudio() }
            }
            PermissionRow(id: "speech", icon: "waveform.circle.fill", title: tr("语音识别"), required: true,
                          why: tr("把声音转成文字，全程在本机完成。"), status: speech, busy: busyItem == "speech") { requestSpeech() }
            PermissionRow(id: "input-monitoring", icon: "command.circle.fill", title: tr("输入监控"), required: false,
                          why: tr("识别「双击左 ⌘」这个快捷键。不给的话用 %@。", GlobalHotkey.comboDisplay), status: input, busy: busyItem == "input") {
                let wasDenied = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeDenied
                _ = GlobalHotkey.requestInputMonitoring()   // 已拒绝时会直接打开系统设置
                if wasDenied { PermissionDropHelper.shared.show(listName: tr("输入监控")); hintFor = "input" }
                refresh()
            }

            if audio != .granted || speech != .granted {
                Text(tr("两项必需权限还没都允许：现在不给也行，开始字幕时系统会再问一次。")).font(.caption).foregroundStyle(KKColor.warning)
            }
            Text(tr("之后随时可以在 系统设置 › 隐私与安全性 里更改。")).font(.caption).foregroundStyle(KKColor.textTertiary)
        }
        .padding(30)
        .onAppear {
#if DEBUG
            if R11TestEnvironment.active { return } // Tab-test the real rows without prompting.
#endif
            refresh(probeAudio: false)
            if !autoAsked {
                autoAsked = true
                requestAudio(done: { if speech == .unknown && busyItem != "speech" { requestSpeech() } })
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
#if DEBUG
            if R11TestEnvironment.active { return }
#endif
            refresh()
        }   // 从系统设置回来即刷新
    }

    private func refresh(probeAudio: Bool = true) {
        speech = {
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .notDetermined: return .unknown
            default: return .needsSettings
            }
        }()
        input = GlobalHotkey.inputMonitoringGranted ? .granted
              : (IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeDenied ? .needsSettings : .unknown)
        if input == .granted { GlobalHotkey.reinstall() }
        if (hintFor == "input" && input == .granted) || (hintFor == "speech" && speech == .granted) { PermissionDropHelper.shared.hide(); hintFor = nil }
        // 刚让用户去点系统弹窗：回来静默再探一次（已授权时不会再弹）
        if probeAudio && !audioProbeInFlight && busyItem == nil {
            audioProbeInFlight = true
            busyItem = "audio"
            Task {
                let evidence = await SystemAudioTap.probePermission()
                applyAudioEvidence(evidence)
                audioProbeInFlight = false
                if busyItem == "audio" { busyItem = nil }
            }
        }
    }

    private func applyAudioEvidence(_ evidence: SystemAudioTap.PermissionEvidence) {
        switch evidence {
        case .verified: audio = .granted
        case .unconfirmed: audio = .unconfirmed
        case .failed: audio = .needsSettings
        }
        if audio == .granted, hintFor == "audio" {
            PermissionDropHelper.shared.hide()
            hintFor = nil
        }
    }

    /// 打开系统设置对应隐私页 + 浮出「把 Kikishima 拖进列表」提示条
    private func openSettings(_ pane: String, item: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
        let listName: String = {
            switch pane {
            case "Privacy_AudioCapture": return tr("屏幕录制与系统录音")
            case "Privacy_SpeechRecognition": return tr("语音识别")
            case "Privacy_ListenEvent": return tr("输入监控")
            default: return tr("隐私与安全性")
            }
        }()
        hintFor = item
        PermissionDropHelper.shared.show(listName: listName)
    }
}

struct PermissionRow: View {
    var id: String
    var icon: String
    var title: String
    var required: Bool
    var why: String
    var status: PermissionStatus
    var busy: Bool
    var action: () -> Void

    private var statusText: String {
        switch status {
        case .granted: return tr("已允许")
        case .unconfirmed: return tr("尚未确认系统音频权限，请在系统设置里检查；播放声音后回来重试。")
        case .needsSettings: return tr("被拒绝过：请在系统设置里打开，回来会自动刷新。")
        case .prompted: return tr("请在弹出的系统对话框里允许，回来会自动刷新。")
        case .denied: return tr("被拒绝")
        case .unknown: return why
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(KKColor.textSecondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    Text(required ? tr("必需") : tr("可选"))
                        .font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(required ? KKColor.error.opacity(0.15) : KKColor.textTertiary.opacity(0.15)))
                        .foregroundStyle(required ? KKColor.error : KKColor.textSecondary)
                }
                Text(statusText)
                    .font(.caption).foregroundStyle(status == .needsSettings || status == .prompted ? KKColor.warning : KKColor.textSecondary)
            }
            Spacer()
            switch status {
            case .granted:
                Label(tr("已允许"), systemImage: "checkmark.circle.fill").foregroundStyle(KKColor.textSecondary).font(.callout)
            case .needsSettings, .denied, .unconfirmed:
                Button(tr("打开系统设置")) { action() }.controlSize(.small)
                    .accessibilityIdentifier("kk-permission-action-" + id)
            case .prompted:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(tr("未允许")).font(.caption).foregroundStyle(KKColor.warning)
                }
            case .unknown:
                Button(tr("允许")) { action() }.buttonStyle(KKQuietButtonStyle()).controlSize(.small).disabled(busy)
                    .accessibilityIdentifier("kk-permission-action-" + id)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(KKColor.surfaceRaised))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)：\(statusText)")
    }
}


// MARK: - 语言页

/// 五种界面语言（= 首批本地化范围）；prompt 为译文语言的英文名，locale 为该语言的会议转写 locale
struct UILang: Identifiable {
    let code: String, native: String, prompt: String, locale: String
    var id: String { code }
    static let all: [UILang] = [
        UILang(code: "zh-Hans", native: "简体中文", prompt: "Simplified Chinese", locale: "zh_CN"),
        UILang(code: "zh-Hant", native: "繁體中文", prompt: "Traditional Chinese", locale: "zh_TW"),
        UILang(code: "ja", native: "日本語", prompt: "Japanese", locale: "ja_JP"),
        UILang(code: "en", native: "English", prompt: "English", locale: "en_US"),
        UILang(code: "ko", native: "한국어", prompt: "Korean", locale: "ko_KR"),
    ]
    /// 按系统语言猜默认
    static var systemDefault: UILang {
        let pref = Locale.preferredLanguages.first ?? "en"
        if pref.hasPrefix("zh-Hant") || pref.hasPrefix("zh-TW") || pref.hasPrefix("zh-HK") { return all[1] }
        if pref.hasPrefix("zh") { return all[0] }
        if pref.hasPrefix("ja") { return all[2] }
        if pref.hasPrefix("ko") { return all[4] }
        return all[3]
    }
}

/// 会议语言的显示名跟随「界面语言」而不是系统语言（否则日文界面里语言列表是英文）
@MainActor func localeName(_ id: String) -> String {
    let ui = CaptionState.shared.uiLanguage
    let loc = Locale(identifier: ui.isEmpty ? "en" : ui)
    return loc.localizedString(forIdentifier: id) ?? id
}

struct LanguagePage: View {
    @Bindable var state: CaptionState
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("你最熟悉的语言是哪一个？")).font(.title2.bold())
            Text(tr("界面和字幕译文都会用这个语言。之后随时能改。")).font(.callout).foregroundStyle(KKColor.textSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                ForEach(UILang.all) { l in
                    LanguageChoiceTile(title: l.native, selected: state.uiLanguage == l.code) {
                        state.uiLanguage = l.code
                        state.targetLang = l.prompt
                    }
                }
            }
            Text(tr("界面和译文会立即切换。")).font(.caption).foregroundStyle(KKColor.textTertiary)
        }
        .padding(30)
        .onAppear {
            if state.uiLanguage.isEmpty {
                let d = UILang.systemDefault
                state.uiLanguage = d.code; state.targetLang = d.prompt
            }
        }
    }
}

/// 常用会议语言（多选 → 预下载模型；第一个作默认会议语言）
struct MeetingLanguagesPage: View {
    @Bindable var state: CaptionState
    @State private var all: [Locale] = []
    @State private var showAll = false
    private let common = ["en_US", "ja_JP", "zh_CN", "zh_TW", "ko_KR", "es_ES", "fr_FR", "de_DE", "pt_BR", "it_IT"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("开会时通常会听到哪些语言？")).font(.title2.bold())
            Text(tr("可以多选。选好后会在后台下载对应的离线转写模型（每个几百 MB，只下一次）。")).font(.callout).foregroundStyle(KKColor.textSecondary)
            let commonShown = common.filter { c in all.isEmpty || all.contains { $0.identifier == c } }
            let shown = showAll ? all.map(\.identifier) : commonShown + state.meetingLocales.filter { !commonShown.contains($0) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(shown, id: \.self) { id in
                    let on = state.meetingLocales.contains(id)
                    Button {
                        if on { state.meetingLocales.removeAll { $0 == id } }
                        else { state.meetingLocales.append(id); state.predownloadModels([id]) }
                        if let first = state.meetingLocales.first { state.localeID = first }
                    } label: {
                        HStack {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? KKColor.textPrimary : KKColor.textSecondary)
                            Text(localeName(id)).lineLimit(1)
                            Spacer()
                            if state.modelReady(id) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(KKColor.textSecondary).font(.caption)
                                    .accessibilityLabel(tr("模型已安装"))
                            } else {
                                Text(tr("需下载")).font(.caption).foregroundStyle(KKColor.textSecondary)
                            }
                        }
                        .padding(.horizontal, 8).frame(minHeight: 34)
                        .foregroundStyle(KKColor.textPrimary)
                        .background(on ? KKColor.surfaceSelected : KKColor.surfaceRaised,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(KKColor.textPrimary.opacity(on ? 1 : 0), lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(KKPlainButtonStyle(radius: 8))
                    .accessibilityLabel(localeName(id))
                    .accessibilityIdentifier("kk-meeting-language-" + id)
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                    .help(localeName(id))
                }
            }
            HStack {
                if !all.isEmpty {
                    Button(showAll ? tr("只看常用") : tr("显示全部 %@ 种", all.count)) { showAll.toggle() }.font(.caption)
                }
                Spacer()
                if let first = state.meetingLocales.first {
                    Text(tr("默认会议语言：%@", localeName(first))).font(.caption).foregroundStyle(KKColor.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle(tr("选了就下载模型（建议在 Wi-Fi 下）"), isOn: $state.autoDownloadModels).toggleStyle(KKSwitchToggleStyle()).controlSize(.small)
                    .accessibilityLabel(tr("选了就下载模型（建议在 Wi-Fi 下）"))
                    .accessibilityIdentifier("kk-onboarding-download-models")
                Text(state.autoDownloadModels ? tr("已选 %@ 种，每种几百 MB，只下一次。", state.meetingLocales.count) : tr("稍后下载：开始字幕时再按需下载当前会议语言的模型。"))
                    .font(.caption).foregroundStyle(KKColor.textSecondary)
            }
        }
        .padding(30)
        .padding(.bottom, 16)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            await state.refreshModelInstallation()
            all = await SpeechTranscriber.supportedLocales.sorted { ($0.identifier) < ($1.identifier) }
            if state.meetingLocales.isEmpty {
                // 默认：英语 + 母语对应的会议语言（母语不是英语时）
                var picks = ["en_US"]
                if let mine = UILang.all.first(where: { $0.code == state.uiLanguage }), mine.locale != "en_US" { picks.append(mine.locale) }
                state.meetingLocales = picks.filter { c in all.contains { $0.identifier == c } }
                if let f = state.meetingLocales.first { state.localeID = f }
                state.predownloadModels(state.meetingLocales)
            }
        }
    }
}
