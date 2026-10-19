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
                let samples: [SidebarAccountSummary] = [
                    .init(tier: .signedOut),
                    .init(tier: .free, email: "long.sample.address@example.com", remainingMinutes: 42, remainingDescription: "42"),
                    .init(tier: .pro, email: "sample@example.com", usageDescription: tr("本月已用约 %@ 分钟", "303")),
                    .init(tier: .pro, email: "sample@example.com", paidTitle: tr("试用中 · 还剩 %@ 天", "7")),
                    .init(tier: .free, email: "sample@example.com", remainingMinutes: 0, remainingDescription: "<1"),
                    .init(tier: .free, email: "sample@example.com")
                ]
                let row = VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                    ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                        VStack(spacing: 0) {
                            SidebarBrandRow()
                            SidebarNavigation(selection: .constant(.captions))
                            Spacer(minLength: 16)
                            SidebarAccountCard(summary: sample, login: {}, upgrade: {}, redeemInvite: {}, signOut: {})
                                .padding(10)
                        }
                        .frame(width: 190, height: 640)
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                    }
                    // TranslateFailure cases whose live banner action is .upgrade:
                    // paymentRequired, quotaExceeded, freePoolExhausted.
                    HStack(alignment: .top, spacing: 16) {
                        ForEach([
                            tr("需要订阅 Pro 才能继续翻译"),
                            tr("本周免费额度已用完，%@ 重置", "2026-10-19"),
                            tr("今日免费额度已被用完，明天再来，或升级 Pro 不受影响")
                        ], id: \.self) { message in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                                Button(tr("升级 Pro")) {}.kkPrimaryButton()
                            }.padding(16).frame(width: 380, height: 160, alignment: .topLeading)
                                .background(KKColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }.padding(16).environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: row)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = NSSize(width: 1252, height: 848)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: rep)
                let path = ".build/sidebar-preview/\(lang)-\(dark ? "dark" : "light").png"
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
                window.close()
            }
        }
        print("Rendered 6 synthetic account variants (signedOut/free/pro, trial, quota exhausted, usage unknown) and 3 upgrade failure cases in 5 languages, light and dark")
    }
}
