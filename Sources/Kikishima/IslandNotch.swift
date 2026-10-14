// 字幕岛（DynamicNotchKit 引擎）：有刘海时从刘海长出。无刘海时墨色面板贴住屏幕最上沿，不跟系统浅色。
// 开关：UserDefaults "islandEngine" = "panel" 回落到 CaptionPanelController 自己的 NSPanel 岛（0.36 行为）。
import SwiftUI
import AppKit
import DynamicNotchKit
import Pow
import Observation

/// The actual host display is shared by the SwiftUI content and NSPanel policy.
@MainActor @Observable
final class IslandDisplayContext {
    var visibleFrame: CGRect = .zero
}

@MainActor
final class IslandNotchController {
    static let shared = IslandNotchController()
    static var enabled: Bool { (UserDefaults.standard.string(forKey: "islandEngine") ?? "notchkit") != "panel" }

    private var notch: DynamicNotch<IslandExpandedView, IslandCompactLeading, IslandCompactTrailing>?
    private let display = IslandDisplayContext()
    private(set) var visible = false
    private(set) var expanded = false

    private func make() -> DynamicNotch<IslandExpandedView, IslandCompactLeading, IslandCompactTrailing> {
        let s = CaptionState.shared
        let n = DynamicNotch(
            // Explicit stop/hide must work even while the pointer is on the toolbar.
            hoverBehavior: [],
            style: .auto,
            expanded: { IslandExpandedView(state: s, display: self.display) },
            compactLeading: { IslandCompactLeading(state: s) },
            compactTrailing: { IslandCompactTrailing(state: s) }
        )
        n.configureWindow = { [weak self] window, screen in
            self?.applyWindowPolicy(to: window, on: screen)
        }
        n.transitionConfiguration.skipIntermediateHides = true
        // 设计合同：spring 0.48 / 0.86 展开；收起更快
        n.transitionConfiguration.openingAnimation = .spring(response: 0.48, dampingFraction: 0.86)
        n.transitionConfiguration.closingAnimation = .spring(response: 0.32, dampingFraction: 0.9)
        n.transitionConfiguration.conversionAnimation = .spring(response: 0.42, dampingFraction: 0.86)
        return n
    }

    /// 会议窗口所在屏；找不到就主屏
    private func screen() -> NSScreen {
        let source = AudioSourceWindow.frontWindowFrame(for: CaptionState.micUsers())
        return source.flatMap { s in NSScreen.screens.first { $0.frame.contains(NSPoint(x: s.midX, y: s.midY)) } }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func show() {
        visible = true
        sync(force: true)
    }

    // MARK: 自动收回：无人说话 N 秒 → 胶囊；新句 / 横幅 / 暂停 → 立刻长回来
    private var dormancyTask: Task<Void, Never>?
    func noteActivity() {
        let s = CaptionState.shared
        if s.islandDormant { s.islandDormant = false }
        dormancyTask?.cancel()
        let secs = s.islandAutoCollapseSeconds
        guard secs > 0, visible, !s.islandSettingsOpen else { return }
        dormancyTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(secs))
            guard !Task.isCancelled, self.visible, !CaptionState.shared.islandSettingsOpen else { return }
            CaptionState.shared.islandDormant = true
            self.sync()
        }
    }

    /// 字号 / 宽度 / 高度分档变化：只改窗口大小，不要重新 expand（那会闪）。
    func resizeToContent() {
        guard visible else { return }
        resizeGen += 1
        let gen = resizeGen
        guard let scr = notch?.windowController?.window?.screen ?? NSScreen.main else {
            applyWindowPolicy()
            return
        }
        let newContent = expanded ? IslandExpandedView.expandedSize(in: scr.visibleFrame) : IslandExpandedView.idleSize
        let growing = newContent.width > lastContentSize.width + 2 || newContent.height > lastContentSize.height + 2
        lastContentSize = newContent
        if growing {
            applyWindowPolicy()
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(380))
            guard gen == self.resizeGen else { return }
            self.applyWindowPolicy()
        }
    }
    private var resizeGen = 0
    private var lastContentSize = CGSize.zero

    func hide() {
        guard visible else { return }
        visible = false
        dormancyTask?.cancel()
        dormancyTask = nil
        resizeGen += 1
        CaptionState.shared.islandSettingsOpen = false
        shown = false
        expanded = false
        CaptionState.shared.islandExpanded = false
        let n = notch
        Task { @MainActor in await n?.hide() }
    }

    /// 岛永远处于 NotchKit 的 expanded 态：没内容时画小胶囊，有内容时长成字幕面板。
    /// 不用 NotchKit 的 compact，避免内容被限制在刘海两侧、菜单栏高度的小图标区域
    func sync(force: Bool = false) {
        guard visible else { return }
        let scr = screen()
        if notch == nil {
            display.visibleFrame = scr.visibleFrame
            notch = make()
        }
        guard let n = notch else { return }
        let want = CaptionState.shared.wantsIslandExpanded
        let wasShown = shown
        guard force || want != expanded || !wasShown else { return }
        let growing = want && !expanded
        expanded = want
        CaptionState.shared.islandExpanded = want
        // 长大：先把窗口撑到目标大小再让内容动，否则动画前半段被窄窗口裁掉
        if growing, wasShown { applyWindowPolicy() }
        Task { @MainActor in
            if !wasShown { self.shown = true; await n.expand(on: scr) }
            try? await Task.sleep(for: .milliseconds(560))   // 收小：等动画走完再收窄窗口
            self.applyWindowPolicy()
        }
    }
    private var shown = false

    /// 和旧岛一致的窗口策略：默认不进屏幕共享；全屏会议上方可见；点击穿透。
    /// NotchKit 的面板默认是半屏宽 × 半屏高的透明窗，会挡住菜单栏弹窗的点击，因此收窄到内容大小
    func applyWindowPolicy() {
        guard let w = notch?.windowController?.window, let scr = w.screen ?? NSScreen.main else { return }
        applyWindowPolicy(to: w, on: scr)
    }

    private func applyWindowPolicy(to w: NSWindow, on scr: NSScreen) {
        display.visibleFrame = scr.visibleFrame
        let s = CaptionState.shared
        w.sharingType = s.captionsVisibleInScreenShare ? .readOnly : .none
        w.collectionBehavior.insert(.fullScreenAuxiliary)
        w.appearance = NSAppearance(named: .darkAqua)   // 岛永远墨色，不跟系统浅色
        w.acceptsMouseMovedEvents = true
        w.ignoresMouseEvents = !expanded   // 只有无操作的胶囊穿透；展开后必须能操作工具条
        let content = expanded ? IslandExpandedView.expandedSize(in: scr.visibleFrame) : IslandExpandedView.idleSize
        lastContentSize = content
        let notchH = scr.frame.maxY - scr.visibleFrame.maxY   // 菜单栏 / 刘海高度
        // 无刘海：窗口必须高于菜单栏，墨色才能画到屏幕最上沿。有刘海仍用 floating，从刘海长出。
        let notchless = scr.auxiliaryTopLeftArea == nil || scr.auxiliaryTopRightArea == nil
        w.level = notchless ? .statusBar : .floating
        let size = notchless
            ? NSSize(width: content.width + 30, height: content.height + 8 + 15)   // 与 NotchlessView 的内边距一致，不留透明边去挡菜单栏
            : NSSize(width: content.width + 80, height: content.height + notchH + 40)
        let frame = NSRect(x: scr.frame.midX - size.width / 2, y: scr.frame.maxY - size.height, width: size.width, height: size.height)
        if w.frame != frame { w.setFrame(frame, display: true) }
    }
}

// MARK: - 内容

/// 展开态：复用字幕视图，宽度 / 高度按分档
struct IslandExpandedView: View {
    @Bindable var state: CaptionState
    @Bindable var display: IslandDisplayContext
    static let idleSize = CGSize(width: 150, height: 12)
    static func expandedSize(in visibleFrame: CGRect) -> CGSize {
        CaptionIslandLayout.notchContentSize(visibleFrame: visibleFrame,
            widthFraction: CaptionState.shared.captionWidthFraction,
            height: CaptionState.shared.islandHeight)
    }
    var body: some View {
        let size = state.wantsIslandExpanded ? Self.expandedSize(in: display.visibleFrame) : Self.idleSize
        ZStack {
            if state.wantsIslandExpanded {
                CaptionFeedView(state: state, hostedInNotch: true)
                    .transition(.movingParts.blur.combined(with: .opacity))
            } else {
                // 胶囊：左朱红点、右电平，中间留白——就是设计稿 S1
                HStack(spacing: 10) {
                    IslandCompactLeading(state: state)
                    Spacer(minLength: 0)
                    IslandCompactTrailing(state: state)
                }
                .padding(.horizontal, 14)
                .transition(.movingParts.blur.combined(with: .opacity))
            }
        }
        .frame(width: size.width, height: size.height)
        .padding(.bottom, state.wantsIslandExpanded ? 0 : -9)   // 胶囊态：吃掉 NotchKit 写死的 15pt 底边留白的一部分
        .animation(.spring(response: 0.48, dampingFraction: 0.86), value: state.wantsIslandExpanded)
        .animation(.spring(response: 0.36, dampingFraction: 0.9), value: size)
        .onChange(of: state.wantsIslandExpanded) { IslandNotchController.shared.sync() }
        .onChange(of: state.chunks.last?.zh) { IslandNotchController.shared.noteActivity() }
        .onChange(of: state.pendingEn) { IslandNotchController.shared.noteActivity() }
        .onChange(of: state.pendingDraft) { IslandNotchController.shared.noteActivity() }
        .onChange(of: state.errorBanner?.text) { IslandNotchController.shared.noteActivity() }
        .onChange(of: state.paused) { IslandNotchController.shared.noteActivity() }
        .onAppear { IslandNotchController.shared.noteActivity() }
    }
}

/// 胶囊左：朱红 live dot（运行中），灰点（启动中 / 未运行）
struct IslandCompactLeading: View {
    @Bindable var state: CaptionState
    var body: some View {
        Circle()
            .fill(state.running && !state.paused ? Color(red: 1.0, green: 0.23, blue: 0.12) : Color.white.opacity(0.35))
            .frame(width: 7, height: 7)
            .changeEffect(.glow(color: Color(red: 1.0, green: 0.23, blue: 0.12), radius: 8), value: state.running)
            .accessibilityLabel(state.running ? tr("正在听…") : tr("字幕"))
    }
}

/// 胶囊右：三根电平
struct IslandCompactTrailing: View {
    @Bindable var state: CaptionState
    var body: some View {
        let lv = state.running ? state.audioLevel : 0
        HStack(spacing: 3) {
            Capsule().fill(Color.white.opacity(0.35 + lv * 0.55)).frame(width: 3, height: 5 + lv * 7)
            Capsule().fill(Color.white.opacity(0.28 + lv * 0.5)).frame(width: 3, height: 4 + lv * 10)
            Capsule().fill(Color.white.opacity(0.35 + lv * 0.55)).frame(width: 3, height: 5 + lv * 7)
        }
        .frame(height: 14)
        .animation(.linear(duration: 0.08), value: lv)
    }
}
