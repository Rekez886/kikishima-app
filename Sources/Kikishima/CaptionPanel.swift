// 悬浮字幕窗：置顶、不抢焦点、全空间可见（能浮在 Zoom 全屏上）、默认不进屏幕共享（sharingType = .none）
import SwiftUI
import AppKit
import QuartzCore
import Translation
import Pow

@MainActor
final class CaptionPanelController: NSObject, NSWindowDelegate {
    static let shared = CaptionPanelController()
    private var panel: NSPanel?

    /// 会议岛走 DynamicNotchKit 引擎（islandEngine != "panel"）；其余形态仍是自己的 NSPanel
    private var notchEngine: Bool { usesIsland && IslandNotchController.enabled }
    var isVisible: Bool { panel?.isVisible == true || (notchEngine && IslandNotchController.shared.visible) }

    func show() {
        if notchEngine { IslandNotchController.shared.show(); return }
        if panel == nil { build() }
        applySharing()
        applyAppearance()
        if usesIsland, !userAdjusted {
            revealed = CaptionState.shared.hasIslandContent
            CaptionState.shared.islandExpanded = revealed
            placing = true
            panel?.setFrame(islandFrame(expanded: revealed), display: false)
            placing = false
        }
        panel?.orderFrontRegardless()
    }

    private var builtIsland = false
    private var revealed = false
    private var usesIsland: Bool { CaptionState.shared.effectiveMode == .meeting && CaptionState.shared.captionSurface == "island" }

    /// 菜单里切「灵动岛 / 桌面窗口」：收掉当前形态，运行中就立刻以新形态摆出来
    func switchSurface() {
        let wasVisible = isVisible
        IslandNotchController.shared.hide()
        panel?.orderOut(nil)
        panel = nil
        guard wasVisible || CaptionState.shared.running else { return }
        show()
        place(for: CaptionState.shared.effectiveMode, force: true)
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
        p.backgroundColor = wantBorderless ? .clear : NSColor(calibratedWhite: 0.06, alpha: s.captionOpacity)
    }

    func hide() {
        if notchEngine { IslandNotchController.shared.hide() }
        guard let p = panel, p.isVisible else { return }
        if usesIsland, revealed, !userAdjusted {
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
        guard usesIsland, panel?.isVisible == true, !userAdjusted else { return }
        let shouldReveal = CaptionState.shared.hasIslandContent
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

    /// 按场景摆位：会议 → 摄像头下方的岛，翻译到了再向下展开；视频 → 贴发声窗口底部
    func place(for mode: EffectiveMode, force: Bool = false) {
        if mode == .meeting, usesIsland, IslandNotchController.enabled {
            if IslandNotchController.shared.visible { IslandNotchController.shared.resizeToContent() }
            return
        }
        if panel == nil { build() }
        guard let p = panel else { return }
        if userAdjusted && !force { return }
        if mode == .meeting, usesIsland {
            revealed = CaptionState.shared.hasIslandContent
            CaptionState.shared.islandExpanded = revealed
            placing = true
            p.setFrame(islandFrame(expanded: revealed), display: true, animate: p.isVisible && revealed)
            placing = false
            return
        }
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

    private func islandScreen() -> NSScreen? {
        let source = AudioSourceWindow.frontWindowFrame(for: CaptionState.micUsers())
        return source.flatMap { s in NSScreen.screens.first { $0.frame.contains(NSPoint(x: s.midX, y: s.midY)) } }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func islandFrame(expanded: Bool) -> NSRect {
        let screen = islandScreen() ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return .zero }
        let vf = screen.visibleFrame
        let left = screen.auxiliaryTopLeftArea ?? .zero
        let right = screen.auxiliaryTopRightArea ?? .zero
        let notch = CaptionIslandLayout.notchWidth(auxiliaryTopLeft: left, auxiliaryTopRight: right)
        let cx = CaptionIslandLayout.centerX(visibleFrame: vf, auxiliaryTopLeft: left, auxiliaryTopRight: right)
        let s = CaptionState.shared
        let rect = expanded
            ? CaptionIslandLayout.expandedRect(visibleFrame: vf, centerX: cx, widthFraction: s.captionWidthFraction, compact: s.compactCaptions)
            : CaptionIslandLayout.idleRect(visibleFrame: vf, centerX: cx, notchWidth: notch)
        return NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    /// 视频模式轮询：发声窗口挪了 / 换了就跟过去（用户手动拖过则不跟）
    func followSourceIfMoved() {
        guard !userAdjusted, panel?.isVisible == true, let src = AudioSourceWindow.current() else { return }
        if let last = lastSourceFrame, abs(last.midX - src.midX) < 20, abs(last.minY - src.minY) < 20, abs(last.width - src.width) < 20 { return }
        place(for: .video, force: true)
    }

    /// 用户明确重置位置（菜单「重置字幕位置」）
    func resetPlacement(mode: EffectiveMode) { userAdjusted = false; place(for: mode, force: true) }

    func windowDidMove(_ notification: Notification) { if !placing { userAdjusted = true } }
    func windowDidResize(_ notification: Notification) { if !placing { userAdjusted = true } }

    private func build() {
        let s = CaptionState.shared
        let island = usesIsland
        let compact = island || s.compactCaptions
        builtIsland = island
        let p = NSPanel(
            contentRect: NSRect(x: 120, y: 80, width: island ? CaptionIslandLayout.idleMinWidth : 780, height: compact ? CaptionIslandLayout.idleHeight : 320),
            styleMask: compact ? [.borderless, .resizable, .nonactivatingPanel] : [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        p.title = tr("字幕")                                   // 不叫 Kikishima：主窗口按 identifier 找，避免撞名
        p.identifier = NSUserInterfaceItemIdentifier("caption-panel")
        p.setFrameAutosaveName(island ? "caption-island" : compact ? "caption-panel-compact" : "caption-panel")
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.sharingType = s.captionsVisibleInScreenShare ? .readOnly : .none   // 屏幕共享 / 录屏里默认不出现（设置里可改）
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        if compact {
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isMovableByWindowBackground = true          // 无标题栏：按住任意处拖
            p.minSize = NSSize(width: 360, height: 90)
            p.ignoresMouseEvents = !island && s.captionClickThrough
        } else {
            p.titlebarAppearsTransparent = true
            p.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: s.captionOpacity)
        }
        p.delegate = self
        p.contentView = NSHostingView(rootView: CaptionFeedView(state: s))
        panel = p
    }

    /// 关闭按钮 = 隐藏字幕窗，字幕继续跑（macOS 惯例：关窗不等于停任务；菜单里「显示字幕窗」随时叫回来）。停止走菜单 / 快捷键 / 主窗
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}

struct CaptionFeedView: View {
    @Bindable var state: CaptionState
    /// 由 DynamicNotchKit 承载：黑底和胶囊态由它画，这里只出内容
    var hostedInNotch = false
    @State private var hovering = false
    @State private var showSettings = false
    private var isIsland: Bool { state.effectiveMode == .meeting && state.captionSurface == "island" }

    /// 悬停出现的小工具条：暂停 / 停止 / 切形态（点击穿透开着时鼠标到不了这里，靠菜单栏）
    private var toolbar: some View {
        HStack(spacing: 6) {
            if state.running {
                Button { state.paused ? state.resume() : state.pause() } label: { Image(systemName: state.paused ? "play.fill" : "pause.fill") }
                    .help(state.paused ? tr("继续字幕") : tr("暂停字幕"))
                    .disabled(state.resuming || state.switchingMeetingLanguage)
                Button { state.stop(); CaptionPanelController.shared.hide() } label: { Image(systemName: "stop.fill") }
                    .help(tr("停止字幕"))
            }
            Button { state.compactCaptions.toggle() } label: { Image(systemName: state.compactCaptions ? "rectangle.expand.vertical" : "rectangle.compress.vertical") }
                .help(tr("紧凑字幕"))
            Button { showSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .help(tr("字幕设置"))
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { IslandSettingsCard(state: state) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.55)))
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
        .overlay(alignment: hostedInNotch ? .bottomTrailing : .topTrailing) { if hovering || showSettings, state.islandExpanded || !isIsland || hostedInNotch { toolbar } }
        .onHover { hovering = $0 }
        .background {
            if !hostedInNotch, isIsland || state.compactCaptions {
                RoundedRectangle(cornerRadius: isIsland && !state.islandExpanded ? 18 : 22, style: .continuous)
                    .fill(Color.black.opacity(state.captionOpacity))
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
                .fill(Color.white.opacity(state.running ? 0.92 : 0.45))
                .frame(width: 22, height: 8)
            if state.running {
                Capsule()
                    .fill(Color.white.opacity(0.35 + state.audioLevel * 0.55))
                    .frame(width: 3, height: 6 + state.audioLevel * 10)
                Capsule()
                    .fill(Color.white.opacity(0.28 + state.audioLevel * 0.5))
                    .frame(width: 3, height: 4 + state.audioLevel * 14)
                Capsule()
                    .fill(Color.white.opacity(0.35 + state.audioLevel * 0.55))
                    .frame(width: 3, height: 6 + state.audioLevel * 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(state.running ? tr("正在听…") : tr("字幕"))
    }

    private var content: some View {
        VStack(spacing: 0) {
            if let banner = state.errorBanner {
                HStack(spacing: 10) {
                    Image(systemName: banner.severity == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundStyle(banner.severity == .error ? .orange : .blue)
                    Text(banner.text).font(.system(size: 13)).foregroundStyle(.white)
                    Spacer()
                    if let action = banner.action {
                        Button(tr(action.title)) { state.performBanner(action) }
                            .controlSize(.small)
                    }
                    Button { state.errorBanner = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.gray)
                        .accessibilityLabel(tr("关闭"))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color(white: 0.16))
                .transition(.movingParts.blur.combined(with: .move(edge: .top)))
            }
            if state.paused {
                HStack(spacing: 10) {
                    Image(systemName: "pause.circle.fill").foregroundStyle(.yellow)
                    Text(tr("已暂停 · 声音不再记录")).font(.system(size: 13)).foregroundStyle(.white)
                    Spacer()
                    Button(tr("继续")) { state.resume() }.controlSize(.small)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color(white: 0.16))
                .transition(.movingParts.blur.combined(with: .move(edge: .top)))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    if state.chunks.isEmpty && state.pendingEn.isEmpty {
                        // 空态 / 加载态：启动中、下载模型、正在听。以前是一块纯黑
                        VStack(spacing: 8) {
                            Image(systemName: state.starting ? "hourglass" : "waveform")
                                .font(.title2).foregroundStyle(Color(white: 0.5))
                            Text(state.running ? tr("正在听…") : state.status)
                                .font(state.captionFont(14)).foregroundStyle(Color(white: 0.62))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 36).padding(.horizontal, 24)
                    } else if state.compactCaptions {
                        // 紧凑模式：只看最近两句，大字（会议里盯着看的形态）。没译文的块回落显示原文，额度用完 / 登出时不再整块空白
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(state.compactCaptionChunks) { chunk in
                                let isLast = chunk.id == state.visibleCaptionChunks.last?.id
                                Group {
                                if chunk.isMarker {
                                    Text(chunk.displaySource).font(state.captionFont(12)).foregroundStyle(Color(white: 0.5))
                                } else {
                                    // 双语：小原文 + 大译文；仅译文：没译文时回落原文；仅原文：只原文
                                    if state.showSource && (state.showTranslation ? !chunk.zh.isEmpty : true) {
                                        Text(chunk.displaySource)
                                            .font(state.captionFont(state.showTranslation ? max(12, state.zhFontSize * 0.55) : state.zhFontSize * 1.05))
                                            .foregroundStyle(Color(white: isLast ? 0.78 : 0.55))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    if state.showTranslation {
                                        // 仅译文时不回落原文；等待 GPT 译文期间显示「…」
                                        Text(chunk.zh.isEmpty ? (state.translationPaused && !state.showSource ? chunk.en : "…") : chunk.displayTranslation)
                                            .font(state.captionFont(state.zhFontSize * 1.15, weight: .medium))
                                            .foregroundStyle(chunk.zh.isEmpty ? Color(white: 0.45) : chunk.isDraft ? Color(white: 0.72) : isLast ? .white : Color(white: 0.7))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                }
                                .transition(.movingParts.move(edge: .bottom).combined(with: .opacity))
                            }
                            // 正在说的这句（未定稿 / 未切块）：原文斜体小字 + 本机翻译的灰色草稿，看起来接近同步
                            if state.showSource, !state.pendingEn.isEmpty {
                                Text(state.pendingEn)
                                    .font(state.captionFont(max(12, state.zhFontSize * 0.55))).italic()
                                    .foregroundStyle(Color(white: 0.5))
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if state.showTranslation, !state.pendingDraft.isEmpty {
                                Text(state.pendingDraft)
                                    .font(state.captionFont(state.zhFontSize * 1.15, weight: .medium)).italic()
                                    .foregroundStyle(Color(white: 0.62))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Color.clear.frame(height: 2).id("bottom")
                        }
                        .padding(16)
                        .animation(.spring(response: 0.4, dampingFraction: 0.88), value: state.visibleCaptionChunks.last?.id)
                    } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        // 只渲染最近 120 块：两小时会议上千块全量 ForEach 会拖慢主线程；完整记录在文件里
                        ForEach(state.visibleCaptionChunks) { chunk in
                            if chunk.isMarker {
                                HStack { Rectangle().fill(Color(white: 0.3)).frame(height: 1); Text(chunk.displaySource).font(state.captionFont(12)).foregroundStyle(Color(white: 0.55)); Rectangle().fill(Color(white: 0.3)).frame(height: 1) }
                                    .padding(.vertical, 4)
                            } else {
                            VStack(alignment: .leading, spacing: 2) {
                                if state.showSource {
                                    Text(chunk.displaySource)
                                        .font(state.captionFont(state.showTranslation ? max(12, state.zhFontSize * 0.55) : state.zhFontSize))
                                        .foregroundStyle(state.showTranslation ? Color(white: 0.68) : .white)
                                }
                                if state.showTranslation {
                                    Text(chunk.zh.isEmpty ? (state.translationPaused ? (state.showSource ? "" : chunk.en) : "…") : chunk.displayTranslation)
                                        .font(state.captionFont(state.zhFontSize, weight: .medium))
                                        .foregroundStyle(chunk.zh.isEmpty ? Color(white: 0.4)
                                                         : chunk.isDraft ? Color(white: 0.72) : .white)
                                }
                            }
                            .textSelection(.enabled)
                            .contextMenu {
                                Button(tr("复制译文")) { copy(chunk.zh) }
                                Button(tr("复制原文")) { copy(chunk.en) }
                                Divider()
                                Button(tr("复制全部译文")) { copyAll() }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if state.showTranslation, !state.pendingDraft.isEmpty {
                            Text(state.pendingDraft)
                                .font(state.captionFont(state.zhFontSize, weight: .medium)).italic()
                                .foregroundStyle(Color(white: 0.62))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if state.showSource, !state.pendingEn.isEmpty {
                            Text(state.pendingEn)
                                .font(state.captionFont(state.showTranslation ? max(12, state.zhFontSize * 0.55) : state.zhFontSize))
                                .italic()
                                .foregroundStyle(Color(white: 0.5))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 8).id("bottom")
                    }
                    .padding(16)
                    }
                }
                .onChange(of: state.chunks.last?.zh) { proxy.scrollTo("bottom") }
                .onChange(of: state.pendingEn) { proxy.scrollTo("bottom") }
            }
        }
        .background(Color.clear)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.errorBanner?.text)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.paused)
        .contextMenu { Button(tr("复制全部译文")) { copyAll() } }   // 紧凑模式与空白处也能右键
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("Kikishima 字幕"))
        .accessibilityAddTraits(.updatesFrequently)
        // Apple 本地机翻草稿：session 只在此闭包内有效，从流里收块、翻完回填
        .translationTask(state.translationConfig) { session in
            // Apple 本地翻译：首次会弹系统下载语言包的框（只一次）；失败就没有草稿，不影响正式译文
            try? await session.prepareTranslation()
            for await (id, text) in state.draftRequests {
                if let r = try? await session.translate(text) {
                    await MainActor.run { state.applyDraft(id, for: text, r.targetText) }
                }
            }
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
