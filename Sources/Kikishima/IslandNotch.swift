// 字幕岛：有刘海时从刘海长出；无刘海时同样内容的黑色胶囊位于菜单栏下沿下 8pt。
// 引擎开关 islandEngine = panel 使用 NSPanel 承载同样的岛内容。
import SwiftUI
import AppKit
import DynamicNotchKit
import Pow
import Observation
import QuartzCore

/// The actual host display is shared by the SwiftUI content and NSPanel policy.
@MainActor @Observable
final class IslandDisplayContext {
    var visibleFrame: CGRect = .zero
    var notchWidth: CGFloat = 0
    var toolbarNotchHeight: CGFloat = 0
    var hostSideInset: CGFloat = 15
    var measuredHeight: CGFloat = 64
    var reduceMotion = false
    private var pendingHeight: CGFloat?
    private var measurementScheduled = false

    /// Coalesce layout preferences before publishing an integer height. The
    /// measurement is intrinsic and never depends on the clamped viewport.
    func measure(_ height: CGFloat) {
        pendingHeight = ceil(height)
        guard !measurementScheduled else { return }
        measurementScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measurementScheduled = false
            guard let height = self.pendingHeight else { return }
            self.pendingHeight = nil
            if abs(height - self.measuredHeight) >= 1 { self.measuredHeight = height }
        }
    }
}

/// Content shift: 200ms (0.2,0,0,1); Reduce Motion swaps without movement.
@MainActor
enum IslandContentShift {
    static func setFrame(_ frame: NSRect, on window: NSWindow, reduceMotion: Bool) {
#if SHOOT || DEBUG
        ShootWindowLog.request(window, to: frame, caller: "content-shift", animate: !reduceMotion)
#endif
        guard window.frame != frame else { return }
        if reduceMotion {
            window.setFrame(frame, display: true)
            window.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                window.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
                window.animator().setFrame(frame, display: true)
            }
        }
    }
}

@MainActor
final class IslandNotchController {
    static let shared = IslandNotchController()
    static var enabled: Bool {
#if SHOOT
        if ShootNotch.configuration != nil { return true }
#endif
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
        guard secs > 0 else { return }
        dormancyTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(secs))
            guard !Task.isCancelled, self.surfaceVisible else { return }
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
        let content = expanded
            ? IslandExpandedView.expandedSize(in: scr.frame, measured: display.measuredHeight)
            : IslandExpandedView.idleSize(notchWidth: display.notchWidth)
        let previous = lastContentSize
        lastContentSize = content
        if content.width == previous.width {
            applyWindowPolicy(animateContent: true)
        } else if content.width > previous.width + 2 {
            applyWindowPolicy()
        } else {
            // Preserve the existing width-shrink timing; only content height
            // changes use caption.shift.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(380))
                guard gen == self.resizeGen else { return }
                self.applyWindowPolicy()
            }
        }
    }
    private var resizeGen = 0
    private var lastContentSize = CGSize.zero

    func hide() {
#if SHOOT
        ShootNotch.hide()
#endif
        guard visible else { return }
        visible = false
        dormancyTask?.cancel()
        dormancyTask = nil
        resizeGen += 1
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
#if SHOOT
            if let size = ShootNotch.size(on: scr) { display.notchWidth = size.width }
#endif
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
    func applyWindowPolicy(animateContent: Bool = false) {
        guard let w = notch?.windowController?.window, let scr = w.screen ?? screen() else { return }
        applyWindowPolicy(to: w, on: scr, animateContent: animateContent)
    }

    private func applyWindowPolicy(to w: NSWindow, on scr: NSScreen, animateContent: Bool = false) {
        display.visibleFrame = scr.frame
        display.notchWidth = scr.auxiliaryTopLeftArea.flatMap { left in scr.auxiliaryTopRightArea.map { right in CaptionIslandLayout.notchWidth(auxiliaryTopLeft: left, auxiliaryTopRight: right) } } ?? 0
#if SHOOT
        if let size = ShootNotch.size(on: scr) { display.notchWidth = size.width }
#endif
        let s = CaptionState.shared
        w.sharingType = s.captionsVisibleInScreenShare ? .readOnly : .none
        w.collectionBehavior.insert(.fullScreenAuxiliary)
        w.appearance = NSAppearance(named: .darkAqua)   // 岛永远墨色，不跟系统浅色
        w.acceptsMouseMovedEvents = true
        w.ignoresMouseEvents = !expanded   // 只有无操作的胶囊穿透；展开后必须能操作工具条
        let content = expanded ? IslandExpandedView.expandedSize(in: scr.frame, measured: display.measuredHeight) : IslandExpandedView.idleSize(notchWidth: display.notchWidth)
        lastContentSize = content
        var notchH = scr.frame.maxY - scr.visibleFrame.maxY   // 菜单栏 / 刘海高度
#if SHOOT
        if let height = ShootNotch.menuBarHeight(on: scr) { notchH = height }
#endif
        // 两种屏幕都保持刘海内容；无刘海胶囊顶边距菜单栏下沿 8pt。
        let notchless = !CaptionIslandScreen.hasNotch(scr)
        display.hostSideInset = notchless ? 15 : 30
        // Match NotchView's existing top safe-area inset, not the caption cap.
        display.toolbarNotchHeight = notchless ? 0 : scr.safeAreaInsets.top
#if SHOOT
        if let size = ShootNotch.size(on: scr) { display.toolbarNotchHeight = size.height }
#endif
        w.level = .statusBar
#if SHOOT
        ShootNotch.show(on: scr, sharingType: w.sharingType, above: w.level)
#endif
        let size = notchless
            ? NSSize(width: content.width + 30, height: CaptionIslandToolbarLayout.floatingWindowHeight(contentHeight: content.height, expanded: expanded))   // 与 NotchlessView 的内边距一致，不留透明边去挡菜单栏
            : NSSize(width: content.width + 30, height: content.height + notchH + 15)
        let frame = notchless
            ? CaptionScreenPolicy.floatingFrame(screenFrame: scr.frame, visibleFrame: scr.visibleFrame, size: size)
            : CaptionIslandLayout.notchedWindowFrame(screenFrame: scr.frame, notchHeight: notchH, contentSize: content)
        if animateContent {
            IslandContentShift.setFrame(frame, on: w, reduceMotion: display.reduceMotion)
        } else if w.frame != frame {
#if SHOOT || DEBUG
            ShootWindowLog.request(w, to: frame, caller: "place", animate: false)
#endif
            w.setFrame(frame, display: true)
        }
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
    static func expandedSize(in visibleFrame: CGRect, measured: CGFloat) -> CGSize {
        // Both hosts pass screen.frame. Resolve visible dimensions here
        // so the panel and NotchKit use the same geometry.
        let screen = NSScreen.screens.first { $0.frame == visibleFrame }
        var bounds = visibleFrame
        bounds.size.width = screen?.visibleFrame.width ?? visibleFrame.width
        bounds.size.height = screen?.visibleFrame.height ?? visibleFrame.height
        var size = CaptionIslandLayout.notchContentSize(visibleFrame: bounds,
            widthLevel: CaptionAppearance.parseSize(CaptionState.shared.captionWidthLevel) ?? .medium,
            heightLevel: IslandExpandedView.contentHeight)
        size.height = CaptionIslandLayout.islandContentHeight(measured: measured,
            visibleHeight: bounds.height, heightLevel: contentHeight)
        return size
    }
    static var contentHeight: CaptionSizeLevel {
        // Intrinsic column height is clamped to 64pt and the screen-aware cap.
        // The selected tier remains the scrolling ceiling, not a fixed viewport.
        CaptionAppearance.parseSize(CaptionState.shared.islandHeightLevel) ?? .medium
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let baseSize = state.wantsIslandExpanded ? Self.expandedSize(in: display.visibleFrame, measured: display.measuredHeight) : Self.idleSize(notchWidth: display.notchWidth)
        let size = CGSize(width: baseSize.width + 30 - display.hostSideInset * 2, height: baseSize.height + (state.wantsIslandExpanded ? CaptionIslandToolbarLayout.extraHeight(notchHeight: display.toolbarNotchHeight) : 0))
        ZStack {
            if state.wantsIslandExpanded {
                CaptionFeedView(state: state, hostedInNotch: true, hostSideInset: display.hostSideInset,
                                toolbarNotchWidth: display.notchWidth, toolbarNotchHeight: display.toolbarNotchHeight)
                    .islandLayout(width: baseSize.width + 30,
                        heightCap: CaptionIslandLayout.expandedContentHeight(
                            visibleHeight: NSScreen.screens.first { $0.frame == display.visibleFrame }?.visibleFrame.height ?? display.visibleFrame.height,
                            heightLevel: Self.contentHeight),
                        onHeight: { display.measure($0) })
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
        .environment(\.colorScheme, .dark)
        .frame(width: size.width, height: size.height)
        .padding(.bottom, state.wantsIslandExpanded ? 0 : -9)   // 胶囊态：吃掉 NotchKit 写死的 15pt 底边留白的一部分
        .animation(.spring(response: 0.48, dampingFraction: 0.86), value: state.wantsIslandExpanded)
        .animation(.spring(response: 0.36, dampingFraction: 0.9), value: size.width)
        .animation(reduceMotion ? nil : .timingCurve(0.2, 0, 0, 1, duration: 0.2), value: size.height)
        .onChange(of: reduceMotion, initial: true) { display.reduceMotion = reduceMotion }
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
                .fill(state.captionDisplayStatus == .error ? KKColor.error : state.captionDisplayStatus.isWarning ? KKColor.warning : state.captionDisplayStatus == .listening ? KKColor.brand : KKColor.textTertiary)
                .frame(width: 7, height: 7)
                .changeEffect(.glow(color: KKColor.brand, radius: 8), value: state.running)
            if state.captionDisplayStatus.showsLabel {
                Text(state.captionStatusShortText).font(.system(size: 11))
                    .fixedSize(horizontal: true, vertical: false)
                    .help(state.captionStatusText).accessibilityLabel(state.captionStatusText)
                    .foregroundStyle(state.captionDisplayStatus == .error ? KKColor.error : KKColor.warning)
            }
            if let action = state.captionStatusBanner?.action {
                Button(tr(action.title)) { state.performBanner(action) }
                    .buttonStyle(KKQuietButtonStyle()).controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.captionDisplayStatus == .idle ? tr("字幕") : state.captionStatusText)
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
