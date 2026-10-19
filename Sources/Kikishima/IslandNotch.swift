// 字幕岛：有刘海时从刘海长出；无刘海时同样内容的黑色胶囊位于屏顶下 8pt。
// 引擎开关 islandEngine = panel 使用 NSPanel 承载同样的岛内容。
import SwiftUI
import AppKit
import DynamicNotchKit
import Pow
import Observation

/// The actual host display is shared by the SwiftUI content and NSPanel policy.
@MainActor @Observable
final class IslandDisplayContext {
    var visibleFrame: CGRect = .zero
    var notchWidth: CGFloat = 0
    var hostSideInset: CGFloat = 15
}

@MainActor
final class IslandNotchController {
    static let shared = IslandNotchController()
    static var enabled: Bool {
#if SHOOT || DEBUG
        // Use the existing real NSPanel island path; NotchKit forces a dark environment.
        if ShootSimulation.requestedMode != nil { return false }
#endif
        return (UserDefaults.standard.string(forKey: "islandEngine") ?? "notchkit") != "panel"
    }

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
        n.fallbackScreen = { [weak self] in self?.screen() }
        n.transitionConfiguration.skipIntermediateHides = true
        // 设计合同：spring 0.48 / 0.86 展开；收起更快
        n.transitionConfiguration.openingAnimation = .spring(response: 0.48, dampingFraction: 0.86)
        n.transitionConfiguration.closingAnimation = .spring(response: 0.32, dampingFraction: 0.9)
        n.transitionConfiguration.conversionAnimation = .spring(response: 0.42, dampingFraction: 0.86)
        return n
    }

    private func screen() -> NSScreen? { CaptionIslandScreen.selected() }

    private func screenID(_ screen: NSScreen?) -> Int? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue
    }

    func show() {
        visible = true
        sync(force: true)
    }

    // MARK: 自动收回：无人说话 N 秒 → 胶囊；新句 / 横幅 / 暂停 → 立刻长回来
    private var dormancyTask: Task<Void, Never>?
    private var surfaceVisible: Bool {
        visible || (!Self.enabled && CaptionState.shared.usesIslandCaptions
            && CaptionPanelController.shared.isVisible)
    }
    func noteActivity() {
        let s = CaptionState.shared
        if s.islandDormant { s.islandDormant = false }
        dormancyTask?.cancel()
        let secs = s.islandAutoCollapseSeconds
        guard secs > 0, surfaceVisible, !s.islandSettingsOpen else { return }
        dormancyTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(secs))
            guard !Task.isCancelled, self.surfaceVisible, !CaptionState.shared.islandSettingsOpen else { return }
            CaptionState.shared.islandDormant = true
            self.sync()
        }
    }

    /// 字号 / 宽度 / 高度分档变化：只改窗口大小，不要重新 expand（那会闪）。
    func resizeToContent() {
        guard visible else { return }
        resizeGen += 1
        let gen = resizeGen
        guard let scr = notch?.windowController?.window?.screen ?? screen() else {
            applyWindowPolicy()
            return
        }
        let newContent = expanded ? IslandExpandedView.expandedSize(in: scr.frame) : IslandExpandedView.idleSize(notchWidth: display.notchWidth)
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
        guard let scr = screen() else { return }
        if notch == nil {
            display.visibleFrame = scr.frame
            display.notchWidth = scr.auxiliaryTopLeftArea.flatMap { left in scr.auxiliaryTopRightArea.map { right in CaptionIslandLayout.notchWidth(auxiliaryTopLeft: left, auxiliaryTopRight: right) } } ?? 0
            notch = make()
        }
        guard let n = notch else { return }
        let want = CaptionState.shared.wantsIslandExpanded
        let wasShown = shown
        let migrate = CaptionScreenPolicy.shouldMigrate(shown: wasShown,
            currentScreenID: screenID(n.windowController?.window?.screen), selectedScreenID: screenID(scr),
            force: force, expansionChanged: want != expanded)
        guard migrate else { return }
        let growing = want && !expanded
        expanded = want
        CaptionState.shared.islandExpanded = want
        // 长大：先把窗口撑到目标大小再让内容动，否则动画前半段被窄窗口裁掉
        if growing, wasShown { applyWindowPolicy() }
        Task { @MainActor in
            guard self.visible else { return }
            self.shown = true
            await n.expand(on: scr)
            try? await Task.sleep(for: .milliseconds(560))   // 收小：等动画走完再收窄窗口
            self.applyWindowPolicy()
        }
    }
    private var shown = false

    /// 和旧岛一致的窗口策略：默认不进屏幕共享；全屏会议上方可见；点击穿透。
    /// NotchKit 的面板默认是半屏宽 × 半屏高的透明窗，会挡住菜单栏弹窗的点击，因此收窄到内容大小
    func applyWindowPolicy() {
        guard let w = notch?.windowController?.window, let scr = w.screen ?? screen() else { return }
        applyWindowPolicy(to: w, on: scr)
    }

    private func applyWindowPolicy(to w: NSWindow, on scr: NSScreen) {
        display.visibleFrame = scr.frame
        display.notchWidth = scr.auxiliaryTopLeftArea.flatMap { left in scr.auxiliaryTopRightArea.map { right in CaptionIslandLayout.notchWidth(auxiliaryTopLeft: left, auxiliaryTopRight: right) } } ?? 0
        let s = CaptionState.shared
        w.sharingType = s.captionsVisibleInScreenShare ? .readOnly : .none
        w.collectionBehavior.insert(.fullScreenAuxiliary)
        w.appearance = nil   // 岛永远墨色，不跟系统浅色
        w.acceptsMouseMovedEvents = true
        w.ignoresMouseEvents = !expanded   // 只有无操作的胶囊穿透；展开后必须能操作工具条
        let content = expanded ? IslandExpandedView.expandedSize(in: scr.frame) : IslandExpandedView.idleSize(notchWidth: display.notchWidth)
        lastContentSize = content
        let notchH = scr.frame.maxY - scr.visibleFrame.maxY   // 菜单栏 / 刘海高度
        // 两种屏幕都保持刘海内容；无刘海胶囊顶边距屏顶 8pt。
        let notchless = !CaptionIslandScreen.hasNotch(scr)
        display.hostSideInset = notchless ? 15 : 30
        w.level = .statusBar
        let size = notchless
            ? NSSize(width: content.width + 30, height: content.height + 8 + 15)   // 与 NotchlessView 的内边距一致，不留透明边去挡菜单栏
            : NSSize(width: content.width + 30, height: content.height + notchH + 15)
        let frame = notchless
            ? CaptionScreenPolicy.floatingFrame(screenFrame: scr.frame, size: size)
            : NSRect(x: scr.frame.midX - size.width / 2, y: scr.frame.maxY - size.height, width: size.width, height: size.height)
        if w.frame != frame { w.setFrame(frame, display: true) }
    }
}

// MARK: - 内容

/// 展开态：复用字幕视图，宽度 / 高度按分档
struct IslandExpandedView: View {
    @Bindable var state: CaptionState
    @Bindable var display: IslandDisplayContext
    static func idleSize(notchWidth: CGFloat) -> CGSize {
        CGSize(width: CaptionIslandLayout.compactWidth(notchWidth: notchWidth) - 30, height: 12) // + host 30 = notch + 2 × 120pt
    }
    static func expandedSize(in visibleFrame: CGRect) -> CGSize {
        CaptionIslandLayout.notchContentSize(visibleFrame: visibleFrame,
            widthFraction: CaptionState.shared.captionWidthFraction,
            height: IslandExpandedView.contentHeight)
    }
    static var contentHeight: CGFloat {
        let state = CaptionState.shared
        let hasPending = !state.pendingEn.isEmpty || !state.pendingDraft.isEmpty
        let limit = CaptionHierarchy.historyLimit(userSize: state.zhFontSize, showTranslation: state.showTranslation, showSource: state.showSource, banner: state.errorBanner != nil || state.paused)
        let count = min(limit + 1, state.visibleCaptionChunks.filter { !$0.isMarker }.count + (hasPending ? 1 : 0))
        let scale = state.zhFontSize / 18
        let current = (state.showTranslation ? 48.0 : 0) + (state.showSource ? 22.0 : 0)
        let history = Double(max(0, count - 1)) * CaptionHierarchy.historyLineHeight(showTranslation: state.showTranslation, showSource: state.showSource)
        let banners = (state.errorBanner != nil || state.paused) ? 40.0 : 0
        return min(153, max(64, (current + history) * scale + Double(max(0, count - 1)) * 4 + 16 + banners))
    }
    var body: some View {
        let baseSize = state.wantsIslandExpanded ? Self.expandedSize(in: display.visibleFrame) : Self.idleSize(notchWidth: display.notchWidth)
        let size = CGSize(width: baseSize.width + 30 - display.hostSideInset * 2, height: baseSize.height)
        ZStack {
            if state.wantsIslandExpanded {
                CaptionFeedView(state: state, hostedInNotch: true, hostSideInset: display.hostSideInset)
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
        .onChange(of: size) { CaptionPanelController.shared.resizeIslandToContent() }
        .onChange(of: state.wantsIslandExpanded) {
            IslandNotchController.shared.sync()
            CaptionPanelController.shared.syncIslandReveal()
        }
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
        HStack(spacing: 6) {
            Circle()
                .fill(state.silentTooLong ? KKColor.warning : state.running && !state.paused ? KKColor.brand : KKColor.textTertiary)
                .frame(width: 7, height: 7)
                .changeEffect(.glow(color: KKColor.brand, radius: 8), value: state.running)
            if state.silentTooLong {
                Text(tr("没听到声音")).font(.system(size: 11))
                    .foregroundStyle(KKColor.warning)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.running ? CaptionListeningStatus.text(silentTooLong: state.silentTooLong, audioStalled: state.audioStalled) : tr("字幕"))
    }
}

/// 胶囊右：三根电平
struct IslandCompactTrailing: View {
    @Bindable var state: CaptionState
    var body: some View {
        let lv = state.running ? state.audioLevel : 0
        HStack(spacing: 3) {
            Capsule().fill((state.silentTooLong ? KKColor.warning : KKColor.historyInk).opacity(max(138.0 / 255.0, 0.35 + lv * 0.55))).frame(width: 3, height: 5 + lv * 7)
            Capsule().fill((state.silentTooLong ? KKColor.warning : KKColor.historyInk).opacity(max(138.0 / 255.0, 0.28 + lv * 0.5))).frame(width: 3, height: 4 + lv * 10)
            Capsule().fill((state.silentTooLong ? KKColor.warning : KKColor.historyInk).opacity(max(138.0 / 255.0, 0.35 + lv * 0.55))).frame(width: 3, height: 5 + lv * 7)
        }
        .frame(height: 14)
        .animation(.linear(duration: 0.08), value: lv)
    }
}
