// Kikishima — 菜单栏 app + 悬浮字幕窗
import SwiftUI
import AppKit
import MacControlCenterUI
import MenuBarExtraAccess
import Pow

#if DEBUG
/// UI automation uses the existing screenshot-simulation isolation, never a signed-in session.
enum R11TestEnvironment {
    static var active: Bool {
        Bundle.main.bundleIdentifier == "com.kikishima.mac.r11test"
            && ProcessInfo.processInfo.environment["KIKISHIMA_R11_E2E"] == "1"
            && ShootSimulation.requestedMode != nil
    }
}
#endif

/// All listening surfaces use the same warning precedence and localized copy.
@MainActor
enum CaptionListeningStatus {
    static func text(silentTooLong: Bool, audioStalled: Bool) -> String {
        if audioStalled { return tr("音频中断，正在恢复") }
        if silentTooLong { return tr("没听到声音") }
        return tr("正在听…")
    }
}

/// Dock 图标 + 主窗口：菜单栏常驻，但点 Dock 图标 / 菜单「打开 Kikishima」都进同一个主窗口（Wispr Flow 式）
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var waitingForTermination = false
    static var showDockIcon: Bool {
        get { UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showDockIcon"); apply() }
    }
    static func apply() { NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory) }
    /// 由 SwiftUI 侧注入（openWindow 只能在 View 环境里拿到）
    static var openMainWindow: (() -> Void)?
    /// Injected by the owner of menuPresented; never simulate a status-item click.
    static var presentMenuPanel: (() -> Void)?
    static func openMenuPanel() { presentMenuPanel?() }
    static weak var menuStatusButton: NSStatusBarButton?
    static func restoreMenuStatusFocus() {
        guard let button = menuStatusButton, let window = button.window else { return }
        // A first responder in a non-key window is not the application's AX focus.
        // Run after ordering the popup out, so its close cannot select main again.
        window.makeKey()
        let accepted = window.makeFirstResponder(button)
        button.setAccessibilityFocused(true)
        if window.isKeyWindow && accepted {
            NSAccessibility.post(element: button, notification: .focusedUIElementChanged)
        }
#if DEBUG
        let evidence = "KKMenuStatusFocus window=\(type(of: window)) canBecomeKey=\(window.canBecomeKey) isKey=\(window.isKeyWindow) accepted=\(accepted) responderIsButton=\(window.firstResponder === button) axFocused=\(button.isAccessibilityFocused())\n"
        FileHandle.standardError.write(Data(evidence.utf8))
#endif
    }
    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") ?? false }   // 只按 SwiftUI Window id 找，不看标题（字幕窗曾同名撞车）
    }
    /// 收起菜单栏弹出窗（SwiftUI MenuBarExtra 没给关闭 API：点击时它就是 keyWindow，无标题、非主窗、非字幕窗）
    static func dismissMenuBarPopup() {
        if let k = NSApp.keyWindow, k.title.isEmpty, !(k.identifier?.rawValue.hasPrefix("main") ?? false) { k.close() }   // 字幕窗标题「字幕」非空，不会误关
    }
    /// 打开主窗口；section 给了就切到那一栏（登录提示 → 设置，⌘, → 设置）
    static func enter(section: MainSection? = nil) {
        if let section { CaptionState.shared.mainSection = section }
        dismissMenuBarPopup()
        NSApp.activate(ignoringOtherApps: true)
        if let w = mainWindow() { w.makeKeyAndOrderFront(nil); w.orderFrontRegardless(); return }
        openMainWindow?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.activate(ignoringOtherApps: true)
            if let w = mainWindow() { w.makeKeyAndOrderFront(nil); w.orderFrontRegardless() }   // regardless：即使系统没把我们当前台也硬顶到最前
        }
    }
    static var showMainOnLaunch: Bool {
        get { UserDefaults.standard.object(forKey: "showMainOnLaunch") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showMainOnLaunch") }
    }
    /// 状态栏图标就位（openMainWindow 已注入）→ 启动即显示主窗口（不是静默常驻）；引导期间不弹，引导结束由它自己接管
    private static var launchShown = false
    static func hostReady() {
#if SHOOT
        if ShootAudioOnly.requested { return }
#endif
#if SHOOT || DEBUG
        if ShootSimulation.requestedMode != nil { return }
#endif
        guard !launchShown else { return }
        launchShown = true
        if showMainOnLaunch && !OnboardingController.needed { enter() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
#if SHOOT
        if ShootAudioOnly.requested { ShootAudioOnly.start(); return }
#endif
#if SHOOT || DEBUG
        ShootSimulation.applyRequestedAppearance()
#endif
#if DEBUG
        if R11TestEnvironment.active {
            CaptionState.shared.captionSurface = "window"
            Self.apply()
            if OnboardingController.needed { OnboardingController.shared.show() }
            else { Self.enter() }
            // Localized screenshot runs need both real surfaces without a menu toggle.
            if ShootSimulation.requestedMode == .paused || ShootSimulation.requestedMode == .desktop {
                ShootSimulation.showCaptions()
            }
            return
        }
#endif
#if SHOOT || DEBUG
        if ShootSimulation.requestedMode != nil { Self.apply(); ShootSimulation.showCaptions(); return }
#endif
        Self.apply()
        _ = UpdaterController.shared            // 起 Sparkle 后台检查
        CaptionState.shared.probeProviders()    // 服务器开了哪些第三方登录
        // 兜底：状态栏图标的 onAppear 迟迟不来（极少）也别让用户对着一片静默
        Task { @MainActor in try? await Task.sleep(for: .seconds(2)); Self.hostReady() }
    }
    /// 回到前台：刷一次档位（付款回来 / 别处改了订阅），30 秒节流
    func applicationDidBecomeActive(_ notification: Notification) {
#if SHOOT
        if ShootAudioOnly.requested { return }
#endif
#if SHOOT || DEBUG
        if ShootSimulation.requestedMode != nil { return }
#endif
        CaptionState.shared.refreshPlanIfStale(seconds: 30)
    }
    /// 网页版 Google / Apple 登录回跳：kikishima://signed-in?code=…&state=…（或 ?error=…）
    func application(_ application: NSApplication, open urls: [URL]) {
#if SHOOT
        if ShootAudioOnly.requested { return }
#endif
        for url in urls where url.scheme == "kikishima" {
            if url.host == "billing-return" {
                CaptionState.shared.restorePurchases()
            } else {
                CaptionState.shared.handleAuthCallback(url)
            }
            Self.enter()
        }
    }
    /// ⌘Q / Dock 退出 / 注销：先停字幕把记录写完
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
#if SHOOT
        if ShootAudioOnly.requested { ShootAudioOnly.stop(); return .terminateNow }
#endif
        let s = CaptionState.shared
#if DEBUG
        FileHandle.standardError.write(Data("KKTermination received running=\(s.running) starting=\(s.starting) pending=\(s.hasPendingMeetingFinalization) waiting=\(waitingForTermination)\n".utf8))
#endif
        if s.running || s.starting { s.stop() }
        if s.hasPendingMeetingFinalization, !waitingForTermination {
            waitingForTermination = true
            Task { @MainActor in
                await s.waitForPendingMeetingFinalization()
                TranslationTimingRecorder.shared.flushBeforeExit()
#if DEBUG
                FileHandle.standardError.write(Data("KKTermination finalization-finished\n".utf8))
#endif
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
#if DEBUG
        FileHandle.standardError.write(Data("KKTermination terminateNow\n".utf8))
#endif
        TranslationTimingRecorder.shared.flushBeforeExit()
        return .terminateNow
    }
    /// 点 Dock 图标且没有可见窗口 → 进主窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if Self.mainWindow()?.isVisible != true { Self.enter() }   // 字幕窗开着也算「有窗口」，得看主窗自己
        return true
    }
}

struct KikishimaApp: App {   // 入口在 main.swift（要先判断是不是 Chrome 原生消息宿主模式）
    @State private var state = CaptionState.shared
    @State private var menuPresented = false
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
#if SHOOT
        if ShootAudioOnly.requested { return }
#endif
#if SHOOT || DEBUG
        if ShootSimulation.requestedMode != nil { return }
#endif
        GlobalHotkey.register()
        if OnboardingController.needed {
            DispatchQueue.main.async { OnboardingController.shared.show() }
        }
    }

    private var menuStatus: CaptionMenuStatus {
        .resolve(running: state.running, starting: state.starting, paused: state.paused,
                 translationPaused: state.translationPaused, resuming: state.resuming,
                 switchingLanguage: state.switchingMeetingLanguage)
    }

    private var menuStatusLabel: String {
        if state.menuShowsLogin { return tr("未登录，字幕只显示原文；登录后继续翻译") }
        if state.captionDisplayStatus.showsLabel { return state.captionStatusText }
        if state.finishingCaptions { return tr("已停止采音，正在完成最后一句…") }
        return switch menuStatus {
        case .idle: tr("已停止")
        case .starting: tr("启动中…")
        case .running: state.captionStatusText
        case .paused: tr("已暂停")
        case .translationPaused: tr("翻译已暂停")
        }
    }

    private var menuAccessPresented: Binding<Bool> {
#if SHOOT || DEBUG
        // OPEN_MENU owns its guarded session lifecycle; dependency presentation stays inert.
        if ShootSimulation.requestedOpenMenu {
            return Binding(get: { false }, set: { if !$0 { menuPresented = false } })
        }
#endif
        return $menuPresented
    }

    var body: some Scene {
        MenuBarExtra {
#if SHOOT
            if !ShootAudioOnly.requested {
                MenuContent(state: state, isPresented: $menuPresented)
            }
#else
            MenuContent(state: state, isPresented: $menuPresented)
#endif
        } label: {
            Image(nsImage: BrandIcons.menuImage(menuStatus))
                .renderingMode(.template)
                .accessibilityIdentifier("kk-status-item")
                .accessibilityLabel(tr("Kikishima 字幕") + " · " + menuStatusLabel)
                .help(tr("Kikishima 字幕") + " · " + menuStatusLabel)
                .onAppear {
                    AppDelegate.openMainWindow = { openWindow(id: "main") }
                    AppDelegate.presentMenuPanel = { menuPresented = true }
                    AppDelegate.hostReady()
#if SHOOT || DEBUG
                    if ShootSimulation.requestedOpenMenu { ShootOpenMenu.shared.start() }
#endif
                }   // 状态栏图标常驻，启动即注入
        }
        .menuBarExtraAccess(isPresented: menuAccessPresented, statusItem: { item in
            AppDelegate.menuStatusButton = item.button
#if SHOOT || DEBUG
            if ShootSimulation.requestedOpenMenu || ShootDiagnosticLog.shared?.enabled == true {
                ShootOpenMenu.shared.discovered(item, present: { menuPresented = true })
            }
#endif
        })
        .menuBarExtraStyle(.window)

        // 主窗口（左侧栏式；视觉归设计轮）
        Window("Kikishima", id: "main") {
#if SHOOT
            if !ShootAudioOnly.requested { MainWindowView() }
#else
            MainWindowView()
#endif
        }
        .defaultSize(width: 960, height: 620)
        .defaultLaunchBehavior(.suppressed)   // 启动不弹，等 hostReady / 用户「打开」
    }
}

struct MenuContent: View {
    @ObservedObject private var captionPanel = CaptionPanelController.shared
    @Namespace private var menuFocusScope
    @Environment(\.resetFocus) private var resetFocus
    @Bindable var state: CaptionState
    @Binding var isPresented: Bool
    @State private var quickTerm = ""
    @FocusState private var primaryFocused: Bool
    @State private var devices: [AudioDevices.Device] = []
    @State private var currentDevice = MenuOutputDevice.readName()
    private var outputDeviceLabel: String { MenuOutputDevice.label(currentDevice, none: tr("无")) }
    private var meetingLocaleChoices: [String] {
        var choices = state.meetingLocales
        if !choices.contains(state.localeID) { choices.insert(state.localeID, at: 0) }
        return choices
    }
    private var menuKeyboardPresented: Bool {
#if SHOOT || DEBUG
        if ProcessInfo.processInfo.environment["KIKISHIMA_SHOOT_RENDER"] != nil { return false }
#endif
        return isPresented
    }
    private func refreshDevices() {
        currentDevice = MenuOutputDevice.readName()
#if SHOOT || DEBUG
        if ProcessInfo.processInfo.environment["KIKISHIMA_SHOOT_RENDER"] != nil {
            devices = []
            return
        }
#endif
        devices = AudioDevices.outputDevices()
    }

    @Environment(\.colorScheme) private var colorScheme
    private var warning: Bool { state.captionDisplayStatus.showsLabel }
    private var brandRed: Color { KKColor.brand }

    private var isListening: Bool { state.running && !state.paused && !state.resuming && !state.switchingMeetingLanguage }
    // Menu-only English labels; shared caption labels remain unchanged.
    private var menuCaptionOptions: [(String, String)] {
        [(tr("双语"), "both"),
         (captionDisplayText("仅译文"), "translation"),
         (captionDisplayText("仅原文"), "source")]
    }

    private var statusLabel: String {
        if state.menuShowsLogin { return tr("未登录，字幕只显示原文；登录后继续翻译") }
        if state.captionDisplayStatus.showsLabel { return state.captionStatusText }
        if state.finishingCaptions { return tr("已停止采音，正在完成最后一句…") }
        return switch CaptionMenuStatus.resolve(running: state.running, starting: state.starting, paused: state.paused,
            translationPaused: state.translationPaused, resuming: state.resuming,
            switchingLanguage: state.switchingMeetingLanguage) {
        case .idle: "Kikishima"
        case .starting: tr("启动中…")
        case .running: state.captionStatusText
        case .paused: tr("已暂停")
        case .translationPaused: tr("翻译已暂停")
        }
    }

    /// 状态块：运行中是墨色的岛回声（朱红点 + 电平 + 语言对 + 设备），空闲是 5% 灰卡
    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if state.paused {
                    Image(systemName: "pause.fill").foregroundStyle(KKColor.textSecondary)
                } else {
                    Circle()
                        .fill(isListening ? (warning ? KKColor.warning : brandRed) : KKColor.textPrimary.opacity(0.25))
                        .frame(width: 8, height: 8)
                        .changeEffect(.glow(color: brandRed, radius: 8), value: state.running)
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { i in
                            Capsule().fill(isListening ? KKColor.historyInk.opacity(warning ? 0.35 : 0.9) : KKColor.textPrimary.opacity(0.25))
                                .frame(width: 3, height: i == 1 ? 11 : 7)
                        }
                    }
                }
                Text(statusLabel).font(.system(size: 13, weight: .medium))
                    .lineLimit(state.menuShowsLogin ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: state.menuShowsLogin)
                    .foregroundStyle(warning && isListening ? KKColor.warning : KKColor.textPrimary)
                Spacer()
            }
            if !state.menuShowsLogin && !state.paused && !state.captionDisplayStatus.showsLabel && state.status != statusLabel {
                Text(state.status).font(.system(size: 11))
                    .foregroundStyle(warning && isListening ? KKColor.warning : KKColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isListening {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(KKColor.historyInk.opacity(0.15))
                        Capsule().fill(warning ? KKColor.warning : KKColor.textSecondary).frame(width: max(4, g.size.width * state.audioLevel))
                    }
                }
                .frame(height: 3)
                .accessibilityLabel(tr("音频电平"))
                .animation(.linear(duration: 0.08), value: state.audioLevel)
            }
            Text(tr("捕获范围：全部系统音频")).font(.system(size: 11)).foregroundStyle(KKColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(tr("输出设备：%@", outputDeviceLabel)).font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(KKColor.textSecondary)
                Spacer()
                Menu(tr("切换")) {
                    ForEach(devices) { d in
                        Button(d.name + (d.name == currentDevice ? " ✓" : "")) { AudioDevices.setDefaultOutput(d.id); refreshDevices() }
                    }
                }.kkFocusRing().buttonStyle(.automatic)
                .menuStyle(.borderlessButton).controlSize(.small).fixedSize()
                .accessibilityLabel(tr("切换输出设备，当前 %@", outputDeviceLabel))
            }
        }
        .foregroundStyle(KKColor.textPrimary)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isListening ? KKColor.surfaceBase : KKColor.textPrimary.opacity(0.05)))
        .environment(\.colorScheme, isListening ? .dark : colorScheme)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.running)
    }

    var body: some View {
        MacControlCenterMenu(isPresented: $isPresented, width: .custom(304), activateAppOnCommandSelection: false) {
            statusBlock
            if state.menuShowsLogin {
                Button(tr("登录")) { state.mainSection = .settings; AppDelegate.enter() }
                    .kkPrimaryButton()
            } else if state.menuShowsUpgrade {
                Button(tr("升级 Pro")) { state.openUpgrade() }
                    .kkPrimaryButton()
            }

            // 主操作：开始（品牌色）/ 停止（抬升底色）+ 暂停
            Button { state.toggle() } label: {
                Label(state.running || state.starting ? tr("停止字幕") : tr("开始字幕"),
                      systemImage: state.running || state.starting ? "stop.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .kkPrimaryButton(active: state.running || state.starting)
            .disabled(state.finishingCaptions)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("kk-menu-primary")
            .focused($primaryFocused)
            .prefersDefaultFocus(true, in: menuFocusScope)
            if state.running {
                Button { state.paused ? state.resume() : state.pause() } label: {
                    Label(state.paused ? tr("继续字幕") : tr("暂停字幕"), systemImage: state.paused ? "play.circle" : "pause.circle").frame(maxWidth: .infinity)
                }
                .accessibilityLabel(state.paused ? tr("继续字幕") : tr("暂停字幕"))
                .disabled(state.switchingMeetingLanguage || state.resuming)
            }
            HStack {
                Text(tr("快捷键：%@", GlobalHotkey.displayText)).font(.caption2).foregroundStyle(KKColor.textTertiary)
                Spacer()
                if !state.sessionToken.isEmpty, state.plan != "pro", state.plan != "dev", state.usageQuota > 0 {
                    Text(state.remainingText).font(.caption2).foregroundStyle((state.remainingMinutes ?? 99) < 5 ? AnyShapeStyle(KKColor.warning) : AnyShapeStyle(KKColor.textTertiary))
                } else if state.plan == "pro" {
                    Text("Pro").font(.caption2).foregroundStyle(KKColor.textTertiary)
                }
            }

            Divider()

            // 快捷设置
            Menu(tr("会议语言：%@", localeName(state.localeID))) {
                ForEach(meetingLocaleChoices, id: \.self) { localeID in
                    Button {
                        state.selectMeetingLanguage(localeID)
                    } label: {
                        if localeID == state.localeID {
                            Label(localeName(localeID), systemImage: "checkmark")
                        } else {
                            Text(localeName(localeID))
                        }
                    }
                }
                Divider()
                Button(tr("更多会议语言…")) { AppDelegate.enter(section: .languages) }
            }.kkFocusRing().buttonStyle(.automatic)
            .disabled(state.starting || state.switchingMeetingLanguage || state.resuming)
            KKSegmentedPicker(title: tr("字幕位置"), selection: Binding(get: { state.captionSurface }, set: { state.selectCaptionSurface($0) }), options: [(tr("灵动岛"), "island"), (tr("桌面窗口"), "window")]).controlSize(.small).labelsHidden()
            .accessibilityRepresentation { CaptionSegmentAccessibility(title: tr("字幕位置"), selection: Binding(get: { state.captionSurface }, set: { state.selectCaptionSurface($0) }), options: [(tr("灵动岛"), "island"), (tr("桌面窗口"), "window")]) }
            Toggle(tr("紧凑字幕"), isOn: $state.compactCaptions).toggleStyle(KKSwitchToggleStyle()).accessibilityLabel(tr("紧凑字幕"))
            KKSegmentedPicker(title: tr("显示内容"), selection: $state.captionDisplay, options: menuCaptionOptions).controlSize(.small).labelsHidden()
            .accessibilityRepresentation { CaptionSegmentAccessibility(title: tr("显示内容"), selection: $state.captionDisplay, options: menuCaptionOptions) }
            TextField(tr("这场会的词（回车添加到术语表）"), text: $quickTerm, prompt: Text(tr("这场会的词（回车添加到术语表）")).foregroundStyle(KKColor.textSecondary)).kkFocusRing()
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .background(MenuTermFocusRingSuppression().allowsHitTesting(false).accessibilityHidden(true))
                .accessibilityLabel(tr("这场会的词（回车添加到术语表）"))
                .onSubmit { state.addGlossaryTerm(quickTerm); quickTerm = "" }

            Divider()

            AccessibleMenuCommand(CaptionPanelController.shared.hasVisibleCaptions ? tr("隐藏字幕窗") : tr("显示字幕窗"), activatesApp: false, dismissesMenu: false) { CaptionPanelController.shared.toggleVisible(mode: state.effectiveMode) }
            AccessibleMenuCommand(tr("回看本场字幕")) { CaptionReviewController.shared.show() }
            AccessibleMenuCommand(tr("重置字幕位置"), activatesApp: false) { CaptionPanelController.shared.show(); CaptionPanelController.shared.resetPlacement(mode: state.effectiveMode) }
            AccessibleMenuCommand(tr("打开记录文件夹"), activatesApp: false) {
                try? FileManager.default.createDirectory(at: CaptionState.transcriptDir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(CaptionState.transcriptDir)
            }

            Divider()

            AccessibleMenuCommand(tr("打开 Kikishima")) { AppDelegate.enter() }
            AccessibleMenuCommand(tr("设置…")) { AppDelegate.enter(section: .settings) }
            AccessibleMenuCommand(tr("检查更新…")) { UpdaterController.shared.checkForUpdates() }
            AccessibleMenuCommand(tr("退出"), activatesApp: false) {
                state.stop()
                NSApplication.shared.terminate(nil)
            }
        }
        .foregroundStyle(KKColor.textPrimary)
        .background(KKColor.surfaceBase)
        .buttonStyle(KKQuietButtonStyle())
        .kkNeutralControls()
        .background(KKMenuKeyboardAccess(presented: menuKeyboardPresented).allowsHitTesting(false).accessibilityHidden(true))
        .focusScope(menuFocusScope)
        .defaultFocus($primaryFocused, true)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard isPresented, let window = notification.object as? NSWindow,
                  window.accessibilityIdentifier() == "kk-menu-panel" else { return }
            // KKMenuKeyboardAccess activates asynchronously. Reset AFTER AppKit restores
            // the previous first responder, even when primaryFocused was already true.
            resetFocus(in: menuFocusScope)
        }
        .onChange(of: isPresented) { _, presented in
            primaryFocused = presented
            if presented { refreshDevices(); resetFocus(in: menuFocusScope) }
        }
        .onExitCommand {
            // Complete the native close before restoring focus. A binding-only
            // close can otherwise choose main after our restoration has run.
            if let panel = NSApp.keyWindow, panel.accessibilityIdentifier() == "kk-menu-panel" {
                panel.orderOut(nil)
            }
            isPresented = false
            DispatchQueue.main.async { AppDelegate.restoreMenuStatusFocus() }
        }
        .onAppear {
            refreshDevices()
#if SHOOT || DEBUG
            if ProcessInfo.processInfo.environment["KIKISHIMA_SHOOT_RENDER"] != nil { return }
#endif
            primaryFocused = true; state.prewarm(); state.refreshPlan()
        }   // 点开菜单即预热 + 刷新档位 + 读设备，点「开始」时连接已就绪
    }
}

/// Native Button semantics, including keyboard activation, inside the menu panel.
private struct AccessibleMenuCommand: View {
    let title: String
    var activatesApp = true
    var dismissesMenu = true
    var action: () -> Void
    init(_ title: String, activatesApp: Bool = true, dismissesMenu: Bool = true,
         action: @escaping () -> Void) {
        self.title = title
        self.activatesApp = activatesApp
        self.dismissesMenu = dismissesMenu
        self.action = action
    }
    var body: some View {
        Button {
            if dismissesMenu { AppDelegate.dismissMenuBarPopup() }
            if activatesApp { NSApp.activate(ignoringOtherApps: true) }
            action()
        } label: {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
    }
}

/// Suppress only this field's native ring; kkFocusRing retains the app's orange ring.
private struct MenuTermFocusRingSuppression: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.suppressRing() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); suppressRing() }
        override func layout() { super.layout(); suppressRing() }
        func suppressRing() {
            guard window != nil, !bounds.isEmpty else { return }
            let target = convert(bounds, to: nil)
            func find(_ view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.isEditable,
                   field.convert(field.bounds, to: nil).intersects(target) { return field }
                return view.subviews.lazy.compactMap(find).first
            }
            var ancestor = superview
            while let container = ancestor {
                if let field = find(container) { field.focusRingType = .none; return }
                ancestor = container.superview
            }
        }
    }
}
