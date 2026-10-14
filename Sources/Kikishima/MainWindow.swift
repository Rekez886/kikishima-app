// 主窗口：左侧栏 + 右内容（Wispr Flow 式），便于后续加功能。视觉归设计轮，这里只定信息架构
import SwiftUI
import AppKit
import Speech
import Carbon.HIToolbox

enum MainSection: String, CaseIterable, Identifiable {
    case captions = "字幕", history = "记录", glossary = "术语表", languages = "语言", settings = "设置", help = "帮助"
    var id: String { rawValue }
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

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                SidebarBrandRow()
                List(selection: $state.mainSection) {
                    ForEach(MainSection.allCases) { s in
                        Label(tr(s.rawValue), systemImage: s.icon)
                            .frame(minHeight: 24).tag(s)
                    }
                }
                .listStyle(.sidebar)
                quotaCard.padding(10)
            }
            // Column preferences alone do not constrain native fitting-size measurement.
            // Give wrapped account text a real width so it cannot inflate the split height.
            .frame(minWidth: 190)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            Group {
                switch state.mainSection ?? .captions {
                case .captions: CaptionsHome(state: state)
                case .history: HistoryView()
                case .glossary: GlossarySettings(state: state).padding(20)
                case .languages: LanguagesView(state: state)
                case .settings: SettingsPane(state: state)
                case .help: HelpView()
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 780, minHeight: 520)
        .task { state.refreshPlan() }
    }

    private var quotaCard: some View {
        SidebarAccountCard(summary: accountSummary,
            login: { state.mainSection = .settings },
            upgrade: { state.openUpgrade() },
            redeemInvite: { state.mainSection = .settings; state.focusInvite = true },
            signOut: { state.signOut() })
    }

    private var accountSummary: SidebarAccountSummary {
        guard !state.sessionToken.isEmpty else { return .init(tier: .signedOut) }
        if state.plan == "pro" || state.plan == "dev" {
            let title: String
            if state.plan == "dev" { title = tr("开发者") }
            else if state.subscriptionStatus == "trialing", let days = state.trialDaysLeft {
                title = tr("试用中 · 还剩 %@ 天", days)
            } else { title = "Pro" }
            return .init(tier: .pro, email: state.accountEmail, paidTitle: title,
                usageDescription: state.usageQuota > 0 ? tr("本月已用约 %@ 分钟", state.usageTokens / 4000) : nil)
        }
        return .init(tier: .free, email: state.accountEmail,
            remainingMinutes: state.remainingMinutes, remainingDescription: state.remainingText)
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

    private var previewText: CaptionPreviewText {
        CaptionPreviewText(
            segments: state.compactCaptionChunks.filter { !$0.isMarker }.map {
                (source: $0.displaySource, translation: $0.displayTranslation)
            },
            pendingSource: state.pendingEn, pendingTranslation: state.pendingDraft,
            translationPaused: state.translationPaused)
    }
    private var previewSource: String {
        guard state.running || state.starting else { return "Let's review the next steps together." }
        return previewText.source
    }
    private var previewTranslation: String {
        guard state.running || state.starting else { return HomeCaptionPreview.sampleTranslation(for: state.targetLang) }
        return previewText.translation
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(state.accountEmail.isEmpty ? "Kikishima" : tr("欢迎回来"))
                        .font(.system(size: 24, weight: .bold))
                    Text(state.status).font(.system(size: 13)).foregroundStyle(.secondary)
                }

                if state.sessionToken.isEmpty, !state.loginHint.isEmpty {
                    Label(state.loginHint, systemImage: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange)
                }

                HomeCaptionPreview(
                    source: previewSource, translation: previewTranslation, status: state.status,
                    compact: state.compactCaptions, display: state.captionDisplay,
                    desktop: state.captionSurface == "window", isExample: !state.running && !state.starting)

                VStack(alignment: .leading, spacing: 8) {
                HomeCaptionControls(active: state.running || state.starting, running: state.running,
                    paused: state.paused, transition: state.switchingMeetingLanguage || state.resuming,
                    compact: $state.compactCaptions, display: $state.captionDisplay,
                    toggle: { state.toggle() }, pause: { state.paused ? state.resume() : state.pause() })
                Text(tr("快捷键 %@", GlobalHotkey.displayText))
                    .font(.caption).foregroundStyle(.secondary)
                }

                Divider()
                // 语言：首页直接可选；会中选择会重启转写引擎，但保留同一场会议
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tr("会议语言")).font(.caption).foregroundStyle(.secondary)
                            Picker(tr("会议语言"), selection: Binding(
                                get: { state.localeID },
                                set: { state.selectMeetingLanguage($0) }
                            )) {
                                ForEach(homeLocales, id: \.self) { id in
                                    Text(localeName(id) + (state.meetingLocales.contains(id) || state.modelReady(id) ? "" : " · " + tr("需下载"))).tag(id)
                                }
                            }
                            .labelsHidden().frame(maxWidth: 240)
                            .disabled(state.starting || state.switchingMeetingLanguage || state.resuming)
                        }
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary).padding(.top, 14)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tr("译文语言")).font(.caption).foregroundStyle(.secondary)
                            Picker(tr("译文语言"), selection: $state.targetLang) {
                                ForEach(targetLanguages, id: \.prompt) { lang in Text(lang.display).tag(lang.prompt) }
                            }
                            .labelsHidden().frame(maxWidth: 240)
                            .disabled(state.running || state.starting || state.switchingMeetingLanguage)
                        }
                    }
                    Button(tr("更多语言…")) { state.mainSection = .languages }
                        .buttonStyle(.link)
                }
                .task { allLocales = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted() }

                CalendarMeetingCard(coordinator: state.calendarCoordinator,
                                    isRunning: state.running || state.starting)

                if state.summaryConsent == .undecided {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(tr("Kikishima 可以在会议中持续整理要点，并在停止字幕后生成最终总结。"))
                            Text(tr("音频不会上传。会议文字和你填写的称呼会发送到 Kikishima，并转交 OpenAI 生成总结；服务器不保存内容。关闭会议总结不会关闭本机会议记录。"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button(tr("生成会议总结")) { state.setMeetingSummariesEnabled(true) }
                                    .buttonStyle(.borderedProminent)
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
            .frame(maxWidth: 640, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - 记录

struct TranscriptFile: Identifiable, Hashable, Sendable {
    let url: URL
    var id: URL { url }
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
                Text(tr("还没有会议记录。停止字幕时会自动保存到「文稿 › Kikishima」。")).font(.caption).foregroundStyle(.secondary).padding(6)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(files.prefix(limit)) { f in
                        HStack {
                            Text(f.name).lineLimit(1)
                            Spacer()
                            Text(f.date, style: .relative).font(.caption).foregroundStyle(.tertiary)
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

private struct TranscriptRow: View {
    let file: TranscriptFile
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(file.name).font(.system(size: 12, weight: .medium))
                    .lineLimit(2).help(file.name)
                Text(file.date, style: .date).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(tr("删除"))
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .onHover { hovering = $0 }
    }
}

struct HistoryView: View {
    @Bindable private var state = CaptionState.shared
    @State private var files: [TranscriptFile] = []
    @State private var query = ""
    @State private var previewSelection: TranscriptFile.ID?
    @State private var selection: Set<TranscriptFile.ID> = []
    @State private var pendingDeletions: [TranscriptFile] = []
    @State private var showingDeletionConfirmation = false
    @State private var contents: [URL: String] = [:]
    @State private var summaries: [URL: MeetingSummaryDocument] = [:]
    @State private var retryableSummaryURLs: Set<URL> = []
    @State private var operationError: String?
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
        let alert = NSAlert()
        alert.messageText = tr("重命名记录")
        alert.addButton(withTitle: tr("好")); alert.addButton(withTitle: tr("取消"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = f.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
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
        guard !files.isEmpty else { return }
        pendingDeletions = files
        showingDeletionConfirmation = true
    }

    private func delete(_ files: [TranscriptFile]) {
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
        let loadedFiles = await Task.detached(priority: .utility) { loadTranscripts() }.value
        var loadedContents: [URL: String] = [:]
        var loadedSummaries: [URL: MeetingSummaryDocument] = [:]
        var loadedRetryableURLs: Set<URL> = []
        for file in loadedFiles {
            loadedContents[file.url] = await Task.detached(priority: .utility) {
                (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
            }.value
            if let document = try? await summaryStore.load(for: file.url) {
                let currentFingerprint = await Task.detached(priority: .utility) {
                    try? MeetingSummaryStore.sha256(of: file.url)
                }.value
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
        files = loadedFiles
        contents = loadedContents
        summaries = loadedSummaries
        retryableSummaryURLs = loadedRetryableURLs
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
                Text(tr("会议记录")).font(.system(size: 24, weight: .bold))
                Spacer()
                Button(role: .destructive) {
                    requestDeletion(selectedFiles)
                } label: {
                    Label(tr("删除所选"), systemImage: "trash")
                }
                .disabled(selectedFiles.isEmpty)
                Button(tr("打开文件夹")) {
                    try? FileManager.default.createDirectory(at: CaptionState.transcriptDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(CaptionState.transcriptDir)
                }
            }
            TextField(tr("搜索标题或内容"), text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
            if files.isEmpty {
                ContentUnavailableView(tr("还没有会议记录"), systemImage: "doc.text", description: Text(tr("停止字幕时会自动保存到「文稿 › Kikishima」。")))
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                HSplitView {
                    // 双击打开、右键更多；删除做成悬停可见入口，避免功能藏得太深
                    List(shown, selection: $selection) { f in
                        TranscriptRow(file: f) { requestDeletion([f]) }
                            .tag(f.id)
                            .contentShape(Rectangle())
                    }
                    .contextMenu(forSelectionType: TranscriptFile.ID.self) { ids in
                        let targets = shown.filter { ids.contains($0.id) }
                        if let file = targets.first, targets.count == 1 {
                            Button(tr("打开")) { NSWorkspace.shared.open(file.url) }
                            Button(tr("在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                            Button(tr("重命名…")) { rename(file) }
                            Divider()
                        }
                        if !targets.isEmpty {
                            Button(tr("删除"), role: .destructive) { requestDeletion(targets) }
                        }
                    } primaryAction: { ids in
                        for file in shown where ids.contains(file.id) {
                            NSWorkspace.shared.open(file.url)
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 160, idealWidth: 196, maxWidth: 260)

                    if let selected = files.first(where: { $0.id == previewSelection }) {
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
                        .frame(minWidth: 280, maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(28)
        .task { await reload() }
        .onChange(of: state.meetingSummarySnapshot) { Task { await reload() } }
        .onChange(of: state.summaryDiskRevision) { Task { await reload() } }
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
            Picker(tr("界面语言"), selection: $state.uiLanguage) {
                ForEach(UILang.all) { l in Text(l.native).tag(l.code) }
            }
            .onChange(of: state.uiLanguage) {
                showingLanguageRelaunchPrompt = AppLanguagePreference.requiresRelaunch(for: state.uiLanguage)
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
                    Text(tr("字幕运行中。为避免中断，更新窗口等系统界面会在下次启动 Kikishima 时切换语言。"))
                } else {
                    Text(tr("更新窗口等系统界面需要重新启动 Kikishima 才能切换语言。"))
                }
            }
            Section(tr("常用会议语言（已预下载模型）")) {
                Toggle(tr("选了就下载模型（建议在 Wi-Fi 下）"), isOn: $state.autoDownloadModels)
                if state.meetingLocales.isEmpty {
                    Text(tr("还没选。开始字幕时会按需下载当前会议语言的模型。")).font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(state.meetingLocales, id: \.self) { id in
                        HStack {
                            Text(localeName(id))
                            Spacer()
                            if let p = state.modelProgress[id], p < 1 { ProgressView(value: p).frame(width: 60) }
                            else { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            Button { state.meetingLocales.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                                .accessibilityLabel(tr("删除"))
                        }
                    }
                }
                Menu(tr("添加会议语言")) {
                    ForEach(sourceLocales.filter { !state.meetingLocales.contains($0.identifier) }, id: \.identifier) { loc in
                        Button(localeName(loc.identifier)) { state.meetingLocales.append(loc.identifier); state.predownloadModels([loc.identifier]) }
                    }
                }
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
                        Text(localeName(loc.identifier) + (state.meetingLocales.contains(loc.identifier) || state.modelReady(loc.identifier) ? "" : " · " + tr("需下载"))).tag(loc.identifier)
                    }
                }
            }
            .disabled(state.starting || state.switchingMeetingLanguage || state.resuming)
            Picker(tr("译文语言"), selection: $state.targetLang) {
                ForEach(targetLanguages, id: \.prompt) { lang in Text(lang.display).tag(lang.prompt) }
            }
            .disabled(state.running || state.starting || state.switchingMeetingLanguage)
            CaptionSizeLevelPicker(title: tr("译文字号"), level: $state.captionFontLevel, low: "小", high: "大")
        }
        .formStyle(.grouped)
        .task {
            let locales = await SpeechTranscriber.supportedLocales
            sourceLocales = locales.sorted { localeName($0.identifier) < localeName($1.identifier) }
        }
    }
}

// MARK: - 设置（账号 + 快捷键 + 常规）

struct SettingsPane: View {
    @Bindable var state: CaptionState
    @State private var launchAtLogin = LaunchAtLoginController.live()
    @State private var email = ""
    @State private var code = ""
    @State private var invite = ""
    @State private var showEmailSignIn = false
    @State private var hotkeyTick = 0   // 强制刷新快捷键显示
    @FocusState private var inviteFocused: Bool

    var body: some View {
        Form {
            Section(tr("账号")) {
                if !state.sessionToken.isEmpty {
                    LabeledContent(tr("邮箱")) { Text(state.accountEmail.isEmpty ? tr("已登录") : state.accountEmail) }
                    LabeledContent(tr("档位")) {
                        if state.plan == "pro" {
                            HStack(spacing: 6) {
                                Circle().fill(Color(red: 1, green: 59.0 / 255, blue: 31.0 / 255))
                                    .frame(width: 5, height: 5).accessibilityHidden(true)
                                Text(state.subscriptionStatus == "trialing" ? tr("Pro（试用中）") : "Pro")
                            }
                        } else {
                            Text(state.plan == "dev" ? tr("开发") : tr("免费版 · 每周 60 分钟"))
                        }
                    }
                    if let exp = state.planExpires { LabeledContent(state.subscriptionStatus == "trialing" ? tr("试用到") : tr("到期")) { Text(exp) } }
                    HStack {
                        if state.plan != "pro" && state.plan != "dev" { Button(tr("升级 Pro")) { state.openUpgrade() } }
                        Spacer()
                        Button(tr("刷新订阅状态")) { state.refreshPlan() }
                        Button(tr("退出登录")) { state.signOut() }
                    }
                    if state.plan != "pro" && state.plan != "dev" {
                        Text(tr("请用与账号相同的邮箱付款，才能自动升级。")).font(.caption).foregroundStyle(.secondary)
                        // 邀请码用于兑换终身 / 限期 Pro，区别于 Polar 结账页的折扣码
                        HStack {
                            TextField(tr("有邀请码？"), text: $invite)
                                .focused($inviteFocused)
                                .onSubmit { state.redeemInvite(invite) }
                            Button(state.activating ? tr("验证中…") : tr("兑换")) { state.redeemInvite(invite) }
                                .disabled(invite.trimmingCharacters(in: .whitespaces).count < 8 || state.activating)
                        }
                        Text(tr("邀请码在这里兑换，不用绑支付方式；它不是结账页的折扣码。")).font(.caption).foregroundStyle(.secondary)
                        .onAppear { if state.focusInvite { inviteFocused = true; state.focusInvite = false } }
                        .onChange(of: state.focusInvite) { if state.focusInvite { inviteFocused = true; state.focusInvite = false } }
                    }
                } else if state.codeSent {
                    LabeledContent(tr("邮箱")) { Text(state.accountEmail).foregroundStyle(.secondary) }
                    HStack {
                        TextField(tr("6 位验证码"), text: $code).onSubmit { state.verifyEmailCode(code: code) }
                        Button(state.activating ? tr("验证中…") : tr("登录")) { state.verifyEmailCode(code: code) }
                            .disabled(code.filter(\.isNumber).count != 6 || state.activating)
                    }
                    HStack {
                        Button(tr("换个邮箱")) { state.codeSent = false; code = "" }
                        Button(tr("重新发送")) { state.requestEmailCode(email: state.accountEmail) }.disabled(state.activating)
                    }.font(.caption)
                } else {
                    if !state.loginHint.isEmpty { Text(state.loginHint).font(.callout).foregroundStyle(.orange) }
                    let hasSocial = GoogleSignIn.isConfigured || state.canSignInWithApple
                    VStack(spacing: 8) {
                        if GoogleSignIn.isConfigured {
                            SignInTile(title: tr("使用 Google 登录"), icon: "globe") { state.signInWithGoogle() }.disabled(state.activating)
                        }
                        if state.canSignInWithApple {
                            SignInTile(title: tr("通过 Apple 登录"), icon: "apple.logo") { state.signInWithApple() }.disabled(state.activating)
                        }
                        if hasSocial {
                            SignInTile(title: tr("使用邮箱登录"), icon: "envelope") { showEmailSignIn.toggle() }.disabled(state.activating)
                        }
                        if state.activating { Button(tr("取消")) { state.cancelSignIn() } }
                    }
                    if showEmailSignIn || !hasSocial {
                        HStack {
                            TextField(tr("邮箱"), text: $email).textContentType(.emailAddress).onSubmit { state.requestEmailCode(email: email) }
                            Button(state.activating ? tr("发送中…") : tr("发送验证码")) { state.requestEmailCode(email: email) }
                                .disabled(!email.contains("@") || state.activating)
                        }
                    }
                    Text(tr("免费版每周 60 分钟，登录即用；付费后同一邮箱自动升级 Pro。")).font(.caption).foregroundStyle(.secondary)
                }
                if !state.activationError.isEmpty { Text(state.activationError).font(.caption).foregroundStyle(.red) }
            }

            Section(tr("快捷键")) {
                Picker(tr("方式"), selection: Binding(get: { GlobalHotkey.mode }, set: { GlobalHotkey.mode = $0; hotkeyTick += 1 })) {
                    Text(tr("双击左 ⌘")).tag(GlobalHotkey.Mode.doubleCommand)
                    Text(tr("组合键")).tag(GlobalHotkey.Mode.combo)
                }
                .pickerStyle(.segmented)
                if GlobalHotkey.mode == .doubleCommand {
                    if GlobalHotkey.inputMonitoringGranted {
                        Text(tr("已授权「输入监控」，双击左 ⌘ 开关字幕。")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text(tr("需要「输入监控」权限；未授权前用 %@。", GlobalHotkey.comboDisplay)).font(.caption).foregroundStyle(.orange)
                            Button(tr("授予权限")) { _ = GlobalHotkey.requestInputMonitoring(); GlobalHotkey.reinstall(); hotkeyTick += 1 }
                        }
                    }
                } else {
                    HotkeyRecorder(onChange: { hotkeyTick += 1 })
                }
                if GlobalHotkey.effectiveMode == .combo, GlobalHotkey.lastRegisterError != 0 {
                    Text(tr("组合键注册失败（可能被其他 app 占用），换一个")).font(.caption).foregroundStyle(.orange).id(hotkeyTick)
                } else {
                    Text(tr("当前生效：%@", GlobalHotkey.displayText)).font(.caption2).foregroundStyle(.tertiary).id(hotkeyTick)
                }
            }

            Section(tr("日历")) {
                MacCalendarSettingsRow(coordinator: state.calendarCoordinator)
            }

            Section(tr("会议总结")) {
                Toggle(
                    tr("自动生成会议要点"),
                    isOn: Binding(
                        get: { state.summaryConsent == .enabled && state.meetingSummariesEnabled },
                        set: { state.setMeetingSummariesEnabled($0) }
                    )
                )
                Text(tr("我的会议称呼"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $state.summaryAliasesText)
                    .font(.system(size: 13))
                    .frame(minHeight: 72, maxHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                Text(tr("每行一个称呼，最多 10 个。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(tr("只有会议中明确提到这些称呼的内容才会归到“与你相关”；没有名字的“你来做”暂时无法可靠判断。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(tr("音频不会上传。会议文字和你填写的称呼会发送到 Kikishima，并转交 OpenAI 生成总结；服务器不保存内容。关闭会议总结不会关闭本机会议记录。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(tr("更新")) {
                Toggle(tr("自动检查更新"), isOn: Binding(get: { UpdaterController.shared.automaticallyChecks }, set: { UpdaterController.shared.automaticallyChecks = $0 }))
                Toggle(tr("自动下载并在下次启动时安装"), isOn: Binding(get: { UpdaterController.shared.automaticallyDownloads }, set: { UpdaterController.shared.automaticallyDownloads = $0 }))
                    .disabled(!UpdaterController.shared.automaticallyChecks)
                HStack {
                    Button(tr("检查更新…")) { UpdaterController.shared.checkForUpdates() }.disabled(!UpdaterController.shared.canCheck)
                    Spacer()
                    if let d = UpdaterController.shared.lastCheck {
                        Text(tr("上次检查：%@", d.formatted(date: .abbreviated, time: .shortened))).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(tr("当前版本 %@", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")).font(.caption).foregroundStyle(.tertiary)
            }
            Section(tr("字幕窗")) {
                Picker(tr("字幕位置"), selection: $state.captionSurface) {
                    Text(tr("灵动岛")).tag("island")
                    Text(tr("桌面窗口")).tag("window")
                }
                .pickerStyle(.segmented)
                Text(tr("灵动岛贴在摄像头下方；桌面窗口可拖动、可改大小。")).font(.caption).foregroundStyle(.secondary)
                Picker(tr("显示内容"), selection: $state.captionDisplay) {
                    Text(tr("原文 + 译文")).tag("both")
                    Text(tr("仅译文")).tag("translation")
                    Text(tr("仅原文")).tag("source")
                }
                .pickerStyle(.segmented)
                CaptionSizeLevelPicker(title: tr("字幕窗宽度"), level: $state.captionWidthLevel, low: "窄", high: "宽")
                if state.supportsIslandSizing {
                    CaptionSizeLevelPicker(title: tr("高度"), level: $state.islandHeightLevel, low: "低", high: "高")
                }
                Picker(tr("字幕长度"), selection: $state.chunkLength) {
                    Text(tr("短")).tag("short")
                    Text(tr("中")).tag("medium")
                    Text(tr("长")).tag("long")
                }
                .pickerStyle(.segmented)
                Text(tr("更长 = 一句更完整、更连贯，但每句晚出 1～2 秒。")).font(.caption).foregroundStyle(.secondary)
                if state.captionSurface == "window" {
                    Slider(value: $state.captionOpacity, in: 0.3...1.0) { Text(tr("背景不透明度 %@%", Int(state.captionOpacity * 100))) }
                }
                CaptionSizeLevelPicker(title: tr("译文字号"), level: $state.captionFontLevel, low: "小", high: "大")
                Picker(tr("字体"), selection: $state.captionFontFamily) {
                    Text(tr("系统")).tag("system")
                    Text(tr("圆体")).tag("rounded")
                    Text(tr("衬线")).tag("serif")
                    Text(tr("等宽")).tag("mono")
                }
                .pickerStyle(.segmented)
                if state.supportsIslandSizing {
                    Picker(tr("无人说话后收回"), selection: $state.islandCollapseLevel) {
                        Text(tr("关")).tag(CaptionCollapseLevel.off.rawValue)
                        Text(tr("快")).tag(CaptionCollapseLevel.fast.rawValue)
                        Text(tr("中")).tag(CaptionCollapseLevel.medium.rawValue)
                        Text(tr("慢")).tag(CaptionCollapseLevel.slow.rawValue)
                    }
                    .pickerStyle(.segmented)
                }
                if state.captionSurface == "window" {
                    Toggle(tr("紧凑字幕点击穿透（鼠标直接点到下面的窗口）"), isOn: $state.captionClickThrough)
                    Text(tr("仅桌面紧凑字幕生效，开启后无法点击工具条或拖动窗口。可在这里关闭；停止字幕也可用菜单栏或快捷键。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(tr("允许字幕窗出现在屏幕共享中"), isOn: $state.captionsVisibleInScreenShare)
                Text(tr("默认关闭：共享屏幕时对方看不到你的字幕。")).font(.caption).foregroundStyle(.secondary)
            }
            Section(tr("常规")) {
                Toggle(tr("登录时自动启动"), isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }))
                Toggle(tr("启动时显示主窗口"), isOn: Binding(get: { AppDelegate.showMainOnLaunch }, set: { AppDelegate.showMainOnLaunch = $0 }))
                Toggle(tr("在 Dock 显示图标"), isOn: Binding(get: { AppDelegate.showDockIcon }, set: { AppDelegate.showDockIcon = $0 }))
                LabeledContent(tr("会议记录保存位置")) {
                    HStack {
                        Text(CaptionState.transcriptDir.path(percentEncoded: false)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button(tr("打开文件夹")) {
                            try? FileManager.default.createDirectory(at: CaptionState.transcriptDir, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(CaptionState.transcriptDir)
                        }
                        Button(tr("更改…")) { chooseTranscriptDir() }
                    }
                }
                // 服务器地址不给终端用户看；开发调试用 `defaults write com.kikishima.mac proxyURL <url>`
            }
        }
        .formStyle(.grouped)
        .font(.system(size: 13))
        .alert(tr("无法更改登录启动设置"), isPresented: Binding(
            get: { launchAtLogin.errorMessage != nil },
            set: { if !$0 { launchAtLogin.dismissError() } }
        )) {
            Button(tr("好")) { launchAtLogin.dismissError() }
        } message: {
            Text(launchAtLogin.errorMessage ?? "")
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
                Text(recording ? tr("按 Esc 取消") : tr("需含 ⌃ ⌥ ⇧ ⌘ 中至少一个")).font(.caption).foregroundStyle(.secondary)
            }
            if !warning.isEmpty { Text(warning).font(.caption).foregroundStyle(.orange) }
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
    tr("音频只在本机转写，从不上传。转写出的文字、前一句上下文、术语表和会议称呼会发送到 Kikishima 服务器，并转交 AI 模型服务用于翻译和生成会议总结；服务器不保存内容。会议记录与总结只存在你的 Mac 上。")
}

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(tr("帮助")).font(.system(size: 24, weight: .bold))
                GroupBox(tr("怎么用")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("1. 开会前在「语言」里选好会议语言和译文语言。"))
                        Text(tr("2. 会议开始后，菜单栏点图标 → 开始字幕，或按 %@。", GlobalHotkey.displayText))
                        Text(tr("3. 字幕窗浮在会议窗口上，贴在屏幕顶部。"))
                        Text(tr("4. 停止时记录自动保存到「文稿 › Kikishima」。"))
                        Text(tr("只字幕你听到的声音；你自己说的话不会被记录。")).foregroundStyle(.secondary)
                    }.padding(6)
                }
                GroupBox(tr("隐私")) {
                    Text(privacyStatement).padding(6)
                }
                GroupBox(tr("系统要求")) {
                    Text(tr("macOS 26 (Tahoe) 及以上，Apple Silicon。首次使用会下载一次 Apple 离线转写模型。")).padding(6)
                }
                Button(tr("重新运行首次引导")) { OnboardingController.shared.restart() }
                AboutView().frame(maxWidth: .infinity)
            }
            .padding(28)
        }
    }
}
