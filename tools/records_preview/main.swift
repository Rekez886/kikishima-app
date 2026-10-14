import SwiftUI
import AppKit

// Standalone fixture renderer: no account, Keychain, calendar or network access.
private var translations: [String: String] = [:]
func tr(_ key: String, _ args: Any...) -> String {
    var result = translations[key] ?? key
    for argument in args {
        if let range = result.range(of: "%@") {
            result.replaceSubrange(range, with: String(describing: argument))
        }
    }
    return result
}

struct TranscriptFile {
    var url: URL
    var name: String { url.deletingPathExtension().lastPathComponent }
    var date: Date { Date(timeIntervalSince1970: 1_789_488_000) }
}
@main struct Preview {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        for lang in ["zh-Hans", "en", "ja", "ko", "zh-Hant"] {
            if lang == "zh-Hans" { translations = [:] }
            else {
                translations = try JSONDecoder().decode([String:String].self,
                    from: Data(contentsOf: URL(fileURLWithPath: "Resources/l10n/\(lang).json")))
            }
            for dark in [false, true] {
                let refs = (0..<5).map { SummarySourceRef(segmentID: "s\($0)", startSeconds: $0 * 90) }
                let content = MeetingSummaryContent(
                    overview: [.init(id: "overview", text: "A long meeting summary to verify narrow document layout. 次のリリースに向けて、字幕と会議記録の動作を確認します。", sourceRefs: refs)],
                    currentState: [.init(id: "current", text: "Implementation is ready for review.", sourceRefs: [])],
                    decisions: [.init(id: "decision", text: "Keep the current release scope.", sourceRefs: [])],
                    actionItems: [.init(id: "action", text: "Review the translated captions.", owner: "Sample person", deadline: "Friday", sourceRefs: [])],
                    personalItems: [], openQuestions: [])
                let row = HStack(alignment: .top, spacing: 16) {
                    ForEach(0..<4) { variant in
                        let document = MeetingSummaryDocument(recordID: "fixture", transcriptFileName: "sample.md",
                            content: content, sourceIndex: [:], processedThrough: nil, schemaVersion: 1,
                            promptVersion: "fixture", sourceFingerprint: nil, updatedAt: .now,
                            isFinal: variant == 0, status: variant == 0 ? .finished : variant == 1 ? .interrupted : .active)
                        MeetingSummaryDetailView(
                            transcript: .init(url: URL(fileURLWithPath: "/tmp/週次ミーティング — Caption review.md")),
                            document: variant == 3 ? nil : document, canRetry: variant == 1, onRetry: {})
                            .frame(width: 300, height: 650)
                            .background(Color(nsColor: .windowBackgroundColor))
                    }
                }.padding(16).environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: row)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = NSSize(width: 1280, height: 682)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: rep)
                let path = ".build/records-preview/\(lang)-\(dark ? "dark" : "light").png"
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
                window.close()
            }
        }
        print("Rendered 4 synthetic summary variants in 5 languages, light and dark")
    }
}
