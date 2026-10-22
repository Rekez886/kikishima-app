// 悬浮字幕窗：置顶、不抢焦点、全空间可见；共享可见性依赖系统与捕获方式，不能保证隐藏。
import SwiftUI
import AppKit
import QuartzCore
import Translation
import Pow

/// Can accept explicit keyboard interaction without becoming the main app window.
private final class CaptionKeyboardPanel: CaptionMinimumSizePanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, isKeyWindow,
           !CaptionState.shared.usesIslandCaptions,
           CaptionState.shared.canDismissDesktopCaptionStatus {
            CaptionState.shared.dismissDesktopErrorStatus()
            return
        }
        super.sendEvent(event)
    }
}

/// The accessory adds controls only; the transparent title bar exposes the
/// window's captionWindowBackground and its user-selected opacity.
private final class CaptionTitlebarHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

/// Shared hover state for the native title-bar accessory and caption content.
@Observable
final class CaptionDesktopChrome {
    var contentHovered = false
    var toolbarHovered = false
    let titlebarHeight: CGFloat
    init(titlebarHeight: CGFloat) { self.titlebarHeight = titlebarHeight }
}

@MainActor
final class CaptionPanelController: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = CaptionPanelController()
    private var panel: NSPanel?

    /// 会议刘海走 DynamicNotchKit；关闭该引擎时仍用同款岛内容。
    private var notchEngine: Bool { usesIsland && IslandNotchController.enabled }
    var isVisible: Bool { panel?.isVisible == true || IslandNotchController.shared.visible }
    @Published private(set) var hasVisibleCaptions = false

    override private init() {
        super.init()
        // AppKit window ordering also covers review windows and asynchronous notch hosts.
        // Publish only a changed value; no timer and no view-update feedback loop.
        NotificationCenter.default.addObserver(self, selector: #selector(refreshVisibility),
            name: NSApplication.didUpdateNotification, object: nil)
    }

    @objc private func refreshVisibility() {
        let visible = isVisible || CaptionReviewController.shared.isVisible
        if hasVisibleCaptions != visible { hasVisibleCaptions = visible }
    }

    func show() {
        defer { refreshVisibility() }
        if notchEngine { IslandNotchController.shared.show(); return }
        if panel == nil { build() }
        applySharing()
        applyAppearance()
        if usesIsland {
            revealed = CaptionState.shared.wantsIslandExpanded
            CaptionState.shared.islandExpanded = revealed
            placing = true
            #if SHOOT || DEBUG
            if usesIsland { ShootWindowLog.request(panel, to: islandFrame(expanded: revealed), caller: "show", animate: false) }
#endif
            panel?.setFrame(islandFrame(expanded: revealed), display: false)
            placing = false
        }
        panel?.orderFrontRegardless()
    }

    private var builtIsland = false
    private var revealed = false
    private var usesIsland: Bool { CaptionState.shared.usesIslandCaptions }

    /// 菜单里切「灵动岛 / 桌面窗口」：收掉当前形态，运行中就立刻以新形态摆出来
    func switchSurface(showIfRunning: Bool = true, force: Bool = true) {
        defer { refreshVisibility() }
        let wasVisible = isVisible
        IslandNotchController.shared.hide()
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        guard wasVisible || (showIfRunning && CaptionState.shared.running) else { return }
        show()
        place(for: CaptionState.shared.effectiveMode, force: force)
    }

    /// 外观：会议 = 摄像头下的无边框岛；其它 = 紧凑无边框或带标题栏。形态切换需要重建面板（styleMask 热切不可靠）
    func applyAppearance() {
        if notchEngine { IslandNotchController.shared.applyWindowPolicy() }
        guard let p = panel else { return }
        let s = CaptionState.shared
        let island = usesIsland
        let wantBorderless = island || s.compactCaptions
        let isBorderless = !p.styleMask.contains(.titled)
        if island != builtIsland || wantBorderless != isBorderless {
            let frame = p.frame, visible = p.isVisible
            p.delegate = nil
            p.orderOut(nil)
            panel = nil
            build()
            placing = true
            #if SHOOT || DEBUG
            if usesIsland { ShootWindowLog.request(panel, to: frame, caller: "other", animate: false) }
#endif
            panel?.setFrame(frame, display: false)
            placing = false
            if visible { panel?.orderFrontRegardless() }
            return
        }
        p.ignoresMouseEvents = !island && s.compactCaptions && s.captionClickThrough
        p.title = tr("字幕")
        p.appearance = island ? NSAppearance(named: .darkAqua) : nil
        p.isOpaque = false
        p.backgroundColor = wantBorderless ? .clear : NSColor(KKColor.captionWindowBackground).withAlphaComponent(s.captionOpacity)
    }

    func hide() {
        defer { refreshVisibility() }
        CaptionReviewController.shared.close()
        IslandNotchController.shared.hide()
        guard let p = panel, p.isVisible else { return }
        if usesIsland, revealed {
            revealed = false
            CaptionState.shared.islandExpanded = false
            placing = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1.0, 1.0)
                #if SHOOT || DEBUG
            if usesIsland { ShootWindowLog.request(p, to: islandFrame(expanded: false), caller: "hide", animate: true) }
#endif
            p.animator().setFrame(islandFrame(expanded: false), display: true)
            }, completionHandler: { [weak self] in
                guard let self, !self.revealed else { return }
                p.orderOut(nil)
                self.refreshVisibility()
                self.placing = false
            })
            return
        }
        p.orderOut(nil)
    }

    func syncIslandReveal() {
        if notchEngine { IslandNotchController.shared.sync(); return }
        guard usesIsland, panel?.isVisible == true else { return }
        let shouldReveal = CaptionState.shared.wantsIslandExpanded
        guard shouldReveal != revealed else { return }
        revealed = shouldReveal
        CaptionState.shared.islandExpanded = shouldReveal
        placing = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = shouldReveal ? 0.62 : 0.32
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            #if SHOOT || DEBUG
            if usesIsland { ShootWindowLog.request(panel, to: islandFrame(expanded: shouldReveal), caller: "other", animate: true) }
#endif
            panel?.animator().setFrame(islandFrame(expanded: shouldReveal), display: true)
        }, completionHandler: { [weak self] in
            self?.placing = false
        })
    }

    /// 菜单「显示 / 隐藏字幕窗」
    func toggleVisible(mode: EffectiveMode) {
        refreshVisibility()
        if hasVisibleCaptions { hide() } else { show(); if !userAdjusted { place(for: mode, force: true) } }
    }

    /// Best-effort legacy capture preference. Use manual hiding before sharing.
    func applySharing() {
        IslandNotchController.shared.applyWindowPolicy()
        panel?.sharingType = CaptionState.shared.captionsVisibleInScreenShare ? .readOnly : .none
    }

    private var placing = false
    /// 用户拖过/改过大小：持久化，下次启动也不自动挪（位置本身由 frame autosave 记住）；手动切模式 / 重置（force）会挪但保留尺寸
    private var userAdjusted: Bool {
        get { UserDefaults.standard.bool(forKey: "captionUserAdjusted") }
        set { UserDefaults.standard.set(newValue, forKey: "captionUserAdjusted") }
    }

    private var lastSourceFrame: NSRect?

    /// A user's width choice must take precedence over a previously dragged size.
    func applyWidthSelection() {
        if notchEngine { IslandNotchController.shared.resizeToContent(); return }
        if usesIsland { place(for: .meeting, force: true); return }
        if panel == nil {
            build()
            place(for: CaptionState.shared.effectiveMode, force: true)
        }
        guard let p = panel, let screen = p.screen ?? NSScreen.main else { return }
        let frame = CaptionIslandLayout.desktopFrame(
            selectingWidth: CaptionState.shared.captionWidthFraction,
            current: p.frame, visibleFrame: screen.visibleFrame)
        placing = true
        // One update per click; don't start an AppKit frame animation around a popover.
        p.setFrame(frame, display: p.isVisible)
        placing = false
        userAdjusted = true
    }

    /// 会议刘海位置保持置顶岛；视频及桌面窗口按发声窗口摆位。
    func place(for mode: EffectiveMode, force: Bool = false) {
        if usesIsland, IslandNotchController.enabled {
            if IslandNotchController.shared.visible { IslandNotchController.shared.sync(force: force) }
            return
        }
        if panel == nil { build() }
        guard let p = panel else { return }
        if usesIsland {
            revealed = CaptionState.shared.wantsIslandExpanded
            CaptionState.shared.islandExpanded = revealed
            placing = true
            #if SHOOT || DEBUG
            if usesIsland { ShootWindowLog.request(p, to: islandFrame(expanded: revealed), caller: "place", animate: p.isVisible && revealed) }
#endif
            p.setFrame(islandFrame(expanded: revealed), display: true, animate: p.isVisible && revealed)
            placing = false
            return
        }
        if userAdjusted && !force { return }
        let source = AudioSourceWindow.current()
        let screen = source.flatMap { s in NSScreen.screens.first { $0.frame.contains(NSPoint(x: s.midX, y: s.midY)) } }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame else { return }
        let compact = CaptionState.shared.compactCaptions
        let defaultH: CGFloat = compact ? CaptionIslandLayout.expandedCompactHeight : CaptionIslandLayout.expandedFullHeight
        var size = userAdjusted ? p.frame.size : NSSize(width: max(480, min(vf.width - 24, vf.width * CaptionState.shared.captionWidthFraction)), height: defaultH)
        var x = vf.midX - size.width / 2
        var y: CGFloat = vf.minY + 28
        if let src = source {
            lastSourceFrame = src
            if !userAdjusted { size.width = max(480, min(size.width, max(src.width - 32, vf.width * 0.5))) }
            x = src.midX - size.width / 2
            y = max(vf.minY + 4, src.minY + 16)
        }
        x = min(max(x, vf.minX), max(vf.minX, vf.maxX - size.width))
        placing = true
        p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true, animate: p.isVisible)
        placing = false
    }

    private let islandDisplay = IslandDisplayContext()
    private func islandScreen() -> NSScreen? { CaptionIslandScreen.selected() }

    private func islandFrame(expanded: Bool) -> NSRect {
        let screen = islandScreen()
        guard let screen else { return .zero }
        islandDisplay.visibleFrame = screen.frame
        islandDisplay.notchWidth = screen.auxiliaryTopLeftArea.flatMap { left in screen.auxiliaryTopRightArea.map { right in CaptionIslandLayout.notchWidth(auxiliaryTopLeft: left, auxiliaryTopRight: right) } } ?? 0
        islandDisplay.toolbarNotchHeight = expanded && CaptionIslandScreen.hasNotch(screen)
            ? screen.frame.maxY - screen.visibleFrame.maxY : 0
        let content = expanded ? IslandExpandedView.expandedSize(in: screen.frame, measured: islandDisplay.measuredHeight) : IslandExpandedView.idleSize(notchWidth: islandDisplay.notchWidth)
        let size = CGSize(width: content.width + 30, height: CaptionIslandToolbarLayout.floatingWindowHeight(contentHeight: content.height, expanded: expanded))
        if !CaptionIslandScreen.hasNotch(screen) {
            return CaptionScreenPolicy.floatingFrame(screenFrame: screen.frame, visibleFrame: screen.visibleFrame, size: size)
        }
        if expanded {
            return CaptionIslandLayout.notchedWindowFrame(screenFrame: screen.frame,
                notchHeight: islandDisplay.toolbarNotchHeight, contentSize: content)
        }
        return CGRect(x: screen.frame.midX - size.width / 2,
                      y: screen.visibleFrame.maxY - size.height, width: size.width, height: size.height)
    }

    /// 视频模式轮询：发声窗口挪了 / 换了就跟过去（用户手动拖过则不跟）
    func followSourceIfMoved() {
        guard !usesIsland, !userAdjusted, panel?.isVisible == true, let src = AudioSourceWindow.current() else { return }
        if let last = lastSourceFrame, abs(last.midX - src.midX) < 20, abs(last.minY - src.minY) < 20, abs(last.width - src.width) < 20 { return }
        place(for: .video, force: true)
    }

    /// Content density changes resize the island without changing its top edge.
    func resizeIslandToContent() {
        guard usesIsland else { return }
        if notchEngine { IslandNotchController.shared.resizeToContent(); return }
        guard let panel, panel.isVisible else { return }
        placing = true
        IslandContentShift.setFrame(islandFrame(expanded: revealed), on: panel, reduceMotion: islandDisplay.reduceMotion)
        placing = false
    }

    /// 用户明确重置位置（菜单「重置字幕位置」）
    func resetPlacement(mode: EffectiveMode) { userAdjusted = false; place(for: mode, force: true) }

    func windowDidMove(_ notification: Notification) { if !placing && !usesIsland { userAdjusted = true } }
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard (sender as? CaptionMinimumSizePanel)?.isIslandPanel == false else { return frameSize }
        return CaptionDesktopResizePolicy.constrained(frameSize)
    }

    func windowDidResize(_ notification: Notification) { if !placing && !usesIsland { userAdjusted = true } }

    private func build() {
        let s = CaptionState.shared
        let island = usesIsland
        let compact = island || s.compactCaptions
        builtIsland = island
        let p = CaptionKeyboardPanel(
            contentRect: NSRect(x: 120, y: 80, width: island ? CaptionIslandLayout.idleMinWidth : 780, height: compact ? CaptionIslandLayout.idleHeight : 320),
            styleMask: compact ? [.borderless, .resizable, .nonactivatingPanel] : [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.isIslandPanel = island
        p.title = tr("字幕")                                   // 不叫 Kikishima：主窗口按 identifier 找，避免撞名
        p.identifier = NSUserInterfaceItemIdentifier("caption-panel")
        p.appearance = island ? NSAppearance(named: .darkAqua) : nil
        if !island { p.setFrameAutosaveName(compact ? "caption-panel-compact" : "caption-panel") }
        p.level = island ? .statusBar : .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.sharingType = s.captionsVisibleInScreenShare ? .readOnly : .none
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.hidesOnDeactivate = false
        if compact {
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isMovableByWindowBackground = !island          // 无标题栏：按住任意处拖
            p.minSize = island ? NSSize(width: 1, height: 1) : CaptionDesktopStatusLayout.minimumSize
            p.ignoresMouseEvents = !island && s.captionClickThrough
        } else {
            p.minSize = CaptionDesktopStatusLayout.minimumSize
            p.titlebarAppearsTransparent = true
            p.backgroundColor = NSColor(KKColor.captionWindowBackground).withAlphaComponent(s.captionOpacity)
        }
        p.delegate = self
        if island {
            let islandHost = NSHostingView(rootView: IslandPanelView(state: s, display: islandDisplay))
            // The controller owns island frames. Intrinsic SwiftUI spring sizes
            // must not resize the native panel during its opening animation.
            islandHost.sizingOptions = []
            p.contentView = islandHost
        } else {
            let sampleFrame = NSRect(x: 0, y: 0, width: 780, height: 320)
            let titlebarHeight = sampleFrame.height - NSWindow.contentRect(
                forFrameRect: sampleFrame, styleMask: [.titled, .closable, .resizable]).height
            let chrome = CaptionDesktopChrome(titlebarHeight: titlebarHeight)
            let contentHost = NSHostingView(rootView: CaptionFeedView(state: s))
            contentHost.rootView.desktopChrome = chrome
            p.contentView = contentHost
            if !compact {
                // A native title-bar accessory owns button hit testing. The
                // content view starts below it; unused title-bar space still drags.
                let titlebarHost = CaptionTitlebarHostingView(rootView: CaptionFeedView(
                    state: s, desktopChrome: chrome, titlebarOnly: true)
                    .frame(width: CaptionDesktopStatusLayout.toolbarWidth, height: titlebarHeight)
                    .background(Color.clear))
                titlebarHost.wantsLayer = true
                titlebarHost.layer?.backgroundColor = NSColor.clear.cgColor
                CaptionTitlebarAccessory.install(on: p, view: titlebarHost, titlebarHeight: titlebarHeight)
            }
        }
        panel = p
    }

    /// 关闭按钮 = 隐藏字幕窗，字幕继续跑（macOS 惯例：关窗不等于停任务；菜单里「显示字幕窗」随时叫回来）。停止走菜单 / 快捷键 / 主窗
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}

/// Same fixed-dark compact/expanded content as NotchKit.
private struct IslandPanelView: View {
    @Bindable var state: CaptionState
    @Bindable var display: IslandDisplayContext
    var body: some View {
        IslandExpandedView(state: state, display: display)
            .padding(.horizontal, 15)
            .padding(.top, display.toolbarNotchHeight > 0 ? display.toolbarNotchHeight : 8)
            .padding(.bottom, 15)
            .background(RoundedRectangle(cornerRadius: state.wantsIslandExpanded ? 20 : 999).fill(KKColor.notchBackground))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
    }
}

/// Two stable children: status chrome and clipped caption scroll viewport.
private struct IslandCaptionColumn: Layout {
    var statusFraction: CGFloat
    var animatableData: CGFloat {
        get { statusFraction }
        set { statusFraction = newValue }
    }
    struct Cache { var statusHeight: CGFloat = 0 }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    // Keep removal's full height when the stable status slot becomes empty.
    func updateCache(_ cache: inout Cache, subviews: Subviews) {}
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 0
        let status = subviews[0].sizeThatFits(.init(width: width, height: nil)).height
        // Retain the last full height during removal; an empty slot measures 0.
        if status > 0 { cache.statusHeight = status }
        return CGSize(width: width, height: proposal.height ??
            (status + subviews[1].sizeThatFits(.init(width: width, height: nil)).height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let frames = IslandCaptionColumnGeometry(bounds: bounds,
            statusHeight: cache.statusHeight, fraction: statusFraction)
        for (view, frame) in zip(subviews, [frames.status, frames.captions]) {
            view.place(at: frame.origin, anchor: .topLeading,
                       proposal: .init(width: frame.width, height: frame.height))
        }
    }
}

private struct IslandMeasuredHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

struct CaptionFeedView: View {
    @Bindable var state: CaptionState
    var desktopChrome: CaptionDesktopChrome? = nil
    var titlebarOnly = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 由 DynamicNotchKit 承载：黑底和胶囊态由它画，这里只出内容
    var hostedInNotch = false
    var hostSideInset: CGFloat = 15
    var islandWidth: CGFloat = 560
    var islandHeightCap: CGFloat = 148
    var toolbarNotchWidth: CGFloat = 0
    var toolbarNotchHeight: CGFloat = 0
    var onIslandHeight: (CGFloat) -> Void = { _ in }
    func islandLayout(width: CGFloat, heightCap: CGFloat,
                      onHeight: @escaping (CGFloat) -> Void) -> Self {
        var feed = self
        feed.islandWidth = width
        feed.islandHeightCap = heightCap
        feed.onIslandHeight = onHeight
        return feed
    }

    @State private var copyFeedbackOwner = UUID()
    @State private var islandQueue = CaptionReadingPolicy.DesktopQueue()
    @State private var islandClock = ProcessInfo.processInfo.systemUptime
    @State private var desktopViewportHeight: CGFloat = 0
    @State private var desktopViewportWidth: CGFloat = 0
    @State private var desktopQueue = CaptionReadingPolicy.DesktopQueue()
    @State private var desktopClock = ProcessInfo.processInfo.systemUptime
    @State private var hovering = false
    @State private var showSettings = false
    @FocusState private var toolbarFocus: CaptionToolbarAction?
    private var isIsland: Bool { state.usesIslandCaptions }

    private var toolbarMode: CaptionToolbarMode { isIsland || hostedInNotch ? .island : .captionWindow }
    private var toolbarActions: [CaptionToolbarAction] {
        CaptionToolbar.buttons(mode: toolbarMode, running: state.running, paused: state.paused)
    }
    private var islandToolbarLayout: CaptionIslandToolbarLayout {
        CaptionIslandToolbarLayout(islandWidth: islandWidth, paused: state.paused, hovering: hovering,
                                   notchWidth: toolbarNotchWidth, notchHeight: toolbarNotchHeight)
    }

    @ViewBuilder
    private var toolbar: some View {
        if toolbarMode == .island {
            toolbarButtons
                .buttonStyle(IslandToolbarButtonStyle())
                .font(.system(size: 12))
                .foregroundStyle(KKColor.textSecondary)
        } else {
            toolbarButtons
                // Existing 28pt button hit targets occupy the entire header;
                // the surrounding 5pt capsule padding shares that same height.
                .frame(height: CaptionDesktopStatusLayout.compactHeaderHeight - 10)
                .buttonStyle(KKPlainButtonStyle())
                .font(.system(size: 12))
                .foregroundStyle(KKColor.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Capsule().fill(KKColor.captionWindowBackground.opacity(0.55)))
                .padding(.horizontal, 8)
        }
    }

    private var toolbarButtons: some View {
        HStack(spacing: 6) {
            ForEach(toolbarActions, id: \.self) { action in
                toolbarButton(action)
            }
        }
    }

    @ViewBuilder
    private func toolbarButton(_ action: CaptionToolbarAction) -> some View {
        switch action {
        case .pause:
            Button { state.paused ? state.resume() : state.pause() } label: { Image(systemName: state.paused ? "play.fill" : "pause.fill") }
                .help(state.paused ? tr("继续字幕") : tr("暂停字幕")).accessibilityLabel(state.paused ? tr("继续字幕") : tr("暂停字幕"))
                .focused($toolbarFocus, equals: .pause)
                .disabled(state.resuming || state.switchingMeetingLanguage)
        case .stop:
            Button { state.stop(); CaptionPanelController.shared.hide() } label: { Image(systemName: "stop.fill") }
                .help(tr("停止字幕")).accessibilityLabel(tr("停止字幕"))
                .focused($toolbarFocus, equals: .stop)
        case .compact:
            Button { state.compactCaptions.toggle() } label: { Image(systemName: state.compactCaptions ? "rectangle.expand.vertical" : "rectangle.compress.vertical") }
                .help(tr("紧凑字幕")).accessibilityLabel(tr("紧凑字幕"))
                .focused($toolbarFocus, equals: .compact)
        case .settings:
            if toolbarMode == .island {
                Button { AppDelegate.openMenuPanel() } label: { Image(systemName: "gearshape") }
                    .help(tr("字幕设置")).accessibilityLabel(tr("字幕设置"))
                    .focused($toolbarFocus, equals: .settings)
            } else {
                Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .help(tr("字幕设置")).accessibilityLabel(tr("字幕设置"))
                    .focused($toolbarFocus, equals: .settings)
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                        IslandSettingsCard(state: state)
                    }
            }
        case .review:
            Button { CaptionReviewController.shared.show() } label: { Image(systemName: "text.magnifyingglass") }
                .help(tr("回看本场字幕")).accessibilityLabel(tr("回看本场字幕"))
                .focused($toolbarFocus, equals: .review)
        }
    }

    private var desktopToolbarVisible: Bool {
        hovering || desktopChrome?.contentHovered == true || desktopChrome?.toolbarHovered == true
            || showSettings || toolbarFocus != nil
    }
    private var desktopToolbarRow: some View {
        toolbar
            .frame(maxWidth: .infinity, alignment: .trailing)
            .frame(height: desktopChrome?.titlebarHeight ?? CaptionDesktopStatusLayout.compactHeaderHeight)
            .clipped()
            .contentShape(Rectangle())
            .opacity(desktopToolbarVisible ? 1 : 0)
            .allowsHitTesting(desktopToolbarVisible)
    }

    private var compactStatusHeader: some View {
        GeometryReader { geometry in
            let layout = CaptionDesktopStatusLayout(width: geometry.size.width, height: geometry.size.height,
                compact: true, titlebarHeight: 0, statusHeight: 18 * scale,
                hasStatus: displayedErrorStatus != nil, leadingInset: KKSpace.five + KKSpace.three)
            ZStack(alignment: .topLeading) {
                if let banner = displayedErrorStatus {
                    desktopStatusLine(banner)
                        .frame(width: layout.status.width, height: layout.status.height)
                        .clipped()
                        .offset(x: layout.status.minX)
                        .transition(.opacity)
                }
                toolbar
                    .frame(width: layout.toolbar.width, height: layout.toolbar.height, alignment: .trailing)
                    .clipped()
                    .contentShape(Rectangle())
                    .opacity(desktopToolbarVisible ? 1 : 0)
                    .allowsHitTesting(desktopToolbarVisible)
                    .offset(x: layout.toolbar.minX)
            }
        }
        .frame(height: CaptionDesktopStatusLayout.compactHeaderHeight)
        .animation(reduceMotion ? nil : .timingCurve(0.2, 0, 0, 1, duration: 0.12), value: displayedErrorStatus)
    }

    private func desktopStatusLine(_ banner: CaptionBanner) -> some View {
        CaptionStatusInlineLayout(lineHeight: state.compactCaptions ? 18 * scale : CaptionDesktopStatusLayout.statusRowHeight) {
            Circle().fill(banner.severity == .info ? KKColor.warning : KKColor.error).frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(banner.shortText)
                .fixedSize(horizontal: true, vertical: false)
                .help(banner.text).accessibilityLabel(banner.text)
            if let action = banner.action {
                Button(action.title) {
                    switch action {
                    case .upgrade: state.openUpgrade()
                    default: state.performBanner(action)
                    }
                }
                .buttonStyle(KKPlainButtonStyle())
                .disabled(action == .retry && state.finishingCaptions)
            }
        }
        .font(state.captionFont(13 * scale))
        .foregroundStyle(KKColor.textSecondary)
        .clipped()
        .contentShape(Rectangle())
    }

    /// Island error chrome stays in its existing location with existing insets.
    private func islandErrorRow(_ banner: CaptionBanner) -> some View {
        HStack(spacing: 10) {
            Circle().fill(banner.severity == .info ? KKColor.warning : KKColor.error).frame(width: 6, height: 6)
            Text(banner.shortText).font(.system(size: 13)).foregroundStyle(banner.severity == .info ? KKColor.warning : KKColor.textPrimary)
                .fixedSize(horizontal: true, vertical: false)
                .help(banner.text).accessibilityLabel(banner.text)
            Spacer()
            if let action = banner.action {
                if action == .upgrade {
                    if state.plan != "pro" && state.plan != "dev" {
                        Button(tr("升级 Pro")) { state.openUpgrade() }
                            .kkPrimaryButton().controlSize(.small)
                    }
                } else {
                    Button(tr(action.title)) { state.performBanner(action) }
                        .buttonStyle(KKQuietButtonStyle()).controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .transition(.opacity)
    }

    @ViewBuilder
    var body: some View {
        if titlebarOnly {
            desktopToolbarRow
                .contentShape(Rectangle())
                .onHover { desktopChrome?.toolbarHovered = $0 }
        } else {
            feedBody
        }
    }

    private var feedBody: some View {
        ZStack {
            if isIsland && !state.islandExpanded && !hostedInNotch {
                islandIdle
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    if toolbarMode == .captionWindow, state.compactCaptions {
                        compactStatusHeader
                    }
                    content
                }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -10)),
                        removal: .opacity
                    ))
            }
        }
        .animation(.spring(response: 0.48, dampingFraction: 0.86), value: state.islandExpanded)
        .onDisappear {
            showSettings = false
        }
        .onChange(of: toolbarActions) {
            if toolbarMode == .island, let focus = toolbarFocus, !toolbarActions.contains(focus) { toolbarFocus = nil }
        }
        .onHover {
            hovering = $0
            desktopChrome?.contentHovered = $0
        }
        .background {
            if !hostedInNotch, isIsland || state.compactCaptions {
                RoundedRectangle(cornerRadius: isIsland && !state.islandExpanded ? 18 : 22, style: .continuous)
                    .fill((isIsland ? KKColor.notchBackground : KKColor.captionWindowBackground).opacity(state.captionOpacity))
            }
        }
        .onChange(of: state.chunks.count) { CaptionPanelController.shared.syncIslandReveal() }
        .onChange(of: state.pendingEn) { CaptionPanelController.shared.syncIslandReveal() }
        .onChange(of: state.pendingDraft) { CaptionPanelController.shared.syncIslandReveal() }
        .onChange(of: state.paused) { CaptionPanelController.shared.syncIslandReveal() }
        .onChange(of: state.errorBanner?.text) { CaptionPanelController.shared.syncIslandReveal() }
        .onAppear { CaptionPanelController.shared.syncIslandReveal() }
        .transformEnvironment(\.colorScheme) { scheme in
            if isIsland || hostedInNotch { scheme = .dark }
        }
    }

    private var islandIdle: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill((state.captionDisplayStatus == .error ? KKColor.error : state.captionDisplayStatus.isWarning ? KKColor.warning : KKColor.historyInk).opacity(state.running ? 0.92 : 0.45))
                .frame(width: 22, height: 8)
            if state.running {
                Capsule()
                    .fill(KKColor.historyInk.opacity(0.35 + state.audioLevel * 0.55))
                    .frame(width: 3, height: 6 + state.audioLevel * 10)
                Capsule()
                    .fill(KKColor.historyInk.opacity(0.28 + state.audioLevel * 0.5))
                    .frame(width: 3, height: 4 + state.audioLevel * 14)
                Capsule()
                    .fill(KKColor.historyInk.opacity(0.35 + state.audioLevel * 0.55))
                    .frame(width: 3, height: 6 + state.audioLevel * 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(state.captionDisplayStatus == .idle ? tr("字幕") : state.captionStatusText)
    }

    private var displayedErrorStatus: CaptionBanner? {
        toolbarMode == .island ? state.captionStatusBanner : state.desktopCaptionStatusBanner
    }

    private var content: some View {
        let column = toolbarMode == .island
            ? AnyLayout(IslandCaptionColumn(statusFraction: displayedErrorStatus == nil ? 0 : 1))
            : AnyLayout(VStackLayout(spacing: 0))
        return column {
            if toolbarMode == .island {
                // Keep two stable layout slots; removed status text is never in AX.
                ZStack {
                    if let banner = displayedErrorStatus {
                        islandErrorRow(banner)
                            .background { GeometryReader { geometry in
                                Color.clear.preference(key: IslandMeasuredHeight.self, value: geometry.size.height)
                            } }
                            .transition(.identity)
                    }
                }
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
                .accessibilityHidden(displayedErrorStatus == nil)
            } else if let banner = displayedErrorStatus {
                if !state.compactCaptions {
                    desktopStatusLine(banner)
                        .frame(height: CaptionDesktopStatusLayout.statusRowHeight)
                        .padding(.top, KKSpace.one)
                        .padding(.horizontal, KKSpace.five + KKSpace.three)
                        .transition(.opacity)
                }
            }
            if state.paused && !(isIsland || hostedInNotch) {
                HStack(spacing: 10) {
                    Image(systemName: "pause.circle.fill").foregroundStyle(KKColor.textSecondary)
                    Text(tr("已暂停 · 声音不再记录")).font(.system(size: 13)).foregroundStyle(KKColor.textPrimary)
                    Spacer()
                    Button(tr("继续")) { state.resume() }
                        .accessibilityLabel(tr("继续字幕"))
                        .buttonStyle(KKQuietButtonStyle()).controlSize(.small)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(KKColor.surfaceRaised)
                .transition(.movingParts.blur.combined(with: .move(edge: .top)))
            }
            if isIsland || hostedInNotch {
                ScrollView(.vertical) { captionRows }
                    .frame(width: CaptionIslandLayout.textColumnWidth(islandWidth: islandWidth))
                    .padding(.horizontal, KKSpace.five - hostSideInset)
            } else {
                GeometryReader { geometry in
                    captionRows
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
                        .onAppear { desktopViewportWidth = geometry.size.width; desktopViewportHeight = geometry.size.height; updateDesktopQueue() }
                        .onChange(of: geometry.size.height) { desktopViewportHeight = geometry.size.height; updateDesktopQueue() }
                        .onChange(of: geometry.size.width) { desktopViewportWidth = geometry.size.width; updateDesktopQueue() }
                }
                .onChange(of: desktopItems) { updateDesktopQueue() }
                .onChange(of: hasPending) { updateDesktopQueue() }
                .onChange(of: desktopHistoryLimit) { updateDesktopQueue() }
                .task {
                    while !Task.isCancelled {
                        updateDesktopQueue()
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    }
                }
            }

        }
        .onPreferenceChange(IslandMeasuredHeight.self) { height in
            if isIsland || hostedInNotch { onIslandHeight(height) }
        }
        // The caption viewport is measured and clamped before adding chrome.
        .padding(.top, toolbarMode == .island ? islandToolbarLayout.contentTop : 0)
        .overlay(alignment: .topLeading) {
            if toolbarMode == .island {
                toolbar
                    .opacity(hovering || showSettings || toolbarFocus != nil ? 1 : 0)
                    .allowsHitTesting(hovering || showSettings || toolbarFocus != nil)
                    .frame(width: islandToolbarLayout.toolbar.width, height: islandToolbarLayout.toolbar.height)
                    .offset(x: islandToolbarLayout.toolbar.minX - hostSideInset,
                            y: islandToolbarLayout.toolbar.minY)
            }
        }
        .background(isIsland || hostedInNotch ? KKColor.notchBackground : Color.clear)
        .animation(reduceMotion ? nil : .timingCurve(0.2, 0, 0, 1, duration: toolbarMode == .island ? 0.2 : 0.12), value: displayedErrorStatus)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.paused)
        .contextMenu { Button(tr("复制全部译文")) { copyAll() } }   // 紧凑模式与空白处也能右键
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("Kikishima 字幕"))
        .accessibilityAddTraits(.updatesFrequently)
        .onChange(of: state.uiLanguage) { CaptionPanelController.shared.applyAppearance() }
        // Apple 本地机翻草稿：session 只在此闭包内有效，从流里收块、翻完回填
        .translationTask(state.translationConfig) { session in
#if SHOOT || DEBUG
            if ShootSimulation.requestedMode != nil { return }
#endif
            // Apple 本地翻译：首次会弹系统下载语言包的框（只一次）；失败就没有草稿，不影响正式译文
            try? await session.prepareTranslation()
            for await (id, text) in state.draftRequests {
                if let r = try? await session.translate(text) {
                    await MainActor.run { state.applyDraft(id, for: text, r.targetText) }
                }
            }
        }
    }

    private var hasPending: Bool { !state.pendingEn.isEmpty || !state.pendingDraft.isEmpty }
    private var latestReadableID: UUID? {
        if let latest = state.visibleCaptionChunks.last(where: { !$0.isMarker }), latest.zh.isEmpty,
           latest.translationExhausted || state.translationPaused || latest.captionFinalized || (!state.running && !state.starting && !state.finishingCaptions) {
            return latest.id
        }
        return state.visibleCaptionChunks.last {
            !$0.isMarker && CaptionReadingPolicy.isReadable($0.zh, isDraft: $0.isDraft)
        }?.id
    }
    private var desktopHistoryLimit: Int {
        CaptionHierarchy.desktopHistoryCount(availableHeight: Double(desktopViewportHeight),
            userSize: state.zhFontSize, showTranslation: state.showTranslation, showSource: state.showSource,
            currentHeight: desktopCurrentText.height(scale: scale))
    }
    private var desktopItems: [CaptionReadingPolicy.DesktopItem] {
        state.visibleCaptionChunks.filter { !$0.isMarker }.map {
            .init(id: $0.id, finalized: $0.captionFinalized || !state.showTranslation || state.translationPaused,
                  translated: $0.translationComplete)
        }
    }
    private var desktopLayout: CaptionReadingPolicy.DesktopLayout {
        var queue = desktopQueue
        return CaptionReadingPolicy.desktopLayout(items: desktopItems, historyLimit: max(1, desktopHistoryLimit - desktopCurrentText.overflow.count),
            pending: hasPending, now: desktopClock, queue: &queue)
    }
    private func updateDesktopQueue() {
        desktopClock = ProcessInfo.processInfo.systemUptime
        _ = CaptionReadingPolicy.desktopLayout(items: desktopItems, historyLimit: max(1, desktopHistoryLimit - desktopCurrentText.overflow.count),
            pending: hasPending, now: desktopClock, queue: &desktopQueue)
    }
    private var islandHistoryCapacity: Int {
        CaptionHierarchy.historyLimit(userSize: state.zhFontSize,
            showTranslation: state.showTranslation, showSource: state.showSource,
            banner: state.errorBanner != nil || state.paused, height: Double(islandHeightCap))
    }
    private var islandLayoutResult: CaptionReadingPolicy.DesktopLayout {
        var queue = islandQueue
        return CaptionReadingPolicy.islandLayout(items: desktopItems, historyLimit: islandHistoryCapacity,
            pending: hasPending, showTranslation: state.showTranslation, now: islandClock, queue: &queue)
    }
    private func updateIslandQueue() {
        islandClock = ProcessInfo.processInfo.systemUptime
        _ = CaptionReadingPolicy.islandLayout(items: desktopItems, historyLimit: islandHistoryCapacity,
            pending: hasPending, showTranslation: state.showTranslation, now: islandClock, queue: &islandQueue)
    }
    private var displayedChunks: [CaptionChunk] {
        let chunks = state.visibleCaptionChunks.filter { !$0.isMarker }
        if !(isIsland || hostedInNotch) {
            let ids = Set(desktopLayout.ids)
            return chunks.filter { ids.contains($0.id) }
        }
        let limit = CaptionHierarchy.historyLimit(userSize: state.zhFontSize,
            showTranslation: state.showTranslation, showSource: state.showSource,
            banner: state.errorBanner != nil || state.paused, height: Double(islandHeightCap))
        if state.showTranslation {
            let layout = islandLayoutResult
            let ids = Set(CaptionReadingPolicy.islandVisibleIDs(layout, compact: state.compactCaptions))
            return chunks.filter { ids.contains($0.id) }.map { chunk in
                // Presentation copy only: the model's unfinished status remains
                // unchanged and protected until its real translation arrives.
                var visible = chunk
                if layout.sourceOnly.contains(chunk.id) {
                    visible.zh = ""
                    visible.translationExhausted = true
                }
                return visible
            }
        }
        let indices = CaptionReadingPolicy.retainedIndices(
            readable: chunks.map { state.showTranslation && CaptionReadingPolicy.isReadable($0.zh, isDraft: $0.isDraft) },
            recentLimit: hasPending ? limit : limit + 1)
        return indices.map { chunks[$0] }
    }

    @ViewBuilder
    private var captionRows: some View {
        if isIsland || hostedInNotch {
            VStack(alignment: .leading, spacing: KKSpace.one) {
                if state.paused { islandPauseRow }
                captionLines
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(width: CaptionIslandLayout.textColumnWidth(islandWidth: islandWidth), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { updateIslandQueue() }
            .onChange(of: desktopItems) { updateIslandQueue() }
            .onChange(of: hasPending) { updateIslandQueue() }
            .onChange(of: islandHistoryCapacity) { updateIslandQueue() }
            .task {
                while !Task.isCancelled {
                    updateIslandQueue()
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
            // Measure the final layout, never an interpolated animation height.
            .transaction { $0.animation = nil }
            .background { GeometryReader { geometry in
                Color.clear.preference(key: IslandMeasuredHeight.self, value: geometry.size.height)
            } }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kk-caption-text-slab")
        } else {
            desktopCaptionRows
        }
    }

    private var islandPauseRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.fill")
            Text(tr("已暂停 · 声音不再记录")).font(.system(size: 13))
            Spacer(minLength: 0)
            Button(tr("继续")) { state.resume() }
                .accessibilityLabel(tr("继续字幕"))
                .buttonStyle(KKQuietButtonStyle()).controlSize(.small)
        }
        .foregroundStyle(KKColor.textSecondary)
        .padding(.vertical, KKSpace.two)
    }

    @ViewBuilder
    private var desktopCaptionRows: some View {
        if !displayedChunks.isEmpty || hasPending || (!state.captionDisplayStatus.showsLabel && !state.paused) {
            captionLines
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, KKSpace.three)
                .padding(.vertical, KKSpace.two)
                .background(KKColor.surfaceBase, in: RoundedRectangle(cornerRadius: KKRadius.md))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("kk-caption-text-slab")
                .padding(.horizontal, KKSpace.five)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var captionLines: some View {
        Group {
            if displayedChunks.isEmpty && !hasPending && !state.captionDisplayStatus.showsLabel && !state.paused {
                Text(state.captionStatusShortText)
                .accessibilityLabel(state.captionStatusText)
                .font(state.captionFont(14)).foregroundStyle(state.captionDisplayStatus == .error ? KKColor.error : state.captionDisplayStatus.isWarning ? KKColor.warning : KKColor.textSecondary)
            } else if !(isIsland || hostedInNotch) {
                desktopCaptionLines
            } else {
                VStack(alignment: .leading, spacing: KKSpace.one) {
                    ForEach(Array(displayedChunks.enumerated()), id: \.element.id) { index, chunk in
                        let current = state.showTranslation
                        ? islandLayoutResult.current == chunk.id
                        : !hasPending && index == displayedChunks.count - 1
                        let age = state.showTranslation
                        ? islandLayoutResult.history.count - (islandLayoutResult.history.firstIndex(of: chunk.id) ?? islandLayoutResult.history.count)
                        : displayedChunks.count - index - (hasPending ? 0 : 1)
                        captionRow(chunk, current: current, age: age)
                    }
                    if hasPending {
                        if islandLayoutResult.showsPending {
                            VStack(alignment: .leading, spacing: KKSpace.one) {
                                let text = CaptionHierarchy.row(source: state.pendingEn, translation: state.pendingDraft,
                                waiting: !state.translationPaused && (state.running || state.starting || state.finishingCaptions),
                                current: true, showTranslation: state.showTranslation, showSource: state.showSource)
                                Text(text.primary)
                                .kkCaptionLineHeight(fontSize: 17 * scale, lineHeight: 24 * scale)
                                .font(state.captionFont(CaptionHierarchy.fontSize(current: true, userSize: state.zhFontSize), weight: .medium))
                                .foregroundStyle(text.placeholder ? KKColor.textTertiary : KKColor.textPrimary).lineLimit(2)
                                if let secondary = text.secondary {
                                    Text(secondary)
                                    .kkCaptionLineHeight(fontSize: 13 * scale, lineHeight: 18 * scale)
                                    .font(state.captionFont(CaptionHierarchy.sourceSize * scale))
                                    .foregroundStyle(KKColor.textSecondary).lineLimit(1).truncationMode(.head)
                                }
                            }
                            .padding(.leading, 10)
                            .overlay(alignment: .leading) { Rectangle().fill(KKColor.brand).frame(width: 2) }
                        }
                    }
                }
            }
        }
    }


    private var desktopCaptionLines: some View {
        let layout = desktopLayout
        let chunks = state.visibleCaptionChunks.filter { !$0.isMarker }
        let current = desktopCurrentText
        let overflow = Array(current.overflow.suffix(max(0, desktopHistoryLimit - layout.history.count)))
        return VStack(alignment: .leading, spacing: KKSpace.one) {
            ForEach(layout.history, id: \.self) { id in
                if let chunk = chunks.first(where: { $0.id == id }) {
                    desktopHistoryRow(chunk, sourceOnly: layout.sourceOnly.contains(id),
                        age: layout.history.count - (layout.history.firstIndex(of: id) ?? 0))
                        .transition(.opacity)
                }
            }
            ForEach(Array(overflow.enumerated()), id: \.offset) { _, line in
                Text(line).font(state.captionFont(15 * scale))
                    .foregroundStyle(KKColor.historyInk)
                    .opacity(max(CaptionOpacityPolicy.minimumHistoryInkOpacity, CaptionHierarchy.opacity(age: 1)))
                    .lineLimit(1).frame(height: 21 * scale).padding(.leading, 10)
            }
            if layout.current != nil || layout.showsPending {
                VStack(alignment: .leading, spacing: KKSpace.one) {
                    Text(current.primary).font(state.captionFont(17 * scale, weight: .medium))
                        .kkCaptionLineHeight(fontSize: 17 * scale, lineHeight: 24 * scale)
                        .foregroundStyle(KKColor.textPrimary)
                        .lineLimit(current.translated ? 2 : 1)
                        .frame(height: Double(current.lineCount) * 24 * scale, alignment: .leading)
                    if let source = current.secondary {
                        Text(source).font(state.captionFont(13 * scale))
                            .foregroundStyle(KKColor.textSecondary).lineLimit(1).truncationMode(.head)
                            .frame(height: 18 * scale)
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(KKColor.brand).frame(width: 2) }
                .textSelection(.enabled)
                .contextMenu {
                    if let id = layout.current, let chunk = chunks.first(where: { $0.id == id }) {
                        Button(tr("复制译文")) { copy(chunk.zh, feedbackID: copyFeedbackID(chunk)) }
                        Button(tr("复制原文")) { copy(chunk.en, feedbackID: copyFeedbackID(chunk)) }
                    }
                }
                .overlay(alignment: .trailing) {
                    if let id = layout.current, let chunk = chunks.first(where: { $0.id == id }) {
                        CopyFeedbackBadge(id: copyFeedbackID(chunk))
                    }
                }
            }
        }
        .animation(reduceMotion ? .linear(duration: 0.1) : .linear(duration: 0.3), value: layout.history)
    }

    private func desktopHistoryRow(_ chunk: CaptionChunk, sourceOnly: Bool, age: Int) -> some View {
        let translation = sourceOnly || chunk.translationExhausted ? "" : chunk.displayTranslation
        let text = state.showTranslation && !translation.isEmpty ? translation : chunk.displaySource
        return Text(text).font(state.captionFont(15 * scale))
            .foregroundStyle(translation.isEmpty ? KKColor.textPrimary : KKColor.historyInk)
            .opacity(translation.isEmpty ? 1 : max(CaptionOpacityPolicy.minimumHistoryInkOpacity, CaptionHierarchy.opacity(age: age)))
            .lineLimit(1).truncationMode(.tail)
            .frame(height: 21 * scale).padding(.leading, 10)
            .textSelection(.enabled)
            .contextMenu {
                Button(tr("复制译文")) { copy(chunk.zh, feedbackID: copyFeedbackID(chunk)) }
                Button(tr("复制原文")) { copy(chunk.en, feedbackID: copyFeedbackID(chunk)) }
            }
            .overlay(alignment: .trailing) { CopyFeedbackBadge(id: copyFeedbackID(chunk)) }
    }

    private var scale: Double { state.zhFontSize / 18 }

    private func captionRow(_ chunk: CaptionChunk, current: Bool, age: Int) -> some View {
        let text = CaptionHierarchy.row(source: chunk.displaySource, translation: chunk.displayTranslation,
            waiting: !chunk.translationExhausted && !state.translationPaused && !chunk.captionFinalized && (state.running || state.starting || state.finishingCaptions),
            current: current, showTranslation: state.showTranslation, showSource: state.showSource)
        return HStack(alignment: .center, spacing: KKSpace.one) {
            VStack(alignment: .leading, spacing: KKSpace.one) {
                Text(text.primary)
                    .kkCaptionLineHeight(fontSize: (current ? 17 : 15) * scale, lineHeight: (current ? 24 : 21) * scale)
                    .font(state.captionFont(CaptionHierarchy.fontSize(current: current, userSize: state.zhFontSize), weight: current ? .medium : .regular))
                    .foregroundStyle(text.placeholder ? KKColor.textTertiary : chunk.zh.isEmpty || current ? KKColor.textPrimary : KKColor.historyInk)
                    .opacity(current || chunk.zh.isEmpty ? 1 : max(CaptionOpacityPolicy.minimumHistoryInkOpacity, CaptionHierarchy.opacity(age: age)))
                    .lineLimit(current ? nil : 1)
                    .id(chunk.displayTranslation.isEmpty)
                    .transition(.identity)
                if let secondary = text.secondary {
                    Text(secondary)
                        .kkCaptionLineHeight(fontSize: 13 * scale, lineHeight: 18 * scale)
                        .font(state.captionFont(CaptionHierarchy.sourceSize * scale))
                        .foregroundStyle(KKColor.textSecondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                if current { Rectangle().fill(KKColor.brand).frame(width: 2) }
            }
            .textSelection(.enabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text.accessibilityText)
            .frame(maxWidth: .infinity, alignment: .leading)
            CopyFeedbackBadge(id: copyFeedbackID(chunk))
        }
        .contextMenu {
            Button(tr("复制译文")) { copy(chunk.zh, feedbackID: copyFeedbackID(chunk)) }
            Button(tr("复制原文")) { copy(chunk.en, feedbackID: copyFeedbackID(chunk)) }
            Divider()
            Button(tr("复制全部译文")) { copyAll() }
        }
    }

    private var desktopTextWidth: Double { max(1, Double(desktopViewportWidth) - 40 - 24 - 10) }
    private var desktopCurrentText: CaptionReadingPolicy.DesktopText {
        let chunks = state.visibleCaptionChunks.filter { !$0.isMarker }
        // The queue owns the current slot. All-finalized steady state uses the
        // newest sentence until a new source arrives, just like desktopLayout.
        let current = desktopQueue.current.flatMap { id in chunks.first { $0.id == id } }
            ?? chunks.first { !desktopQueue.advanced.contains($0.id) }
            ?? (hasPending ? nil : chunks.last)
        let source = current?.displaySource ?? state.pendingEn
        let translation = current.map { $0.translationExhausted ? "" : $0.displayTranslation } ?? state.pendingDraft
        let waiting = current.map { !$0.captionFinalized } ?? true
        let text = CaptionHierarchy.row(source: source, translation: translation,
            waiting: waiting && !state.translationPaused && (state.running || state.starting || state.finishingCaptions),
            current: true, showTranslation: state.showTranslation, showSource: state.showSource)
        return CaptionReadingPolicy.desktopText(primary: text.primary, secondary: text.secondary,
            translated: state.showTranslation && !translation.isEmpty, width: desktopTextWidth,
            userSize: state.zhFontSize, family: state.captionFontFamily)
    }
    private func copyFeedbackID(_ chunk: CaptionChunk) -> String {
        "\(copyFeedbackOwner)/\(chunk.id)"
    }

    private func copy(_ s: String, feedbackID: String? = nil) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(s, forType: .string), let feedbackID {
            CopyFeedbackPresenter.shared.show(feedbackID)
        }
    }
    private func copyAll() {
        copy(state.chunks.filter { !$0.isMarker }.map(\.zh).filter { !$0.isEmpty }.joined(separator: "\n"))
    }
}

/// Island-only 20pt hit targets; the desktop retains KKPlainButtonStyle's 28pt targets.
private struct IslandToolbarButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(IslandToolbarButtonArtwork())
            .kkFocusRing(radius: 6)
    }
}

private struct IslandToolbarButtonArtwork: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: CaptionIslandToolbarLayout.buttonSize, height: CaptionIslandToolbarLayout.buttonSize)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Exactly three measured children: dot, sentence, action. No trailing Spacer
/// can move the action away from a short sentence.
private struct CaptionStatusInlineLayout: Layout {
    let lineHeight: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +)
        return CGSize(width: proposal.width ?? natural + 2 * CaptionStatusInlineGeometry.gap,
                      height: lineHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 || subviews.count == 3 else { return }
        let geometry = CaptionStatusInlineGeometry(width: bounds.width, height: bounds.height,
            textWidth: subviews[1].sizeThatFits(.unspecified).width,
            actionWidth: subviews.count == 3 ? subviews[2].sizeThatFits(.unspecified).width : 0)
        for (index, rect) in [geometry.dot, geometry.text, geometry.action].prefix(subviews.count).enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.midY),
                anchor: .leading, proposal: ProposedViewSize(width: rect.width, height: rect.height))
        }
    }
}
