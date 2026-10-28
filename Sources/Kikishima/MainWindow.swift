// 主窗口：左侧栏 + 右内容（Wispr Flow 式），便于后续加功能。视觉归设计轮，这里只定信息架构
import SwiftUI
import AppKit
import Speech
import Carbon.HIToolbox

enum MainSection: String, CaseIterable, Identifiable {
    case captions = "字幕", history = "记录", glossary = "术语表", languages = "语言", settings = "设置", help = "帮助"
    var id: String {
        switch self {
        case .captions: return "captions"
        case .history: return "history"
        case .glossary: return "glossary"
        case .languages: return "languages"
        case .settings: return "settings"
        case .help: return "help"
        }
    }
    var icon: String {
        switch self {
        case .captions: return "captions.bubble"
        case .history: return "clock.arrow.circlepath"
        case .glossary: return "character.book.closed"
        case .languages: return "globe"
        case .settings: return "gearshape"
        case .help: return "questionmark.circle"
        }
    }
}

struct MainWindowView: View {
    @Bindable var state = CaptionState.shared
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            VStack(spacing: 0) {
                SidebarBrandRow()
                SidebarNavigation(selection: $state.mainSection)
                quotaCard.padding(10)
            }
            // Column preferences alone do not constrain native fitting-size measurement.
            // Give wrapped account text a real width so it cannot inflate the split height.
            .frame(minWidth: KKLayout.sidebarMinWidth)
            .navigationSplitViewColumnWidth(min: KKLayout.sidebarMinWidth, ideal: KKLayout.sidebarIdealWidth, max: KKLayout.sidebarMaxWidth)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                // Content chrome, outside NSToolbar's native focus/clip wrapper.
                // Remains available when the sidebar is collapsed.
                HStack(spacing: 12) {
                    KKSidebarToggle(visibility: $sidebarVisibility,
                        showTitle: tr("显示边栏"), hideTitle: tr("隐藏边栏"))
                        .padding(4) // room for the 2pt gap + 2pt ring
                    MainPageTitle(title: tr((state.mainSection ?? .captions).rawValue))
                }
                .padding(.horizontal, KKSpace.six).padding(.top, KKSpace.six).padding(.bottom, KKSpace.four)
                Group {
                    switch state.mainSection ?? .captions {
                    case .captions: CaptionsHome(state: state)
                    case .history: HistoryView()
                    case .glossary:
                        // Keep AX attached to the actual editor, not a virtual replacement editor.
                        VStack(alignment: .leading, spacing: 8) {
                            Text(tr("每行一条。纯词条 = 保留原文（人名、项目名）；「原词 → 译法」= 指定翻译。"))
                                .font(.caption).foregroundStyle(KKColor.textSecondary)
                            if state.translationEngine == .apple {
                                Text(tr("Apple 本机翻译暂时不使用术语表；需要固定译法请切换到 OpenAI Key。"))
                                    .font(.caption).foregroundStyle(KKColor.warning)
                            }
                            TextEditor(text: $state.glossary).kkFocusRing().kkTabNavigation()
                                .font(.system(size: 13, design: .monospaced))
                                .accessibilityLabel(tr("术语表"))
                                .accessibilityHint(tr("每行一条。纯词条 = 保留原文（人名、项目名）；「原词 → 译法」= 指定翻译。"))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(KKColor.textTertiary.opacity(0.3)))
                            let lines = state.glossary.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
                            Text(tr("%@ / 80 条 · %@ / 4000 字", lines, state.glossary.count))
                                .font(.caption)
                                .foregroundStyle(lines > 80 || state.glossary.count > 4000 ? KKColor.warning : KKColor.textSecondary)
                        }
                        .padding(12).padding(.horizontal, 20)
                    case .languages: LanguagesView(state: state)
                    case .settings: SettingsPane(state: state)
                    case .help: HelpView()
                    }
                }
                .kkKeyboardPage("main-" + (state.mainSection ?? .captions).id)
                .id(state.mainSection ?? .captions)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: KKLayout.detailMaxWidth, maxHeight: .infinity, alignment: .topLeading)
            .frame(minWidth: KKLayout.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Text actions use brand ink; the native window toolbar keeps its own style.
            .buttonStyle(KKQuietButtonStyle())
        }
        .kkNeutralControls()
        .frame(minWidth: KKLayout.mainWindowMinSize.width, minHeight: KKLayout.mainWindowMinSize.height)
    }

    private var quotaCard: some View {
        SidebarEngineCard(
            engine: state.translationEngine,
            hasOpenAIKey: state.hasOpenAIKey,
            keyHint: state.openAIKeyHint,
            openSettings: { state.mainSection = .settings }
        )
    }

}

// MARK: - 字幕（首页）

struct CaptionsHome: View {
    @Bindable var state: CaptionState
    @State private var allLocales: [String] = []
    /// 首页下拉：常用会议语言在前，其余按字母；当前值不在列表也补上
    private var homeLocales: [String] {
        var list = state.meetingLocales
        for id in allLocales where !list.contains(id) { list.append(id) }
        if !list.contains(state.localeID) { list.insert(state.localeID, at: 0) }
        return list
    }

    private var previewRows: [CaptionRowText] {
        let chunks = state.compactCaptionChunks.filter { !$0.isMarker }
        let active = state.running || state.starting || state.finishingCaptions
        let latest = chunks.last.flatMap { chunk in
            chunk.zh.isEmpty && (chunk.translationExhausted || state.translationPaused || chunk.captionFinalized || !active)
                ? chunk.id : chunks.last(where: { CaptionReadingPolicy.isReadable($0.zh, isDraft: $0.isDraft) })?.id
        }
        var rows = chunks.map { chunk in
            CaptionHierarchy.row(source: chunk.displaySource, translation: chunk.displayTranslation,
                waiting: !chunk.translationExhausted && !state.translationPaused && !chunk.captionFinalized && active,
                current: chunk.id == latest, showTranslation: state.showTranslation, showSource: state.showSource)
        }
        if !state.pendingEn.isEmpty || !state.pendingDraft.isEmpty {
            rows.append(CaptionHierarchy.row(source: state.pendingEn, translation: state.pendingDraft,
                waiting: !state.translationPaused && active, current: true,
                showTranslation: state.showTranslation, showSource: state.showSource))
        }
        return rows
    }
    private var previewSource: String {
        state.running || state.starting || state.finishingCaptions ? "" : "Let's review the next steps together."
    }
    private var previewTranslation: String {
        state.running || state.starting || state.finishingCaptions ? "" : HomeCaptionPreview.sampleTranslation(for: state.targetLang)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(state.status).font(.system(size: KKLayout.bodyFontSize))
                        .foregroundStyle(state.silentTooLong ? KKColor.warning : KKColor.textSecondary)
                        .accessibilityIdentifier("kk-main-listening-status")
                }

                HomeCaptionPreview(
                    source: previewSource, translation: previewTranslation, rows: previewRows, status: state.status,
                    warning: state.silentTooLong,
                    compact: state.compactCaptions, display: state.captionDisplay,
                    desktop: state.captionSurface == "window", statusPresentedExternally: true, isExample: !state.running && !state.starting && !state.finishingCaptions)

                VStack(alignment: .leading, spacing: 8) {
                HomeCaptionControls(active: state.running || state.starting, running: state.running,
                    paused: state.paused, transition: state.switchingMeetingLanguage || state.resuming,
                    compact: $state.compactCaptions, display: $state.captionDisplay,
                    toggle: { state.toggle() }, pause: { state.paused ? state.resume() : state.pause() })
                    // Expose the controls that actually receive keyboard focus,
                    // rather than a separate virtual VStack of replacement controls.
                    .accessibilityElement(children: .contain)
                    .disabled(state.finishingCaptions)
                Text(tr("快捷键 %@", GlobalHotkey.displayText))
                    .font(.caption).foregroundStyle(KKColor.textSecondary)
                }

                Divider()
                // 语言：首页直接可选；会中选择会重启转写引擎，但保留同一场会议
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tr("会议语言")).font(.caption).foregroundStyle(KKColor.textSecondary)
                            Picker(tr("会议语言"), selection: Binding(
                                get: { state.localeID },
                                set: { state.selectMeetingLanguage($0) }
                            )) {
                                ForEach(homeLocales, id: \.self) { id in
                                    Text(localeName(id) + (state.modelReady(id) ? "" : " · " + tr("需下载"))).tag(id)
                                }
                            }.kkFocusRing().buttonStyle(.automatic)
                            .labelsHidden().frame(maxWidth: KKLayout.pickerMaxWidth)
                            .disabled(state.starting || state.switchingMeetingLanguage || state.resuming)
                        }
                        Image(systemName: "arrow.right").foregroundStyle(KKColor.textTertiary).padding(.top, 14)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tr("译文语言")).font(.caption).foregroundStyle(KKColor.textSecondary)
                            Picker(tr("译文语言"), selection: $state.targetLang) {
                                ForEach(targetLanguages, id: \.prompt) { lang in Text(lang.display).tag(lang.prompt) }
                            }.kkFocusRing().buttonStyle(.automatic)
                            .labelsHidden().frame(maxWidth: KKLayout.pickerMaxWidth)
                            .disabled(state.running || state.starting || state.switchingMeetingLanguage)
                            .overlay {
                                if state.running || state.starting || state.switchingMeetingLanguage {
                                    DisabledPickerOverlay(text: targetLanguages.first(where: { $0.prompt == state.targetLang })?.display ?? state.targetLang)
                                }
                            }
                        }
                    }
                    Button { state.mainSection = .languages } label: { Text(tr("更多语言…")) }
                        .buttonStyle(KKLinkButtonStyle())
                }
                .task {
#if SHOOT || DEBUG
                    if ShootSimulation.requestedMode != nil { allLocales = state.meetingLocales; return }
#endif
                    await state.refreshModelInstallation()
                    allLocales = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
                }

                CalendarMeetingCard(coordinator: state.calendarCoordinator,
                                    isRunning: state.running || state.starting)

                if state.summaryConsent == .undecided {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(tr("Kikishima 可以在会议中持续整理要点，并在停止字幕后生成最终总结。"))
                            Text(tr("音频不会上传。会议文字和称呼只在本机用于生成会议总结；选择 OpenAI Key 时会直接发送给 OpenAI，不经过 Kikishima。关闭会议总结不会关闭本机会议记录。"))
                                .font(.caption)
                                .foregroundStyle(KKColor.textSecondary)
                            HStack {
                                Button(tr("生成会议总结")) { state.setMeetingSummariesEnabled(true) }
                                    .kkPrimaryButton()
                                Button(tr("暂不使用")) { state.setMeetingSummariesEnabled(false) }
                            }
                        }
                        .padding(6)
                    } label: {
                        Label(tr("会议总结"), systemImage: "list.bullet.clipboard")
                    }
                }

                // 最近记录
                RecentTranscripts(limit: 2)
            }
            .frame(maxWidth: KKLayout.homeContentMaxWidth, alignment: .leading)
            .padding(.horizontal, KKSpace.eight).padding(.bottom, KKSpace.eight)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

/// A native segmented Picker exposes both its group name and selected item to VO.
struct CaptionSegmentAccessibility<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(String, Value)]
    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options.indices, id: \.self) { index in
                Text(options[index].0).tag(options[index].1)
                    .accessibilityLabel(title + ", " + options[index].0)
            }
        }
        .pickerStyle(.segmented)
        .buttonStyle(.automatic)
        .accessibilityLabel(title)
        .accessibilityValue(options.first(where: { $0.1 == selection })?.0 ?? "")
    }
}

/// Segmented picker plus its native AX representation, one options list for both.
struct KKSegmentedPickerAX<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(String, Value)]
    var body: some View {
        KKSegmentedPicker(title: title, selection: $selection, options: options)
            .accessibilityRepresentation {
                CaptionSegmentAccessibility(title: title, selection: $selection, options: options)
            }
    }
}

/// Size level picker plus its native AX representation, one label pair for both.
struct CaptionSizeLevelPickerAX: View {
    let title: String
    @Binding var level: String
    let low: String
    let high: String
    var body: some View {
        CaptionSizeLevelPicker(title: title, level: $level, low: low, high: high)
            .accessibilityRepresentation {
                CaptionSegmentAccessibility(title: title, selection: $level,
                    options: [(tr(low), "small"), (tr("中"), "medium"), (tr(high), "large")])
            }
    }
}

/// Covers a disabled Picker with its current value so it stays readable.
private struct DisabledPickerOverlay: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: KKLayout.bodyFontSize)).foregroundStyle(KKColor.textTertiary.opacity(0.9))
            .frame(maxWidth: .infinity, minHeight: 24)
            .background(KKColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 5))
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// No native List selection background: selection stays gray regardless of focus.
struct SidebarNavigation: View {
    @Binding var selection: MainSection?
    @FocusState private var focused: MainSection?
    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(MainSection.allCases) { section in
                    Button { selection = section } label: {
                        Label(tr(section.rawValue), systemImage: section.icon)
                            .foregroundStyle(KKColor.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(selection == section ? KKColor.surfaceSelected : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(KKPlainButtonStyle())
                    .focused($focused, equals: section)
                    .accessibilityLabel(tr(section.rawValue))
                    .accessibilityAddTraits(selection == section ? .isSelected : [])
                }
            }.padding(8)
        }
        .onMoveCommand { direction in
            let sections = MainSection.allCases
            let index = sections.firstIndex(of: focused ?? selection ?? .captions) ?? 0
            let next: Int
            switch direction {
            case .up: next = max(0, index - 1)
            case .down: next = min(sections.count - 1, index + 1)
            default: return
            }
            selection = sections[next]
            focused = sections[next]
        }
    }
}

/// Determinate grayscale progress with enough width to be useful at any scale.
struct ModelDownloadProgress: View {
    let progress: Double
    private var fraction: Double { progress.isFinite ? min(1, max(0, progress)) : 0 }
    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geometry in
                Capsule().fill(KKColor.surfaceRaised)
                    .overlay(alignment: .leading) {
                        Capsule().fill(KKColor.textPrimary)
                            .frame(width: geometry.size.width * fraction)
                    }
            }.frame(minWidth: 80, idealWidth: 88, maxWidth: 100, minHeight: 6, maxHeight: 6)
            Text("\(Int(fraction * 100))%")
                .font(.caption).monospacedDigit().foregroundStyle(KKColor.textPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("下载中 %@%", Int(fraction * 100)))
        .accessibilityValue("\(Int(fraction * 100))%")
    }
}

// MARK: - 记录

struct TranscriptFile: Identifiable, Hashable, Sendable {
    let url: URL
    var id: URL { url }
    // UTF-8 hex is deterministic and collision-free, even for localized filenames.
    var accessibilityID: String { "kk-transcript-row-" + url.absoluteString.utf8.map { String(format: "%02x", $0) }.joined() }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var date: Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
}

func loadTranscripts() -> [TranscriptFile] {
    let dir = CaptionState.transcriptDir
    let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    return urls.filter { $0.pathExtension == "md" }.map(TranscriptFile.init).sorted { $0.date > $1.date }
}

struct RecentTranscripts: View {
    @Bindable private var state = CaptionState.shared
    var limit: Int
    @State private var files: [TranscriptFile] = []
    var body: some View {
        GroupBox {
            if files.isEmpty {
                Text(tr("还没有会议记录。停止字幕时会自动保存到「%@」。", transcriptDisplayPath(CaptionState.transcriptDir, homeDirectory: FileManager.default.homeDirectoryForCurrentUser))).font(.caption).foregroundStyle(KKColor.textSecondary).padding(6)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(files.prefix(limit)) { f in
                        HStack {
                            Text(f.name).lineLimit(1)
                            Spacer()
                            Text(f.date, style: .relative).font(.caption).foregroundStyle(KKColor.textTertiary)
                            Button(tr("打开")) { NSWorkspace.shared.open(f.url) }.controlSize(.small)
                        }
                    }
                }
                .padding(6)
            }
        } label: { Label(tr("最近记录"), systemImage: "clock.arrow.circlepath") }
        .task(id: state.transcriptDiskRevision) {
            let loaded = await Task.detached(priority: .utility) { loadTranscripts() }.value
            guard !Task.isCancelled else { return }
            files = loaded
        }
    }
}

/// One native list stop. Rows and their mouse-only trash buttons add no key views.
/// Observe only this window's normal update notifications, never AX or an event monitor.
private struct TranscriptListSelectionAppearance: NSViewRepresentable {
    var label: String
    var focusChanged: (Bool) -> Void
    final class SelectionView: NSView {
        weak var table: NSTableView?
        var label = ""
        var focusChanged: (Bool) -> Void = { _ in }
        private var observer: NSObjectProtocol?
        private var active = false
        private var pending = false
        private var retired = false
        override var acceptsFirstResponder: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func applyAppearance() {
            guard !retired else { return }
            if table == nil {
                func findTable(_ view: NSView) -> NSTableView? {
                    if let table = view as? NSTableView { return table }
                    for child in view.subviews { if let table = findTable(child) { return table } }
                    return nil
                }
                var ancestor = superview
                while let view = ancestor {
                    if let found = findTable(view) { table = found; break }
                    ancestor = view.superview
                }
            }
            guard let table else { return }
            table.selectionHighlightStyle = .none
            table.focusRingType = .none
            table.setAccessibilityLabel(label)
            table.setAccessibilityIdentifier("kk-transcript-list")
            let focused = window?.isKeyWindow == true && window?.firstResponder === table
            guard active != focused else { return }
            active = focused
            // A state update cannot synchronously re-enter SwiftUI layout.
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.retired else { return }
                self.pending = false
                self.focusChanged(self.active)
            }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            if let window {
                observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification,
                    object: window, queue: .main) { [weak self] _ in self?.applyAppearance() }
            }
            applyAppearance()
        }
        override func layout() { super.layout(); applyAppearance() }
        func retire() {
            retired = true
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
    func makeNSView(context: Context) -> SelectionView { SelectionView() }
    func updateNSView(_ view: SelectionView, context: Context) {
        view.label = label; view.focusChanged = focusChanged; view.applyAppearance()
    }
    static func dismantleNSView(_ view: SelectionView, coordinator: ()) { view.retire() }
}

/// Keep the existing hover trash action accessible to AX/mouse, without an extra Tab stop.
/// Keyboard users delete the native list selection with Delete or its context menu.
private struct TranscriptTrashButton: NSViewRepresentable {
    var action: () -> Void
    final class ActionButton: NSButton {
        var perform: () -> Void = {}
        @objc func invoke() { perform() }
        override var acceptsFirstResponder: Bool { false }
    }
    func makeNSView(context: Context) -> ActionButton {
        let button = ActionButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: nil)!, target: nil, action: nil)
        button.target = button; button.action = #selector(ActionButton.invoke)
        button.isBordered = false; button.refusesFirstResponder = true; button.focusRingType = .none
        button.contentTintColor = NSColor(KKColor.error)
        return button
    }
    func updateNSView(_ button: ActionButton, context: Context) {
        button.perform = action; button.toolTip = tr("删除"); button.setAccessibilityLabel(tr("删除"))
    }
}

private struct TranscriptRow: View {
    let file: TranscriptFile
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(file.name).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(KKColor.textPrimary)
                    .lineLimit(2).help(file.name)
                Text(file.date, style: .date).font(.system(size: 10)).foregroundStyle(KKColor.textSecondary)
            }
            Spacer(minLength: 0)
            TranscriptTrashButton(action: onDelete)
                .frame(width: 20, height: 20)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
        }
        .onHover { hovering = $0 }
    }
}

struct HistoryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable private var state = CaptionState.shared
    @State private var files: [TranscriptFile] = []
    @State private var query = ""
    @State private var listFocused = false
    @State private var previewSelection: TranscriptFile.ID?
    @State private var selection: Set<TranscriptFile.ID> = []
    @State private var pendingDeletions: [TranscriptFile] = []
    @State private var showingDeletionConfirmation = false
    @State private var contents: [URL: String] = [:]
    @State private var incompleteTranslations: [URL: Int] = [:]
    @State private var summaries: [URL: MeetingSummaryDocument] = [:]
    @State private var retryableSummaryURLs: Set<URL> = []
    @State private var unreadableSummaryCount = 0
    @State private var operationError: String?
    @State private var reloadGeneration = 0
    private let summaryStore = MeetingSummaryStore()

    private var shown: [TranscriptFile] {
        files.filter { file in
            MeetingSummarySearch.matches(
                query: query,
                title: file.name,
                transcriptText: contents[file.url] ?? "",
                summary: summaries[file.url]
            )
        }
    }

    /// 重命名：系统 alert 里一个输入框，改的是文件名（不含 .md）
    private func rename(_ f: TranscriptFile) {
        guard !state.transcriptIsBusy(f.url) else { return }
        let alert = NSAlert()
        alert.messageText = tr("重命名记录")
        alert.addButton(withTitle: tr("好")); alert.addButton(withTitle: tr("取消"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = f.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard !state.transcriptIsBusy(f.url) else { return }
        let newName = field.stringValue.replacingOccurrences(of: "[/:\\\\\n\r\t]", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != f.name else { return }
        let dest = f.url.deletingLastPathComponent().appendingPathComponent(newName + ".md")
        Task {
            do {
                try await summaryStore.renameRecord(from: f.url, to: dest)
                await reload()
                previewSelection = dest
                selection = [dest]
            } catch {
                operationError = error.localizedDescription
                await reload()
            }
        }
    }

    private var selectedFiles: [TranscriptFile] {
        files.filter { selection.contains($0.id) }
    }

    private func requestDeletion(_ files: [TranscriptFile]) {
        guard !files.isEmpty, !files.contains(where: { state.transcriptIsBusy($0.url) }) else { return }
        pendingDeletions = files
        showingDeletionConfirmation = true
    }

    private func delete(_ files: [TranscriptFile]) {
        guard !files.contains(where: { state.transcriptIsBusy($0.url) }) else { return }
        Task {
            let result = await summaryStore.trashRecords(at: files.map(\.url))
            for url in result.succeeded {
                contents.removeValue(forKey: url)
                summaries.removeValue(forKey: url)
                if previewSelection == url { previewSelection = nil }
                selection.remove(url)
            }
            if !result.failures.isEmpty {
                let names = result.failures.map { $0.url.lastPathComponent }.joined(separator: "\n")
                operationError = tr("以下记录无法删除：\n%@", names)
            }
            await reload()
        }
    }

    private func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let loadedFiles = await Task.detached(priority: .utility) { loadTranscripts() }.value
        guard generation == reloadGeneration else { return }
        var loadedContents: [URL: String] = [:]
        var loadedIncomplete: [URL: Int] = [:]
        var loadedSummaries: [URL: MeetingSummaryDocument] = [:]
        var loadedRetryableURLs: Set<URL> = []
        for file in loadedFiles {
            let loaded = await Task.detached(priority: .utility) {
                let markdown = (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
                let recovery = TranscriptRecovery.decode(markdown)
                return (body: recovery?.body ?? markdown, incomplete: recovery?.incompleteCount)
            }.value
            guard generation == reloadGeneration else { return }
            loadedContents[file.url] = loaded.body
            loadedIncomplete[file.url] = loaded.incomplete
            if let document = try? await summaryStore.load(for: file.url) {
                let currentFingerprint = await Task.detached(priority: .utility) {
                    try? MeetingSummaryStore.sha256(of: file.url)
                }.value
                guard generation == reloadGeneration else { return }
                if MeetingSummaryRetryPolicy.canRetry(
                    status: document.status,
                    hasSourceIndex: !document.sourceIndex.isEmpty,
                    fingerprintMatches: document.sourceFingerprint != nil && document.sourceFingerprint == currentFingerprint
                ) {
                    loadedRetryableURLs.insert(file.url)
                }
                if let liveDocument = state.meetingSummarySnapshot?.document,
                   liveDocument.recordID == document.recordID {
                    loadedSummaries[file.url] = liveDocument
                } else {
                    loadedSummaries[file.url] = document
                }
            }
        }
        guard generation == reloadGeneration else { return }
        files = loadedFiles
        contents = loadedContents
        incompleteTranslations = loadedIncomplete
        summaries = loadedSummaries
        retryableSummaryURLs = loadedRetryableURLs
        unreadableSummaryCount = await summaryStore.unreadableSummaryCount()
        selection.formIntersection(Set(loadedFiles.map(\.id)))
        if let previewSelection, loadedFiles.contains(where: { $0.id == previewSelection }) { return }
        previewSelection = loadedFiles.first(where: { selection.contains($0.id) })?.id
        if selection.isEmpty, let first = shown.first {
            previewSelection = first.id
            selection = [first.id]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer()
                Button(role: .destructive) {
                    requestDeletion(selectedFiles)
                } label: {
                    Label(tr("删除所选"), systemImage: "trash")
                        .foregroundStyle(KKColor.textPrimary)
                }
                .buttonStyle(KKQuietButtonStyle())
                .disabled(selectedFiles.isEmpty || selectedFiles.contains(where: { state.transcriptIsBusy($0.url) }))
                Button(tr("打开文件夹")) {
                    try? FileManager.default.createDirectory(at: CaptionState.transcriptDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(CaptionState.transcriptDir)
                }.buttonStyle(KKQuietButtonStyle()).foregroundStyle(KKColor.textPrimary)
            }
            TextField(tr("搜索标题或内容"), text: $query, prompt: Text(tr("搜索标题或内容")).foregroundStyle(KKColor.textSecondary)).kkFocusRing().textFieldStyle(.roundedBorder).frame(maxWidth: 320).accessibilityLabel(tr("搜索标题或内容"))
            if unreadableSummaryCount > 0 {
                Label(tr("有 %@ 份会议总结无法读取，可能已损坏。", unreadableSummaryCount),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(KKColor.warning)
                    .accessibilityIdentifier("kk-summary-corrupt-warning")
            }
            if files.isEmpty {
                ContentUnavailableView(tr("还没有会议记录"), systemImage: "doc.text", description: Text(tr("停止字幕时会自动保存到「%@」。", transcriptDisplayPath(CaptionState.transcriptDir, homeDirectory: FileManager.default.homeDirectoryForCurrentUser))))
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                HSplitView {
                    // 双击打开、右键更多；删除做成悬停可见入口，避免功能藏得太深
                    List(shown, selection: $selection) { f in
                        TranscriptRow(file: f) { requestDeletion([f]) }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier(f.accessibilityID)
                            .accessibilityLabel(f.name)
                            .tag(f.id)
                            .listRowBackground(
                                KKColor.surfaceRaised.overlay {
                                    if selection.contains(f.id) {
                                        // 7% black gives only 4.24:1; 4% preserves 4.53:1 for dates.
                                        KKColor.surfaceSelected.opacity(colorScheme == .dark ? 1 : 4.0 / 7.0)
                                    }
                                }
                            )
                            .contentShape(Rectangle())
                    }
                    .contextMenu(forSelectionType: TranscriptFile.ID.self) { ids in
                        let targets = shown.filter { ids.contains($0.id) }
                        if let file = targets.first, targets.count == 1 {
                            Button(tr("打开")) { NSWorkspace.shared.open(file.url) }
                            Button(tr("在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                            Button(tr("重命名…")) { rename(file) }.disabled(state.transcriptIsBusy(file.url))
                            Divider()
                        }
                        if !targets.isEmpty {
                            Button(tr("删除"), role: .destructive) { requestDeletion(targets) }
                                .disabled(targets.contains(where: { state.transcriptIsBusy($0.url) }))
                        }
                    } primaryAction: { ids in
                        for file in shown where ids.contains(file.id) {
                            NSWorkspace.shared.open(file.url)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(KKColor.surfaceRaised)
                    .frame(minWidth: 160, idealWidth: 196, maxWidth: 260)
                    .accessibilityLabel(tr("记录列表"))
                    .accessibilityIdentifier("kk-transcript-list")
                    .background(TranscriptListSelectionAppearance(label: tr("记录列表")) { listFocused = $0 })
                    .overlay { KKFocusOutline(active: listFocused, radius: 6) }
                    .padding(4) // keep the 2pt gap + 2pt ring outside the scrolling clip
                    .onDeleteCommand { requestDeletion(selectedFiles) }

                    if let selected = files.first(where: { $0.id == previewSelection }) {
                        VStack(alignment: .leading, spacing: 8) {
                            if let count = incompleteTranslations[selected.url], count > 0 {
                                Text(tr("还有 %@ 段译文未完成，原文已保留。", count))
                                    .foregroundStyle(KKColor.textSecondary)
                                Button(tr("重试未完成字幕")) { state.retryTranscript(at: selected.url) }
                                    .buttonStyle(KKQuietButtonStyle())
                                    .foregroundStyle(KKColor.textPrimary)
                                    .disabled(!state.canRetryTranscript(at: selected.url))
                            }
                            if state.transcriptRetryMessageURL == selected.url, let message = state.transcriptRetryMessage {
                                Text(message).font(.caption).foregroundStyle(KKColor.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            MeetingSummaryDetailView(
                                transcript: selected,
                                document: summaries[selected.url],
                                canRetry: retryableSummaryURLs.contains(selected.url)
                                    && state.canRetryMeetingSummary(recordID: summaries[selected.url]?.recordID),
                                onRetry: {
                                    if let document = summaries[selected.url] {
                                        state.retryMeetingSummary(document: document, transcriptURL: selected.url)
                                    }
                                }
                            )
                            .id(selected.id)
                        }
                        .frame(minWidth: 280, maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, KKSpace.eight).padding(.bottom, KKSpace.eight)
        .task { await reload() }
        .onChange(of: state.meetingSummarySnapshot) { Task { await reload() } }
        .onChange(of: state.summaryDiskRevision) { Task { await reload() } }
        .onChange(of: state.transcriptDiskRevision) { Task { await reload() } }
        .onChange(of: selection) { oldSelection, newSelection in
            previewSelection = HistoryPreview.selectedID(
                previous: previewSelection, oldSelection: oldSelection,
                selection: newSelection, orderedIDs: shown.map(\.id)
            )
        }
        .onChange(of: query) {
            selection.formIntersection(Set(shown.map(\.id)))
            previewSelection = HistoryPreview.selectedID(
                previous: previewSelection, oldSelection: selection,
                selection: selection, orderedIDs: shown.map(\.id)
            )
        }
        .alert(
            pendingDeletions.count == 1
                ? tr("删除这条会议记录？")
                : tr("删除所选的 %@ 条会议记录？", pendingDeletions.count),
            isPresented: $showingDeletionConfirmation
        ) {
            Button(tr("删除"), role: .destructive) { delete(pendingDeletions) }
            Button(tr("取消"), role: .cancel) {}
        } message: {
            Text(tr("删除后会移到废纸篓，可以恢复。"))
        }
        .alert(tr("无法修改记录"), isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button(tr("好")) { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
    }
}

// MARK: - 语言

struct LanguagesView: View {
    @Bindable var state: CaptionState
    @State private var sourceLocales: [Locale] = []
    @State private var showingLanguageRelaunchPrompt = false
    var body: some View {
        Form {
            LabeledContent(tr("界面语言")) {
                Picker("", selection: $state.uiLanguage) {
                    ForEach(UILang.all) { l in Text(l.native).tag(l.code) }
                }
                .labelsHidden()
                .accessibilityLabel(tr("界面语言"))
                .kkFocusRing()
                .buttonStyle(.automatic)
                .onChange(of: state.uiLanguage) {
                    showingLanguageRelaunchPrompt = AppLanguagePreference.requiresRelaunch(for: state.uiLanguage)
                }
            }
            .alert(tr("重新启动以完成语言切换"), isPresented: $showingLanguageRelaunchPrompt) {
                if state.running || state.starting {
                    Button(tr("好")) {}
                } else {
                    Button(tr("立即重新启动")) { AppRelauncher.restart() }
                    Button(tr("稍后"), role: .cancel) {}
                }
            } message: {
                if state.running || state.starting {
                    Text(tr("字幕运行中。为避免中断，系统界面会在下次启动 Kikishima 时切换语言。"))
                } else {
                    Text(tr("系统界面需要重新启动 Kikishima 才能切换语言。"))
                }
            }
            Section(tr("常用会议语言")) {
                Toggle(tr("选了就下载模型（建议在 Wi-Fi 下）"), isOn: $state.autoDownloadModels).toggleStyle(KKSwitchToggleStyle())
                if state.meetingLocales.isEmpty {
                    Text(tr("还没选。开始字幕时会按需下载当前会议语言的模型。")).font(.caption).foregroundStyle(KKColor.textSecondary)
                } else {
                    ForEach(state.meetingLocales, id: \.self) { id in
                        HStack {
                            HStack {
                                Text(localeName(id))
                                Spacer()
                                if state.modelReady(id) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(KKColor.textSecondary)
                                        .accessibilityLabel(tr("模型已安装"))
                                } else if let p = state.modelProgress[id], p < 1 {
                                    ModelDownloadProgress(progress: p)
                                } else {
                                    Text(tr("需下载")).foregroundStyle(KKColor.textSecondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(localeName(id))
                            .accessibilityValue(state.modelReady(id) ? tr("已安装") : state.modelProgress[id].map { tr("下载中 %@%", Int($0 * 100)) } ?? tr("需下载"))
                            Button { state.removeMeetingLocale(id) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(KKPlainButtonStyle())
                                .accessibilityLabel(tr("删除 %@", localeName(id)))
                        }
                        .accessibilityElement(children: .contain)
                    }
                }
                Menu(tr("添加会议语言")) {
                    ForEach(sourceLocales.filter { !state.meetingLocales.contains($0.identifier) }, id: \.identifier) { loc in
                        Button(localeName(loc.identifier)) { state.meetingLocales.append(loc.identifier); state.predownloadModels([loc.identifier]) }
                    }
                }.kkFocusRing().buttonStyle(.automatic)
            }
            Picker(tr("会议语言（转写）"), selection: Binding(
                get: { state.localeID },
                set: { state.selectMeetingLanguage($0) }
            )) {
                if sourceLocales.isEmpty {
                    Text(tr("英语")).tag("en_US")
                    Text(tr("日语")).tag("ja_JP")
                } else {
                    ForEach(sourceLocales, id: \.identifier) { loc in
                        Text(localeName(loc.identifier) + (state.modelReady(loc.identifier) ? "" : " · " + tr("需下载"))).tag(loc.identifier)
                    }
                }
            }.kkFocusRing().buttonStyle(.automatic)
            .disabled(state.starting || state.switchingMeetingLanguage || state.resuming)
            Picker(tr("译文语言"), selection: $state.targetLang) {
                ForEach(targetLanguages, id: \.prompt) { lang in Text(lang.display).tag(lang.prompt) }
            }.kkFocusRing().buttonStyle(.automatic)
            .disabled(state.running || state.starting || state.switchingMeetingLanguage)
            .overlay {
                if state.running || state.starting || state.switchingMeetingLanguage {
                    DisabledPickerOverlay(text: targetLanguages.first(where: { $0.prompt == state.targetLang })?.display ?? state.targetLang)
                }
            }
            LabeledContent(tr("译文字号")) {
                CaptionSizeLevelPickerAX(title: tr("译文字号"), level: $state.captionFontLevel, low: "小", high: "大")
            }
        }
        .formStyle(.grouped)
        .task {
            await state.refreshModelInstallation()
            let locales = await SpeechTranscriber.supportedLocales
            sourceLocales = locales.sorted { localeName($0.identifier) < localeName($1.identifier) }
        }
    }
}

// MARK: - 设置（翻译引擎 + 快捷键 + 常规）

struct SettingsPane: View {
    @ObservedObject private var captionPanel = CaptionPanelController.shared
    @Bindable var state: CaptionState
    @State private var launchAtLogin = LaunchAtLoginController.live()
    @State private var hotkeyTick = 0   // 强制刷新快捷键显示
    @State private var openAIKeyInput = ""
    @State private var openAIKeySaveFailed = false
    @State private var mlx = MLXModelController.shared

    private func captionSetting<Content: View>(_ title: String, value: String,
                                               @ViewBuilder content: () -> Content) -> some View {
        LabeledContent { content() } label: {
            Text(title).foregroundStyle(KKColor.textPrimary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private func sizeLabel(_ level: String, low: String, high: String) -> String {
        tr(level == CaptionSizeLevel.small.rawValue ? low : level == CaptionSizeLevel.large.rawValue ? high : "中")
    }

        var body: some View {
        Form {
            translationEngineSection
            hotkeySection
            calendarSection
            summarySection
            captionSection
            generalSection
        }
        .formStyle(.grouped)
        .background(SettingsFocusAutoScroller())
        .font(.system(size: KKLayout.bodyFontSize))
        .alert(tr("无法更改登录启动设置"), isPresented: Binding(
            get: { launchAtLogin.errorMessage != nil },
            set: { if !$0 { launchAtLogin.dismissError() } }
        )) {
            Button(tr("好")) { launchAtLogin.dismissError() }
        } message: {
            Text(launchAtLogin.errorMessage ?? "")
        }

    }

    @ViewBuilder
    private var translationEngineSection: some View {
        Section(tr("翻译引擎")) {
            KKSegmentedPickerAX(
                title: tr("翻译引擎"),
                selection: Binding(
                    get: { state.translationEngine.rawValue },
                    set: { state.selectTranslationEngine(TranslationEnginePolicy.Engine(rawValue: $0) ?? .apple) }
                ),
                options: [
                    (tr("Apple 本机翻译"), TranslationEnginePolicy.Engine.apple.rawValue),
                    (tr("高质量本机（MLX）"), TranslationEnginePolicy.Engine.mlx.rawValue),
                    (tr("自带 OpenAI Key"), TranslationEnginePolicy.Engine.openAI.rawValue),
                ]
            )
            .accessibilityIdentifier("kk-settings-engine")
            if state.translationEngine == .mlx {
                Text(tr("%@ · %@", MLXModelController.modelName, MLXModelController.downloadSizeLabel))
                    .font(.caption).foregroundStyle(KKColor.textSecondary)
                switch mlx.state {
                case .ready:
                    Label(tr("模型已就绪"), systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(KKColor.textSecondary)
                case .downloading(let progress):
                    ProgressView(value: progress).controlSize(.small)
                    Text(tr("下载中 %@%", Int(progress * 100)))
                        .font(.caption).foregroundStyle(KKColor.textSecondary)
                case .loading:
                    ProgressView(tr("正在加载模型…")).controlSize(.small)
                case .failed(let message):
                    Text(tr("模型加载失败：%@", message)).font(.caption).foregroundStyle(KKColor.error)
                case .notDownloaded:
                    Button(tr("下载模型")) {
                        Task { try? await mlx.load() }
                    }
                    .buttonStyle(KKQuietButtonStyle())
                    .accessibilityIdentifier("kk-settings-mlx-download")
                }
                Text(tr("质量比 Apple 本机翻译更高，但每句会慢一些。下载一次后离线可用。"))
                    .font(.caption).foregroundStyle(KKColor.textSecondary)
            }
            if state.translationEngine == .openAI {
                HStack {
                    SecureField(tr("OpenAI API Key"), text: $openAIKeyInput, prompt: Text("sk-…"))
                        .accessibilityLabel(tr("OpenAI API Key"))
                        .accessibilityIdentifier("kk-settings-openai-key")
                        .kkFocusRing()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveOpenAIKey() }
                    Button(tr("保存")) { saveOpenAIKey() }
                        .buttonStyle(KKQuietButtonStyle())
                        .accessibilityIdentifier("kk-settings-openai-key-save")
                        .disabled(!TranslationEnginePolicy.isValidKey(openAIKeyInput))
                }
                if state.hasOpenAIKey {
                    HStack(spacing: 8) {
                        Text(tr("已保存：%@", state.openAIKeyHint))
                            .font(.caption).foregroundStyle(KKColor.textSecondary)
                        Button(tr("清除")) {
                            state.clearOpenAIKey()
                            openAIKeyInput = ""
                            openAIKeySaveFailed = false
                        }
                        .buttonStyle(KKLinkButtonStyle())
                        .accessibilityIdentifier("kk-settings-openai-key-clear")
                    }
                } else {
                    Text(tr("还没有保存 Key。粘贴后点「保存」。"))
                        .font(.caption).foregroundStyle(KKColor.warning)
                }
                if openAIKeySaveFailed {
                    Text(tr("这个 Key 看起来不完整，请粘贴完整的 OpenAI API Key。"))
                        .font(.caption).foregroundStyle(KKColor.error)
                }
                Text(tr("Key 只保存在这台 Mac 的钥匙串里，不会上传到 Kikishima。字幕文字会从这台 Mac 直接发送给 OpenAI，不经过我们的服务器。"))
                    .font(.caption).foregroundStyle(KKColor.textSecondary)
                Text(tr("OpenAI Key 只用于你选择的翻译和总结；会议总结默认用本机模型，不联网。"))
                    .font(.caption).foregroundStyle(KKColor.textSecondary)
            } else {
                Text(tr("默认使用 Apple 本机翻译：不联网、不需要下载模型，第一句可能要等系统安装语言包。"))
                    .font(.caption).foregroundStyle(KKColor.textSecondary)
            }
        }
    }

    private func saveOpenAIKey() {
        if state.saveOpenAIKey(openAIKeyInput) {
            openAIKeyInput = ""
            openAIKeySaveFailed = false
        } else {
            openAIKeySaveFailed = true
        }
    }

    @ViewBuilder
    private var hotkeySection: some View {
Section(tr("快捷键")) {
        KKSegmentedPickerAX(title: tr("方式"), selection: Binding(get: { GlobalHotkey.mode }, set: { GlobalHotkey.mode = $0; hotkeyTick += 1 }), options: [(tr("双击左 ⌘"), GlobalHotkey.Mode.doubleCommand), (tr("组合键"), GlobalHotkey.Mode.combo)])
        if GlobalHotkey.mode == .doubleCommand {
            if GlobalHotkey.inputMonitoringGranted {
                Text(tr("已授权「输入监控」，双击左 ⌘ 开关字幕。")).font(.caption).foregroundStyle(KKColor.textSecondary)
            } else {
                HStack {
                    Text(tr("需要「输入监控」权限；未授权前用 %@。", GlobalHotkey.comboDisplay)).font(.caption).foregroundStyle(KKColor.warning)
                    Button(tr("授予权限")) { _ = GlobalHotkey.requestInputMonitoring(); GlobalHotkey.reinstall(); hotkeyTick += 1 }
                    .buttonStyle(KKLinkButtonStyle())
                }
            }
        } else {
            HotkeyRecorder(onChange: { hotkeyTick += 1 })
        }
        if GlobalHotkey.effectiveMode == .combo, GlobalHotkey.lastRegisterError != 0 {
            Text(tr("组合键注册失败（可能被其他 app 占用），换一个")).font(.caption).foregroundStyle(KKColor.warning).id(hotkeyTick)
        } else {
            Text(tr("当前生效：%@", GlobalHotkey.displayText)).font(.caption2).foregroundStyle(KKColor.textTertiary).id(hotkeyTick)
        }
    }
    }

    @ViewBuilder
    private var calendarSection: some View {
Section(tr("日历")) {
        MacCalendarSettingsRow(coordinator: state.calendarCoordinator)
    }
    }

    @ViewBuilder
    private var summarySection: some View {
Section(tr("会议总结")) {
        Toggle(
            tr("自动生成会议要点"),
            isOn: Binding(
                get: { state.summaryConsent == .enabled && state.meetingSummariesEnabled },
                set: { state.setMeetingSummariesEnabled($0) }
            )
        ).toggleStyle(KKSwitchToggleStyle())
        Text(tr("会议总结默认使用本机模型；选择 OpenAI Key 时会直接用 Key。字幕翻译同样可以在设置里切换。"))
            .font(.caption).foregroundStyle(KKColor.textSecondary)
        Text(tr("我的会议称呼"))
            .font(.caption)
            .foregroundStyle(KKColor.textSecondary)
        TextEditor(text: $state.summaryAliasesText).kkFocusRing().kkTabNavigation()
            .accessibilityLabel(tr("我的会议称呼"))
            .font(.system(size: KKLayout.bodyFontSize))
            .frame(minHeight: 72, maxHeight: 110)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(KKColor.textTertiary.opacity(0.3)))
        Text(tr("每行一个称呼，最多 10 个。"))
            .font(.caption)
            .foregroundStyle(KKColor.textSecondary)
        Text(tr("只有会议中明确提到这些称呼的内容才会归到“与你相关”；没有名字的“你来做”暂时无法可靠判断。"))
            .font(.caption)
            .foregroundStyle(KKColor.textSecondary)
        Text(tr("音频不会上传。会议文字和称呼只在本机用于生成会议总结；选择 OpenAI Key 时会直接发送给 OpenAI，不经过 Kikishima。关闭会议总结不会关闭本机会议记录。"))
            .font(.caption)
            .foregroundStyle(KKColor.textSecondary)
    }
    }

    @ViewBuilder
    private var captionSection: some View {
Section(tr("字幕窗")) {
        captionSetting(tr("字幕位置"), value: tr(state.captionSurface == "island" ? "灵动岛" : "桌面窗口")) {
            KKSegmentedPickerAX(title: tr("字幕位置"), selection: Binding(get: { state.captionSurface }, set: { state.selectCaptionSurface($0) }), options: [(tr("灵动岛"), "island"), (tr("桌面窗口"), "window")])
        }
        Text(state.captionSurface == "window" ? tr("桌面窗口可拖动、可改大小。") : tr("灵动岛贴在摄像头下方；桌面窗口可拖动、可改大小。")).font(.caption).foregroundStyle(KKColor.textSecondary)
        captionSetting(tr("显示内容"), value: captionDisplayText(state.captionDisplay == "both" ? "双语" : state.captionDisplay == "translation" ? "仅译文" : "仅原文")) {
            KKSegmentedPickerAX(title: tr("显示内容"), selection: $state.captionDisplay, options: [(tr("双语"), "both"), (captionDisplayText("仅译文"), "translation"), (captionDisplayText("仅原文"), "source")])
        }
        captionSetting(tr("字幕窗宽度"), value: sizeLabel(state.captionWidthLevel, low: "窄", high: "宽")) {
            CaptionSizeLevelPickerAX(title: tr("字幕窗宽度"), level: $state.captionWidthLevel, low: "窄", high: "宽")
        }
        if state.supportsIslandSizing {
            captionSetting(tr("高度"), value: sizeLabel(state.islandHeightLevel, low: "低", high: "高")) {
                CaptionSizeLevelPickerAX(title: tr("高度"), level: $state.islandHeightLevel, low: "低", high: "高")
            }
        }
        captionSetting(tr("字幕长度"), value: tr(state.chunkLength == "short" ? "短" : state.chunkLength == "long" ? "长" : "中")) {
            KKSegmentedPickerAX(title: tr("字幕长度"), selection: $state.chunkLength, options: [(tr("短"), "short"), (tr("中"), "medium"), (tr("长"), "long")])
        }
        Text(tr("更长 = 一句更完整、更连贯，但每句晚出 1～2 秒。")).font(.caption).foregroundStyle(KKColor.textSecondary)
        if state.captionSurface == "window" {
            HStack(spacing: 8) {
                Text(tr("背景不透明度 %@%", Int(state.captionOpacity * 100)))
                    .foregroundStyle(KKColor.textPrimary)
                    .frame(minWidth: 120, alignment: .leading)
                Slider(value: $state.captionOpacity, in: CaptionOpacityPolicy.minimum...1.0)
                    .labelsHidden()
                    .accessibilityLabel(tr("背景不透明度 %@%", Int(state.captionOpacity * 100)))
                    .accessibilityIdentifier("kk-caption-opacity").kkFocusRing()
            }
        }
        captionSetting(tr("译文字号"), value: sizeLabel(state.captionFontLevel, low: "小", high: "大")) {
            CaptionSizeLevelPickerAX(title: tr("译文字号"), level: $state.captionFontLevel, low: "小", high: "大")
        }
        captionSetting(tr("字体"), value: tr(state.captionFontFamily == "rounded" ? "圆体" : state.captionFontFamily == "serif" ? "衬线" : state.captionFontFamily == "mono" ? "等宽" : "系统")) {
            KKSegmentedPickerAX(title: tr("字体"), selection: $state.captionFontFamily, options: [(tr("系统"), "system"), (tr("圆体"), "rounded"), (tr("衬线"), "serif"), (tr("等宽"), "mono")])
        }
        if state.supportsIslandSizing {
            captionSetting(tr("无人说话后收回"), value: tr(state.islandCollapseLevel == "off" ? "关" : state.islandCollapseLevel == "fast" ? "快" : state.islandCollapseLevel == "slow" ? "慢" : "中")) {
                KKSegmentedPickerAX(title: tr("无人说话后收回"), selection: $state.islandCollapseLevel, options: [(tr("关"), CaptionCollapseLevel.off.rawValue), (tr("快"), CaptionCollapseLevel.fast.rawValue), (tr("中"), CaptionCollapseLevel.medium.rawValue), (tr("慢"), CaptionCollapseLevel.slow.rawValue)])
            }
        }
        if state.captionSurface == "window" {
            Toggle(tr("紧凑字幕点击穿透（鼠标直接点到下面的窗口）"), isOn: $state.captionClickThrough).toggleStyle(KKSwitchToggleStyle())
            Text(tr("仅桌面紧凑字幕生效，开启后无法点击工具条或拖动窗口。可在这里关闭；停止字幕也可用菜单栏或快捷键。"))
                .font(.caption).foregroundStyle(KKColor.textSecondary)
        }
        Toggle(tr("允许兼容的共享方式捕获字幕窗"), isOn: $state.captionsVisibleInScreenShare).toggleStyle(KKSwitchToggleStyle())
        Text(tr("关闭此项不能保证字幕不被共享或录屏。共享前请手动隐藏字幕，并在参会者设备上确认。")).font(.caption).foregroundStyle(KKColor.textSecondary)
        Button { captionPanel.toggleVisible(mode: state.effectiveMode) } label: {
            Text(captionPanel.hasVisibleCaptions ? tr("隐藏字幕窗") : tr("显示字幕窗"))
                .foregroundStyle(KKColor.textPrimary)
                .padding(.horizontal, KKSpace.three)
                .frame(height: 28)
                .background(KKColor.surfaceRaised, in: RoundedRectangle(cornerRadius: KKRadius.sm))
                .overlay {
                    RoundedRectangle(cornerRadius: KKRadius.sm)
                        .strokeBorder(KKColor.captionVisibilityBorder, lineWidth: 1)
                }
        }
        .buttonStyle(KKPlainButtonStyle(radius: KKRadius.sm))
        .accessibilityIdentifier("kk-sharing-hide-captions")
    }
    }

    @ViewBuilder
    private var generalSection: some View {
Section(tr("常规")) {
        Toggle(tr("登录时自动启动"), isOn: Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) })).toggleStyle(KKSwitchToggleStyle())
        Toggle(tr("启动时显示主窗口"), isOn: Binding(get: { AppDelegate.showMainOnLaunch }, set: { AppDelegate.showMainOnLaunch = $0 })).toggleStyle(KKSwitchToggleStyle())
        Toggle(tr("在 Dock 显示图标"), isOn: Binding(get: { AppDelegate.showDockIcon }, set: { AppDelegate.showDockIcon = $0 })).toggleStyle(KKSwitchToggleStyle())
        LabeledContent(tr("会议记录保存位置")) {
            HStack {
                Text(transcriptDisplayPath(CaptionState.transcriptDir, homeDirectory: FileManager.default.homeDirectoryForCurrentUser)).font(.caption).foregroundStyle(KKColor.textSecondary).lineLimit(1).truncationMode(.middle)
                Button(tr("打开文件夹")) {
                    try? FileManager.default.createDirectory(at: CaptionState.transcriptDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(CaptionState.transcriptDir)
                }.buttonStyle(KKQuietButtonStyle()).foregroundStyle(KKColor.textPrimary)
                Button(tr("更改…")) { chooseTranscriptDir() }
                    .buttonStyle(KKQuietButtonStyle())
                    .foregroundStyle(KKColor.textPrimary)
            }
        }
        // 服务器地址不给终端用户看；开发调试用 `defaults write com.kikishima.mac proxyURL <url>`
    }
    }

    private func chooseTranscriptDir() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true; p.allowsMultipleSelection = false
        p.prompt = tr("选择")
        p.message = tr("选择会议记录文件夹")
        p.directoryURL = CaptionState.transcriptDir
        if p.runModal() == .OK, let url = p.url { CaptionState.setTranscriptDir(url) }
    }
}

/// Ensures that whenever keyboard focus (first responder) moves to any control in
/// the settings form, the enclosing scroll view automatically scrolls to reveal it.
private struct SettingsFocusAutoScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsScrollObserverView { SettingsScrollObserverView() }
    func updateNSView(_ nsView: SettingsScrollObserverView, context: Context) {}
}

private final class SettingsScrollObserverView: NSView {
    private weak var lastResponder: NSView?
    private var observer: NSObjectProtocol?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let window else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.handleWindowUpdate()
        }
    }

    private func handleWindowUpdate() {
        guard let window, window.isKeyWindow else { return }
        guard let responder = window.firstResponder as? NSView else { return }
        // Text fields hand focus to the shared field editor (an NSTextView that
        // lives outside the form's scroll view). Resolve the control being edited.
        let target: NSView
        if let editor = responder as? NSTextView, editor.isFieldEditor,
           let client = editor.delegate as? NSView {
            target = client
        } else {
            target = responder
        }
        guard target !== lastResponder else { return }
        lastResponder = target
        guard let scrollView = enclosingScrollView else { return }
        let doc = scrollView.documentView ?? scrollView
        if target.isDescendant(of: doc) {
            target.scrollToVisible(target.bounds.insetBy(dx: -8, dy: -8))
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// 组合键录制：点一下，按下想要的组合键
struct HotkeyRecorder: View {
    var onChange: () -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var display = GlobalHotkey.comboDisplay
    @State private var warning = ""

    /// macOS 自己占着的 ⌘ 组合：录进去等于把系统快捷键抢了
    private static let reserved: Set<UInt16> = [UInt16(kVK_ANSI_Q), UInt16(kVK_ANSI_W), UInt16(kVK_ANSI_H), UInt16(kVK_ANSI_M), UInt16(kVK_Space), UInt16(kVK_Tab), UInt16(kVK_ANSI_Comma)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(tr("组合键")).frame(width: 60, alignment: .leading)
                Button(recording ? tr("请按下组合键…") : display) { recording ? stop() : start() }
                    .frame(minWidth: 140)
                if recording { Button(tr("取消")) { stop() } }
                Text(recording ? tr("按 Esc 取消") : tr("需含 ⌃ ⌥ ⇧ ⌘ 中至少一个")).font(.caption).foregroundStyle(KKColor.textSecondary)
            }
            if !warning.isEmpty { Text(warning).font(.caption).foregroundStyle(KKColor.warning) }
        }
        .onDisappear { stop() }   // 录制中切走 / 关窗：监视器必须跟着销毁，否则全 app 键盘被吞
    }

    private func start() {
        recording = true; warning = ""
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var carbon: UInt32 = 0
            if f.contains(.command) { carbon |= UInt32(cmdKey) }
            if f.contains(.shift) { carbon |= UInt32(shiftKey) }
            if f.contains(.option) { carbon |= UInt32(optionKey) }
            if f.contains(.control) { carbon |= UInt32(controlKey) }
            if e.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            guard carbon != 0 else { return e }   // 没带修饰键的按键放行，别吞
            if carbon == UInt32(cmdKey), Self.reserved.contains(e.keyCode) { warning = tr("这个组合被系统占用，换一个"); return nil }
            GlobalHotkey.comboKeyCode = UInt32(e.keyCode)
            GlobalHotkey.comboModifiers = carbon
            display = GlobalHotkey.comboDisplay
            stop(); onChange()
            return nil
        }
    }
    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

// MARK: - 帮助

/// 隐私说明只写一处（欢迎页 / 帮助 / 关于共用）
@MainActor var privacyStatement: String {
    tr("音频只在本机转写，从不上传。默认翻译和会议总结都在本机完成，文字不会离开这台 Mac。只有你选择「自带 OpenAI Key」时，字幕文字或总结输入才会从这台 Mac 直接发送给 OpenAI，不经过 Kikishima。会议记录与总结只存在你的 Mac 上。")
}

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(tr("怎么用")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("1. 开会前在「语言」里选好会议语言和译文语言。"))
                        Text(tr("2. 会议开始后，菜单栏点图标 → 开始字幕，或按 %@。", GlobalHotkey.displayText))
                        Text(tr("3. 字幕默认显示在屏幕顶部的灵动岛，也可在菜单面板切到桌面窗口。"))
                        Text(tr("4. 停止时记录自动保存到「文稿 › Kikishima」。"))
                        Text(tr("只字幕你听到的声音；你自己说的话不会被记录。")).foregroundStyle(KKColor.textSecondary)
                    }.padding(6)
                }
                GroupBox(tr("隐私")) {
                    Text(privacyStatement).padding(6)
                }
                GroupBox(tr("系统要求")) {
                    Text(tr("macOS 26 (Tahoe) 及以上，Apple Silicon。首次使用会下载一次 Apple 离线转写模型。")).padding(6)
                }
                Button(tr("重新运行首次引导")) { OnboardingController.shared.restart() }
                .buttonStyle(KKLinkButtonStyle())
                AboutView().frame(maxWidth: .infinity)
            }
            .padding(.horizontal, KKSpace.eight).padding(.bottom, KKSpace.eight)
        }
    }
}
