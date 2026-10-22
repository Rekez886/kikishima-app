import AppKit
import SwiftUI

@MainActor
final class CaptionReviewController: NSObject, NSWindowDelegate {
    static let shared = CaptionReviewController()
    private var window: NSWindow?
    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 540),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = tr("回看本场字幕")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: CaptionReviewView(
            chunks: CaptionState.shared.chunks.filter { !$0.isMarker && $0.sourceFinal && $0.translationComplete && !$0.isDraft },
            returnToLive: { [weak self] in
                self?.window?.close()
                CaptionPanelController.shared.show()
            }))
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Clear the frozen snapshot so reopening always reflects the current session.
    func windowWillClose(_ notification: Notification) { window = nil }
    func close() { window?.close() }
}

private struct CaptionReviewView: View {
    let chunks: [CaptionChunk]
    var returnToLive: () -> Void
    @State private var query = ""
    @State private var copyFeedbackOwner = UUID()

    private func copyFeedbackID(_ item: String) -> String { "\(copyFeedbackOwner)/\(item)" }

    private var matches: [CaptionChunk] {
        chunks.filter {
            query.isEmpty || $0.en.localizedCaseInsensitiveContains(query) ||
                $0.zh.localizedCaseInsensitiveContains(query)
        }
    }

    private func copy(_ chunks: [CaptionChunk], feedbackID: String) {
        let text = chunks.map { chunk in
            let translation = CaptionReadingPolicy.isReadable(chunk.zh, isDraft: chunk.isDraft) ? chunk.zh : ""
            return [chunk.en, translation].filter { !$0.isEmpty }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) {
            CopyFeedbackPresenter.shared.show(feedbackID)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("回看已暂停更新，字幕仍在继续。重新打开可载入最新内容。"))
                .font(.callout).foregroundStyle(KKColor.textSecondary)
            HStack {
                TextField(tr("搜索原文或译文"), text: $query)
                    .textFieldStyle(.roundedBorder).kkFocusRing()
                Button(tr("复制双语字幕")) { copy(matches, feedbackID: copyFeedbackID("toolbar")) }
                    .disabled(matches.isEmpty)
                    .accessibilityIdentifier("kk-review-copy")
                CopyFeedbackBadge(id: copyFeedbackID("toolbar"))
                Button(tr("回到实时")) { returnToLive() }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(matches) { chunk in
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(chunk.en).foregroundStyle(KKColor.textSecondary)
                                if CaptionReadingPolicy.isReadable(chunk.zh, isDraft: chunk.isDraft) {
                                    Text(chunk.zh)
                                } else {
                                    Text(tr("译文尚未完成")).foregroundStyle(KKColor.textSecondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            CopyFeedbackBadge(id: copyFeedbackID(chunk.id.uuidString))
                        }
                        .contextMenu { Button(tr("复制双语字幕")) {
                            copy([chunk], feedbackID: copyFeedbackID(chunk.id.uuidString))
                        } }
                        Divider()
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 300)
        .foregroundStyle(KKColor.textPrimary)
        .background(KKColor.surfaceBase)
        .buttonStyle(KKQuietButtonStyle())
        .kkNeutralControls()
    }
}
