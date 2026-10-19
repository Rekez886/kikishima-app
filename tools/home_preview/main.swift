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
                let row = HStack(alignment: .top, spacing: 16) {
                    ForEach(0..<3) { variant in
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Kikishima").font(.system(size: 28, weight: .bold))
                            Text(variant == 0 ? tr("就绪") : tr("暂停字幕")).font(.system(size: 13)).foregroundStyle(KKColor.textSecondary)
                            HomeCaptionPreview(source: "Let's review the next steps together.",
                                translation: HomeCaptionPreview.sampleTranslation(for: lang == "ja" ? "Japanese" : "Simplified Chinese"),
                                status: tr("暂停字幕"), compact: variant == 0,
                                display: variant == 1 ? "translation" : "both", desktop: variant == 2,
                                isExample: variant == 0)
                            HomeCaptionControls(active: variant != 0, running: variant != 0,
                                paused: true, transition: false, compact: .constant(variant == 0),
                                display: .constant("both"), toggle: {}, pause: {})
                            Spacer()
                        }.padding(28).frame(width: 480, height: 450)
                            .background(Color(nsColor: .windowBackgroundColor))
                    }
                }.padding(16).environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: row)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = NSSize(width: 1504, height: 482)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: rep)
                let path = ".build/home-preview/\(lang)-\(dark ? "dark" : "light").png"
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
                window.close()
            }
        }
        print("Rendered 3 synthetic home variants in 5 languages, light and dark")
    }
}
