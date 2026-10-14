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

@main struct Preview: App {
    init() {
        let args = ["render"] + (ProcessInfo.processInfo.environment["KIKISHIMA_PREVIEW_CASE"] ?? "zh-Hans free light").split(separator: " ").map(String.init)
        let lang = args.count > 1 ? args[1] : "zh-Hans"
        if lang != "zh-Hans" {
            translations = (try? JSONDecoder().decode([String: String].self,
                from: Data(contentsOf: URL(fileURLWithPath: "Resources/l10n/\(lang).json")))) ?? [:]
        }
        let state = CaptionState.shared
        let tier = args.count > 2 ? args[2] : "free"
        state.sessionToken = tier == "signedOut" ? "" : "fixture"
        state.plan = tier == "pro" ? "pro" : "free"
        state.running = args.contains("dark")
        state.visibleCaptionChunks = state.running ? [.init()] : []
    }

    var body: some Scene {
        Window("Kikishima — synthetic UI preview", id: "main") {
            MainWindowView()
                .preferredColorScheme((ProcessInfo.processInfo.environment["KIKISHIMA_PREVIEW_CASE"] ?? "").contains("dark") ? .dark : .light)
                .task { await verifyWindow() }
        }
        .defaultSize(width: 960, height: 620)
    }

    @MainActor private func verifyWindow() async {
        do {
            try await Task.sleep(for: .milliseconds(600))
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }),
                  let host = window.contentView else { throw NSError(domain: "MissingWindow", code: 1) }
            let dark = (ProcessInfo.processInfo.environment["KIKISHIMA_PREVIEW_CASE"] ?? "").contains("dark")
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let fixtureName = (ProcessInfo.processInfo.environment["KIKISHIMA_PREVIEW_CASE"] ?? "default").replacingOccurrences(of: " ", with: "-")
            window.setContentSize(NSSize(width: 780, height: 520))
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(500))
            func splitHost(_ view: NSView) -> NSView? {
                if String(describing: type(of: view)).contains("NavigationSplitRepresentable") { return view }
                return view.subviews.lazy.compactMap { splitHost($0) }.first
            }
            guard let split = splitHost(host) else { throw NSError(domain: "MissingSplit", code: 1) }
            let rect = split.convert(split.bounds, to: host)
            let geometry = "host=\(host.bounds) split=\(rect)\n"
            try geometry.write(toFile: ".build/window-preview/\(fixtureName)-geometry.txt", atomically: true, encoding: .utf8)
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), ".build/window-preview/\(fixtureName).png"]
            try capture.run()
            capture.waitUntilExit()
            guard capture.terminationStatus == 0 else { throw NSError(domain: "CaptureFailed", code: 1) }
            guard rect.minY >= -1, rect.maxY <= host.bounds.height + 1 else {
                throw NSError(domain: "PreviewLayoutOverflow", code: 1, userInfo: [NSLocalizedDescriptionKey: geometry])
            }
            print("PASS: SwiftUI Window scene", geometry)
            exit(0)
        } catch {
            print("FAIL:", error)
            exit(1)
        }
    }
}
