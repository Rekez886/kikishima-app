// Kikishima — 菜单栏 app + 悬浮字幕窗
import SwiftUI
import AppKit
import MacControlCenterUI
import MenuBarExtraAccess
import Pow

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
        guard !launchShown else { return }
        launchShown = true
        if showMainOnLaunch && !OnboardingController.needed { enter() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.apply()
        _ = UpdaterController.shared            // 起 Sparkle 后台检查
        CaptionState.shared.probeProviders()    // 服务器开了哪些第三方登录
        // 兜底：状态栏图标的 onAppear 迟迟不来（极少）也别让用户对着一片静默
        Task { @MainActor in try? await Task.sleep(for: .seconds(2)); Self.hostReady() }
    }
    /// 回到前台：刷一次档位（付款回来 / 别处改了订阅），30 秒节流
    func applicationDidBecomeActive(_ notification: Notification) {
        CaptionState.shared.refreshPlanIfStale(seconds: 30)
    }
    /// 网页版 Apple 登录回跳：kikishima://signed-in?code=…&state=…（或 ?error=…）
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "kikishima" {
            CaptionState.shared.handleAuthCallback(url)
            Self.enter()
        }
    }
    /// ⌘Q / Dock 退出 / 注销：先停字幕把记录写完
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let s = CaptionState.shared
        if s.running || s.starting { s.stop() }
        if s.hasPendingMeetingFinalization, !waitingForTermination {
            waitingForTermination = true
            Task { @MainActor in
                await s.waitForPendingMeetingFinalization()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
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
        switch menuStatus {
        case .idle: tr("已停止")
        case .starting: tr("启动中…")
        case .running: tr("正在听…")
        case .paused: tr("已暂停")
        case .translationPaused: tr("翻译已暂停")
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state, isPresented: $menuPresented)
        } label: {
            Image(nsImage: BrandIcons.menuImage(menuStatus))
                .renderingMode(.template)
                .accessibilityLabel(tr("Kikishima 字幕") + " · " + menuStatusLabel)
                .help(tr("Kikishima 字幕") + " · " + menuStatusLabel)
                .onAppear { AppDelegate.openMainWindow = { openWindow(id: "main") }; AppDelegate.hostReady() }   // 状态栏图标常驻，启动即注入
        }
        .menuBarExtraAccess(isPresented: $menuPresented)   // MacControlCenterMenu 需要它来收起菜单
        .menuBarExtraStyle(.window)

        // 主窗口（左侧栏式；视觉归设计轮）
        Window("Kikishima", id: "main") {
            MainWindowView()
        }
        .defaultSize(width: 960, height: 620)
        .defaultLaunchBehavior(.suppressed)   // 启动不弹，等 hostReady / 用户「打开」
    }
}

struct MenuContent: View {
    @Bindable var state: CaptionState
    @Binding var isPresented: Bool
    @State private var quickTerm = ""
    @State private var devices: [AudioDevices.Device] = []
    @State private var currentDevice = ""
    private var meetingLocaleChoices: [String] {
        var choices = state.meetingLocales
        if !choices.contains(state.localeID) { choices.insert(state.localeID, at: 0) }
        return choices
    }
    private func refreshDevices() {
        devices = AudioDevices.outputDevices()
        currentDevice = AudioDevices.defaultOutput().flatMap { AudioDevices.name(of: $0) } ?? ""
    }

    private var warning: Bool { state.silentTooLong || state.audioStalled }
    private var brandRed: Color { Color(red: 1.0, green: 0.23, blue: 0.12) }

    /// 状态块：运行中是墨色的岛回声（朱红点 + 电平 + 语言对 + 设备），空闲是 5% 灰卡
    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(state.running ? (warning ? Color.orange : brandRed) : Color.primary.opacity(0.25))
                    .frame(width: 8, height: 8)
                    .changeEffect(.glow(color: brandRed, radius: 8), value: state.running)
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { i in
                        Capsule().fill(state.running ? Color.white.opacity(warning ? 0.35 : 0.9) : Color.primary.opacity(0.25))
                            .frame(width: 3, height: i == 1 ? 11 : 7)
                    }
                }
                Text(state.running ? tr("正在听…") : "Kikishima").font(.system(size: 13, weight: .medium))
                Spacer()
            }
            Text(state.status).font(.system(size: 11))
                .foregroundStyle(state.running ? (warning ? Color.orange : Color.white.opacity(0.6)) : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if state.running {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule().fill(warning ? Color.orange : Color.green).frame(width: max(4, g.size.width * state.audioLevel))
                    }
                }
                .frame(height: 3)
                .accessibilityLabel(tr("音频电平"))
                .animation(.linear(duration: 0.08), value: state.audioLevel)
            }
            HStack(spacing: 6) {
                Text(tr("正在听：%@", currentDevice.isEmpty ? "?" : currentDevice)).font(.system(size: 11)).lineLimit(1)
                    .foregroundStyle(state.running ? Color.white.opacity(0.6) : Color.secondary)
                Spacer()
                Menu(tr("切换")) {
                    ForEach(devices) { d in
                        Button(d.name + (d.name == currentDevice ? " ✓" : "")) { AudioDevices.setDefaultOutput(d.id); refreshDevices() }
                    }
                }
                .menuStyle(.borderlessButton).controlSize(.small).fixedSize()
            }
        }
        .foregroundStyle(state.running ? Color.white : Color.primary)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(state.running ? Color(white: 0.06) : Color.primary.opacity(0.05)))
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.running)
    }

    var body: some View {
        MacControlCenterMenu(isPresented: $isPresented, width: .custom(264), activateAppOnCommandSelection: false) {
            statusBlock

            // 主操作：开始 / 停止（朱红）+ 暂停
            Button { state.toggle() } label: {
                Label(state.running || state.starting ? tr("停止字幕") : tr("开始字幕"),
                      systemImage: state.running || state.starting ? "stop.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(state.running || state.starting ? brandRed : .accentColor)
            if state.running {
                Button { state.paused ? state.resume() : state.pause() } label: {
                    Label(state.paused ? tr("继续字幕") : tr("暂停字幕"), systemImage: state.paused ? "play.circle" : "pause.circle").frame(maxWidth: .infinity)
                }
                .disabled(state.switchingMeetingLanguage || state.resuming)
            }
            HStack {
                Text(tr("快捷键：%@", GlobalHotkey.displayText)).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if state.sessionToken.isEmpty {
                    Text(tr("未登录 · 点「打开 Kikishima」登录")).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                } else if state.plan != "pro", state.plan != "dev", state.usageQuota > 0 {
                    Text(state.remainingText).font(.caption2).foregroundStyle((state.remainingMinutes ?? 99) < 5 ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                } else if state.plan == "pro" {
                    Text("Pro").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if state.audioStalled {
                Text(tr("音频输入停止了：检查输出设备是否被拔掉")).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if state.silentTooLong {
                Text(tr("20 秒没听到声音：检查会议是否在播放、输出设备是否正确")).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
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
            }
            .disabled(state.starting || state.switchingMeetingLanguage || state.resuming)
            Picker(tr("字幕位置"), selection: $state.captionSurface) {
                Text(tr("灵动岛")).tag("island")
                Text(tr("桌面窗口")).tag("window")
            }
            .pickerStyle(.segmented).controlSize(.small).labelsHidden()
            MenuToggle(tr("紧凑字幕"), isOn: $state.compactCaptions, image: Image(systemName: "rectangle.compress.vertical"))
            Picker(tr("显示内容"), selection: $state.captionDisplay) {
                Text(tr("原文 + 译文")).tag("both")
                Text(tr("仅译文")).tag("translation")
                Text(tr("仅原文")).tag("source")
            }
            .pickerStyle(.segmented).controlSize(.small).labelsHidden()
            TextField(tr("这场会的词（回车添加到术语表）"), text: $quickTerm)
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .onSubmit { state.addGlossaryTerm(quickTerm); quickTerm = "" }

            Divider()

            MenuCommand(CaptionPanelController.shared.isVisible ? tr("隐藏字幕窗") : tr("显示字幕窗"), activatesApp: false, dismissesMenu: false) { CaptionPanelController.shared.toggleVisible(mode: state.effectiveMode) }
            MenuCommand(tr("重置字幕位置"), activatesApp: false) { CaptionPanelController.shared.show(); CaptionPanelController.shared.resetPlacement(mode: state.effectiveMode) }
            MenuCommand(tr("打开记录文件夹"), activatesApp: false) {
                try? FileManager.default.createDirectory(at: CaptionState.transcriptDir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(CaptionState.transcriptDir)
            }

            Divider()

            MenuCommand(tr("打开 Kikishima")) { AppDelegate.enter() }
            MenuCommand(tr("设置…")) { AppDelegate.enter(section: .settings) }
            MenuCommand(tr("检查更新…")) { UpdaterController.shared.checkForUpdates() }
            MenuCommand(tr("退出"), activatesApp: false) {
                state.stop()
                NSApplication.shared.terminate(nil)
            }
        }
        .onAppear { state.prewarm(); state.refreshPlan(); refreshDevices() }   // 点开菜单即预热 + 刷新档位 + 读设备，点「开始」时连接已就绪
    }
}
