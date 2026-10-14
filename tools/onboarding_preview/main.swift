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
                    ForEach(0..<4) { variant in
                        VStack(spacing: 0) {
                            ScrollView {
                                Group {
                                    if variant == 0 {
                                        OnboardingWelcome(privacy: tr("音频只在本机转写，从不上传。转写出的文字、前一句上下文、术语表和会议称呼会发送到 Kikishima 服务器，并转交 AI 模型服务用于翻译和生成会议总结；服务器不保存内容。会议记录与总结只存在你的 Mac 上。"))
                                    } else if variant == 1 {
                                        VStack(alignment: .leading, spacing: 14) {
                                            Text(tr("你最熟悉的语言是哪一个？")).font(.title2.bold())
                                            Text(tr("界面和字幕译文都会用这个语言。之后随时能改。"))
                                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))]) {
                                                ForEach(["简体中文", "繁體中文", "日本語", "English", "한국어"], id: \.self) { name in
                                                    LanguageChoiceTile(title: name, selected: name == "日本語", action: {})
                                                }
                                            }
                                        }.padding(30)
                                    } else if variant == 2 {
                                        VStack(alignment: .leading, spacing: 14) {
                                            Text(tr("登录")).font(.title2.bold())
                                            Text(tr("免费版每周 60 分钟，登录即用，不需要信用卡。"))
                                            SignInTile(title: tr("使用 Google 登录"), icon: "globe", action: {})
                                            SignInTile(title: tr("通过 Apple 登录"), icon: "apple.logo", action: {})
                                            SignInTile(title: tr("使用邮箱登录"), icon: "envelope", action: {})
                                            TextField(tr("邮箱"), text: .constant("sample@example.com"))
                                                .textFieldStyle(.roundedBorder)
                                        }.padding(30)
                                    } else {
                                        VStack(alignment: .leading, spacing: 14) {
                                            Text(tr("可以开会了")).font(.title2.bold())
                                            HomeCaptionPreview(source: "Let's review the next steps together.",
                                                translation: HomeCaptionPreview.sampleTranslation(for: "Japanese"), status: "",
                                                compact: true, display: "both", desktop: false, isExample: true)
                                            Text(tr("会议是日语或其他语言？在「打开 Kikishima」里改会议语言。人名、产品名总被翻错？把它们加进术语表。"))
                                            Button(tr("现在就试一下（开始字幕）")) {}.buttonStyle(.borderedProminent)
                                        }.padding(30)
                                    }
                                }.frame(maxWidth: .infinity, minHeight: 404)
                            }
                            HStack {
                                Button(tr("上一步")) {}
                                Spacer()
                                Text("\(variant + 1) / 6").foregroundStyle(.secondary)
                                Spacer()
                                Button(tr("下一步")) {}.buttonStyle(.borderedProminent)
                            }.padding(16).background(Color.primary.opacity(0.03))
                        }.frame(width: 540, height: 460)
                            .background(Color(nsColor: .windowBackgroundColor))
                    }
                }.padding(16).environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: row)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = NSSize(width: 2240, height: 492)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: rep)
                let path = ".build/onboarding-preview/\(lang)-\(dark ? "dark" : "light").png"
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
                window.close()
            }
        }
        print("Rendered 4 synthetic onboarding variants in 5 languages, light and dark")
    }
}
