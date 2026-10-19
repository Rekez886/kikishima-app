// 悬浮字幕窗：置顶、不抢焦点、全空间可见（能浮在 Zoom 全屏上）、默认不进屏幕共享（sharingType = .none）
import SwiftUI
import AppKit
import QuartzCore
import Translation
import Pow

/// Can accept explicit keyboard interaction without becoming the main app window.
private final class CaptionKeyboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CaptionPanelController: NSObject, NSWindowDelegate {
    static let shared = CaptionPanelController()
    private var panel: NSPanel?

    /// 会议刘海走 DynamicNotchKit；关闭该引擎时仍用同款岛内容。
    private var notchEngine: Bool { usesIsland && IslandNotchController.enabled }
    var isVisible: Bool { panel?.isVisible == true || IslandNotchController.shared.visible }

    func show() {
        if notchEngine { IslandNotchController.shared.show(); return }
        if panel == nil { build() }
        applySharing()
        applyAppearance()
        if usesIsland {
            revealed = CaptionState.shared.wantsIslandExpanded
            CaptionState.shared.islandExpanded = revealed
            placing = true
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
            panel?.setFrame(frame, display: false)
            placing = false
            if visible { panel?.orderFrontRegardless() }
            return
        }
        p.ignoresMouseEvents = !island && s.compactCaptions && s.captionClickThrough
        p.title = tr("字幕")
        p.appearance = nil
        p.isOpaque = false
        p.backgroundColor = wantBorderless ? .clear : NSColor(KKColor.notchBackground).withAlphaComponent(s.captionOpacity)
    }

    func hide() {
        IslandNotchController.shared.hide()
        guard let p = panel, p.isVisible else { return }
        if usesIsland, revealed {
            revealed = false
            CaptionState.shared.islandExpanded = false
            placing = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1.0, 1.0)
                p.animator().setFrame(islandFrame(expanded: false), display: true)
            }, completionHandler: { [weak self] in
                guard let self, !self.revealed else { return }
                p.orderOut(nil)
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
            panel?.animator().setFrame(islandFrame(expanded: shouldReveal), display: true)
        }, completionHandler: { [weak self] in
            self?.placing = false
        })
    }

    /// 菜单「显示 / 隐藏字幕窗」
    func toggleVisible(mode: EffectiveMode) {
        if isVisible { hide() } else { show(); if !userAdjusted { place(for: mode, force: true) } }
    }

    /// 屏幕共享里可见？默认不可见：一边看翻译字幕一边共享屏幕，字幕不能漏给对方
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
        let content = expanded ? IslandExpandedView.expandedSize(in: screen.frame) : IslandExpandedView.idleSize(notchWidth: islandDisplay.notchWidth)
        let size = CGSize(width: content.width + 30, height: content.height + 23)
        if !CaptionIslandScreen.hasNotch(screen) {
            return CaptionScreenPolicy.floatingFrame(screenFrame: screen.frame, size: size)
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
        panel.setFrame(islandFrame(expanded: revealed), display: true)
        placing = false
    }

    /// 用户明确重置位置（菜单「重置字幕位置」）
    func resetPlacement(mode: EffectiveMode) { userAdjusted = false; place(for: mode, force: true) }

    func windowDidMove(_ notification: Notification) { if !placing && !usesIsland { userAdjusted = true } }
    func windowDidResize(_ notification: Notification) { if !placing && !usesIsland { userAdjusted = true } }

    private func build() {
        let s = CaptionState.shared
        let island = usesIsland
        let compact = island || s.compactCaptions
        builtIsland = island
        let p = CaptionKeyboardPanel(
            contentRect: NSRect(x: 120, y: 80, width: island ? CaptionIslandLayout.idleMinWidth : 780, height: compact ? CaptionIslandLayout.idleHeight : 320),
            styleMask: compact ? [.borderless, .resizable, .nonactivatingPanel] : [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        p.title = tr("字幕")                                   // 不叫 Kikishima：主窗口按 identifier 找，避免撞名
        p.identifier = NSUserInterfaceItemIdentifier("caption-panel")
        if !island { p.setFrameAutosaveName(compact ? "caption-panel-compact" : "caption-panel") }
        p.level = island ? .statusBar : .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.sharingType = s.captionsVisibleInScreenShare ? .readOnly : .none   // 屏幕共享 / 录屏里默认不出现（设置里可改）
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.hidesOnDeactivate = false
        if compact {
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isMovableByWindowBackground = !island          // 无标题栏：按住任意处拖
            p.minSize = island ? NSSize(width: 1, height: 1) : NSSize(width: 360, height: 90)
            p.ignoresMouseEvents = !island && s.captionClickThrough
        } else {
            p.titlebarAppearsTransparent = true
            p.backgroundColor = NSColor(KKColor.notchBackground).withAlphaComponent(s.captionOpacity)
        }
        p.delegate = self
        if island {
            p.contentView = NSHostingView(rootView: IslandPanelView(state: s, display: islandDisplay))
        } else {
            p.contentView = NSHostingView(rootView: CaptionFeedView(state: s))
        }
        panel = p
    }

    /// 关闭按钮 = 隐藏字幕窗，字幕继续跑（macOS 惯例：关窗不等于停任务；菜单里「显示字幕窗」随时叫回来）。停止走菜单 / 快捷键 / 主窗
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}

/// Same compact/expanded content as NotchKit, including live appearance changes.
private struct IslandPanelView: View {
    @Bindable var state: CaptionState
    @Bindable var display: IslandDisplayContext
    var body: some View {
        IslandExpandedView(state: state, display: display)
            .padding(.horizontal, 15).padding(.top, 8).padding(.bottom, 15)
            .background(RoundedRectangle(cornerRadius: state.wantsIslandExpanded ? 20 : 999).fill(KKColor.notchBackground))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct CaptionFeedView: View {
    @Bindable var state: CaptionState
    /// 由 DynamicNotchKit 承载：黑底和胶囊态由它画，这里只出内容
    var hostedInNotch = false
    var hostSideInset: CGFloat = 15
    @State private var hovering = false
    @State private var showSettings = false
    private enum ToolbarAction: Hashable { case pause, stop, compact, settings }
    @FocusState private var toolbarFocus: ToolbarAction?
    private var isIsland: Bool { state.usesIslandCaptions }

    /// 悬停出现的小工具条：暂停 / 停止 / 切形态（点击穿透开着时鼠标到不了这里，靠菜单栏）
    private var toolbar: some View {
        HStack(spacing: 6) {
            if state.running {
                Button { state.paused ? state.resume() : state.pause() } label: { Image(systemName: state.paused ? "play.fill" : "pause.fill") }
                    .help(state.paused ? tr("继续字幕") : tr("暂停字幕")).accessibilityLabel(state.paused ? tr("继续字幕") : tr("暂停字幕"))
                    .focused($toolbarFocus, equals: .pause)
                    .disabled(state.resuming || state.switchingMeetingLanguage)
                Button { state.stop(); CaptionPanelController.shared.hide() } label: { Image(systemName: "stop.fill") }
                    .help(tr("停止字幕")).accessibilityLabel(tr("停止字幕"))
                    .focused($toolbarFocus, equals: .stop)
            }
            Button { state.compactCaptions.toggle() } label: { Image(systemName: state.compactCaptions ? "rectangle.expand.vertical" : "rectangle.compress.vertical") }
                .help(tr("紧凑字幕")).accessibilityLabel(tr("紧凑字幕"))
                .focused($toolbarFocus, equals: .compact)
            Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                .help(tr("字幕设置")).accessibilityLabel(tr("字幕设置"))
                .focused($toolbarFocus, equals: .settings)
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { IslandSettingsCard(state: state) }
        }
        .buttonStyle(KKPlainButtonStyle())
        .font(.system(size: 12))
        .foregroundStyle(KKColor.textSecondary)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(KKColor.notchBackground.opacity(0.55)))
        .padding(8)
    }

    var body: some View {
        ZStack {
            if isIsland && !state.islandExpanded && !hostedInNotch {
                islandIdle
                    .transition(.opacity)
            } else {
                content
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -10)),
                        removal: .opacity
                    ))
            }
        }
        .animation(.spring(response: 0.48, dampingFraction: 0.86), value: state.islandExpanded)
        .onChange(of: showSettings) { state.islandSettingsOpen = showSettings }
        .onDisappear {
            showSettings = false
            state.islandSettingsOpen = false
        }
        .overlay(alignment: .topTrailing) {
            if state.islandExpanded || !isIsland || hostedInNotch {
                // Keep controls in the keyboard tree even before the mouse hovers.
                toolbar
                    .opacity(hovering || showSettings || toolbarFocus != nil ? 1 : 0)
                    .allowsHitTesting(hovering || showSettings || toolbarFocus != nil)
            }
        }
        .onHover { hovering = $0 }
        .background {
            if !hostedInNotch, isIsland || state.compactCaptions {
                RoundedRectangle(cornerRadius: isIsland && !state.islandExpanded ? 18 : 22, style: .continuous)
                    .fill(KKColor.notchBackground.opacity(state.captionOpacity))
            }
        }
        .onChange(of: state.chunks.count) { CaptionPanelController.shared.syncIslandReveal() }
        .onChange(of: state.pendingEn) { CaptionPanelController.shared.syncIslandReveal() }
        .onChange(of: state.pendingDraft) { CaptionPanelController.shared.syncIslandReveal() }
        .onChange(of: state.paused) { CaptionPanelController.shared.syncIslandReveal() }
        .onChange(of: state.errorBanner?.text) { CaptionPanelController.shared.syncIslandReveal() }
        .onAppear { CaptionPanelController.shared.syncIslandReveal() }
    }

    private var islandIdle: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill((state.silentTooLong ? KKColor.warning : KKColor.historyInk).opacity(state.running ? 0.92 : 0.45))
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
        .accessibilityLabel(state.running ? CaptionListeningStatus.text(silentTooLong: state.silentTooLong, audioStalled: state.audioStalled) : tr("字幕"))
    }

    private var content: some View {
        VStack(spacing: 0) {
            if let banner = state.errorBanner {
                HStack(spacing: 10) {
                    Image(systemName: banner.severity == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundStyle(banner.severity == .error ? KKColor.warning : KKColor.textSecondary)
                    Text(banner.text).font(.system(size: 13)).foregroundStyle(KKColor.textPrimary)
                    Spacer()
                    if let action = banner.action {
                        if action == .upgrade {
                            if state.plan != "pro" && state.plan != "dev" {
                                Button(tr("升级 Pro")) { state.openUpgrade() }
                                    .kkPrimaryButton()
                                    .controlSize(.small)
                            }
                        } else {
                            Button(tr(action.title)) { state.performBanner(action) }
                                .buttonStyle(KKQuietButtonStyle())
                                .controlSize(.small)
                        }
                    }
                    Button { state.errorBanner = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(KKPlainButtonStyle()).foregroundStyle(KKColor.textTertiary)
                        .accessibilityLabel(tr("关闭"))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(KKColor.surfaceRaised)
                .transition(.movingParts.blur.combined(with: .move(edge: .top)))
            }
            if state.paused {
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
            captionRows

        }
        .background(isIsland || hostedInNotch ? KKColor.notchBackground : Color.clear)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.errorBanner?.text)
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
    private var displayedChunks: [CaptionChunk] {
        let chunks = state.visibleCaptionChunks.filter { !$0.isMarker }
        let limit = isIsland ? CaptionHierarchy.historyLimit(userSize: state.zhFontSize,
            showTranslation: state.showTranslation, showSource: state.showSource,
            banner: state.errorBanner != nil || state.paused) : CaptionHierarchy.maximumHistory
        return Array(chunks.suffix(hasPending ? limit : limit + 1))
    }

    private var captionRows: some View {
        VStack(alignment: .leading, spacing: KKSpace.one) {
            if displayedChunks.isEmpty && !hasPending {
                Text(state.running ? CaptionListeningStatus.text(silentTooLong: state.silentTooLong, audioStalled: state.audioStalled) : state.status)
                    .font(state.captionFont(14)).foregroundStyle(state.silentTooLong ? KKColor.warning : KKColor.textSecondary)
            }
            ForEach(Array(displayedChunks.enumerated()), id: \.element.id) { index, chunk in
                let current = !hasPending && index == displayedChunks.count - 1
                let age = displayedChunks.count - index - (hasPending ? 0 : 1)
                captionRow(chunk, current: current, age: age)
            }
            if hasPending {
                VStack(alignment: .leading, spacing: KKSpace.one) {
                    if state.showTranslation, !state.pendingDraft.isEmpty {
                        Text(state.pendingDraft)
                            .kkCaptionLineHeight(fontSize: 17 * scale, lineHeight: 24 * scale)
                            .font(state.captionFont(CaptionHierarchy.fontSize(current: true, userSize: state.zhFontSize), weight: .medium))
                            .foregroundStyle(KKColor.textPrimary).lineLimit(2)
                    }
                    if state.showSource, !state.pendingEn.isEmpty {
                        Text(state.pendingEn)
                            .kkCaptionLineHeight(fontSize: 13 * scale, lineHeight: 18 * scale)
                            .font(state.captionFont(CaptionHierarchy.sourceSize * scale))
                            .foregroundStyle(KKColor.textSecondary).lineLimit(1).truncationMode(.head)
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(KKColor.brand).frame(width: 2) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, KKSpace.three)
        .padding(.vertical, KKSpace.two)
        .background(KKColor.surfaceBase, in: RoundedRectangle(cornerRadius: KKRadius.md))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kk-caption-text-slab")
        // Layout margins belong outside the opaque, content-sized slab.
        .padding(.horizontal, hostedInNotch || isIsland ? KKSpace.five - hostSideInset : KKSpace.five)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private var scale: Double { state.zhFontSize / 18 }

    private func captionRow(_ chunk: CaptionChunk, current: Bool, age: Int) -> some View {
        VStack(alignment: .leading, spacing: KKSpace.one) {
            if state.showTranslation {
                Text(chunk.zh.isEmpty ? (state.compactCaptions
                    ? (state.translationPaused && !state.showSource ? chunk.en : "…")
                    : (state.translationPaused ? (state.showSource ? "" : chunk.en) : "…")) : chunk.displayTranslation)
                    .kkCaptionLineHeight(fontSize: (current ? 17 : 15) * scale, lineHeight: (current ? 24 : 21) * scale)
                    .font(state.captionFont(CaptionHierarchy.fontSize(current: current, userSize: state.zhFontSize), weight: current ? .medium : .regular))
                    .foregroundStyle(chunk.zh.isEmpty ? KKColor.textTertiary : current ? KKColor.textPrimary : KKColor.historyInk)
                    .opacity(current || chunk.zh.isEmpty ? 1 : max(CaptionOpacityPolicy.minimumHistoryInkOpacity, CaptionHierarchy.opacity(age: age)))
                    .lineLimit(current ? 2 : 1)
            }
            // In bilingual mode only the current sentence has a secondary source line.
            if CaptionHierarchy.showsSource(current: current, showTranslation: state.showTranslation, showSource: state.showSource)
                && (!state.compactCaptions || (state.showTranslation ? !chunk.zh.isEmpty : true)) {
                Text(chunk.displaySource)
                    .kkCaptionLineHeight(fontSize: (state.showTranslation ? 13 : (current ? 17 : 15)) * scale, lineHeight: (state.showTranslation ? 18 : (current ? 24 : 21)) * scale)
                    .font(state.captionFont((state.showTranslation ? CaptionHierarchy.sourceSize : (current ? CaptionHierarchy.currentSize : CaptionHierarchy.historySize)) * scale))
                    .foregroundStyle(state.showTranslation ? KKColor.textSecondary : KKColor.textPrimary)
                    .lineLimit(1).truncationMode(.head)
            }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            if current { Rectangle().fill(KKColor.brand).frame(width: 2) }
        }
        .textSelection(.enabled)
        .contextMenu {
            Button(tr("复制译文")) { copy(chunk.zh) }
            Button(tr("复制原文")) { copy(chunk.en) }
            Divider()
            Button(tr("复制全部译文")) { copyAll() }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
    private func copyAll() {
        copy(state.chunks.filter { !$0.isMarker }.map(\.zh).filter { !$0.isEmpty }.joined(separator: "\n"))
    }
}
