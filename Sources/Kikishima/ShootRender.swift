#if SHOOT || DEBUG
#if SCREENSHOT_DIFF
import AppKit
import SwiftUI
import QuartzCore

/// Pure pixel convergence policy, tested without creating an app or window.
struct ShootRenderStability {
    static let limit = 40
    private struct Frame: Equatable {
        let width: Int
        let height: Int
        let pixels: Data
    }
    private var previous: Frame?
    private(set) var observations = 0
    mutating func observe(_ pixels: Data, width: Int, height: Int, hasContent: Bool) -> Bool {
        let frame = Frame(width: width, height: height, pixels: pixels)
        observations += 1
        defer { previous = frame }
        return hasContent && previous == frame
    }
}

/// Process-local render preferences; no persistent domain reads or writes.
enum ShootRenderPreferences {
    /// No preferences/Locale fallback: explicit process arguments are the source.
    static func argumentDomain(arguments: [String]) -> [String: Any]? {
        func argument(_ key: String) -> String? { ShootSimulation.argument(key, in: arguments) }
        guard let raw = argument("-AppleLanguages"),
              !raw.trimmingCharacters(in: CharacterSet(charactersIn: "()[]\" ")).split(separator: ",").isEmpty,
              let appearance = argument("-AppleInterfaceStyle"),
              ["Light", "Dark"].contains(appearance) else { return nil }
        let language = ShootSimulation.selectedInterfaceLanguage(arguments: arguments, saved: "")
        let locale = argument("-KikishimaMeetingLanguage") ?? (language == "ja" ? "en_US" : "ja_JP")
        let target = argument("-KikishimaCaptionLanguage") ?? (language == "ja" ? "Japanese" : "English")
        return [
            "uiLanguage": language, "AppleLanguages": [language], "AppleInterfaceStyle": appearance,
            "locale": locale, "targetLang": target, "meetingLocales": [locale],
            "autoDownloadModels": false, "meetingSummaryConsent": "disabled",
            "compactCaptions": false, "captionDisplay": "both", "chunkLength": "medium",
            "captionFontFamily": "system", "captionFontLevel": "medium", "zhFont": 18.0,
            "captionWidthLevel": "medium", "captionWidthFraction": 0.5,
            "islandHeightLevel": "medium", "islandHeight": 148.0,
            "islandCollapseLevel": "off", "islandAutoCollapse": 0.0, "captionOpacity": 1.0,
            "captionSurface": "window", "captionSurfaceNotchDefaultV1": true,
            "captionSurfaceUserSelected": true, "captionUserAdjusted": false,
            "captionClickThrough": false, "captionsInScreenShare": false, "islandEngine": "panel"
        ]
    }
}

/// Only the dedicated screenshot-diff build enables this entry. Never orders a window.
@MainActor
enum ShootRender {
    static func runIfRequested() -> Bool {
        guard let output = ProcessInfo.processInfo.environment["KIKISHIMA_SHOOT_RENDER"] else { return false }
        do {
            guard Bundle.main.bundleIdentifier == "com.kikishima.mac.shotdiff",
                  let mode = ShootSimulation.requestedMode,
                  let placement = ShootSimulation.argument("-KikishimaShotPlacement"),
                  ["desktop", "island", "menu", "main"].contains(placement) else {
                throw RenderError.invalidArguments
            }
            // Install before NSApplication, CaptionState or localization reads.
            // Both observed UI state and trAny now read this process's language;
            // saved preferences and other rendering processes cannot override it.
            guard let defaults = ShootRenderPreferences.argumentDomain(arguments: ProcessInfo.processInfo.arguments) else {
                throw RenderError.invalidArguments
            }
            UserDefaults.standard.setVolatileDomain(defaults, forName: UserDefaults.argumentDomain)
            let app = NSApplication.shared
            guard app.setActivationPolicy(.prohibited) else { throw RenderError.activationPolicy }
            ShootSimulation.applyRequestedAppearance()
            let state = CaptionState.shared
            ShootSimulation.configure(state, mode: mode)
            if placement == "island", !state.wantsIslandExpanded {
                let reason = "收起态岛的尺寸和外观依赖真实刘海及宿主，离屏 idleSize(notchWidth: 0) 不忠实，须实机验证。"
                let data = try JSONSerialization.data(withJSONObject: ["reason": reason], options: [.sortedKeys])
                fputs("KIKISHIMA_SHOTDIFF_DEVICE_ONLY " + String(decoding: data, as: UTF8.self) + "\n", stderr)
                exit(3)
            }
            let contentSize: () -> NSSize
            let root: AnyView
            if placement == "desktop" {
                contentSize = { NSSize(width: 780, height: 320) }
                root = AnyView(CaptionFeedView(state: state))
            } else if placement == "menu" {
                contentSize = { NSSize(width: 304, height: 1000) }
                root = AnyView(MenuContent(state: state, isPresented: .constant(true)))
            } else if placement == "main" {
                contentSize = { NSSize(width: 960, height: 900) }
                root = AnyView(MainWindowView())
            } else {
                let display = IslandDisplayContext()
                // Synthetic dimensions cannot reproduce actual screen/notch geometry.
                // Actual geometry and host are separately listed as device-only items.
                display.visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
                display.reduceMotion = true
                display.hostSideInset = 15
                contentSize = {
                    let content = IslandExpandedView.expandedSize(in: display.visibleFrame, measured: display.measuredHeight)
                    // Match IslandExpandedView.body, not just its text viewport:
                    // the floating toolbar adds 24pt to an expanded 64pt column.
                    // NotchlessView's outer 15pt sides / 8pt top / 15pt bottom
                    // belong to the device-only host, not this content snapshot.
                    let extra = state.wantsIslandExpanded
                        ? CaptionIslandToolbarLayout.extraHeight(notchHeight: display.toolbarNotchHeight) : 0
                    return NSSize(width: ceil(content.width + 30 - display.hostSideInset * 2),
                                  height: ceil(content.height + extra))
                }
                root = AnyView(IslandExpandedView(state: state, display: display))
            }
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize()),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.hasShadow = false
            window.appearance = app.appearance
            // Same production token and opacity as CaptionPanelController.build().
            // cacheDisplay captures the view, not NSWindow's composited background:
            // use that resolved window color as the host's SwiftUI background too.
            window.backgroundColor = ["menu", "main"].contains(placement) ? NSColor(KKColor.surfaceBase) : placement == "desktop"
                ? NSColor(KKColor.captionWindowBackground).withAlphaComponent(state.captionOpacity)
                : NSColor(KKColor.notchBackground)
            let host = NSHostingView(rootView: root
                .background(Color(nsColor: window.backgroundColor))
                .environment(\.colorScheme, ShootSimulation.argument("-AppleInterfaceStyle") == "Dark" ? .dark : .light)
                .transaction { $0.animation = nil; $0.disablesAnimations = true })
            window.contentView = host
            host.appearance = window.appearance
            // No orderFront, makeKey or app activation anywhere in this lifecycle.
            guard !window.isVisible else { throw RenderError.visibleWindow }
            defer { window.close() }
            var convergence = ShootRenderStability()
            for _ in 0..<ShootRenderStability.limit {
                let deadline = Date(timeIntervalSinceNow: 0.025)
                repeat { _ = RunLoop.main.run(mode: .default, before: deadline) }
                while Date() < deadline
                guard !window.isVisible else { throw RenderError.visibleWindow }
                // IslandDisplayContext.measure publishes on the next main-loop turn.
                // Recompute the production column + toolbar dimensions each turn.
                let size = contentSize()
                window.setContentSize(size)
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                CATransaction.flush()
                // Explicit 2x RGBA backing, independent of the attached display.
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0),
                    let bytes = rep.bitmapData else { throw RenderError.bitmap }
                rep.size = size
                let count = rep.bytesPerRow * rep.pixelsHigh
                bytes.initialize(repeating: 0, count: count)
                // Assert again immediately before every readback, after layout callbacks.
                guard !window.isVisible else { throw RenderError.visibleWindow }
                if placement == "island" {
                    let expected = contentSize()
                    let fitted = host.fittingSize
                    guard host.bounds.size == expected,
                          ceil(fitted.width) == expected.width,
                          ceil(fitted.height) == expected.height,
                          rep.pixelsWide == Int(expected.width * 2),
                          rep.pixelsHigh == Int(expected.height * 2) else {
                        throw RenderError.sizeMismatch("island expected=\(expected) host=\(host.bounds.size) fitting=\(fitted) bitmap=\(rep.pixelsWide)x\(rep.pixelsHigh)")
                    }
                }
                host.cacheDisplay(in: host.bounds, to: rep)
                // AppKit cacheDisplay requires the default premultiplied alpha
                // representation (r4 probe). Exclude any allocator row padding
                // from convergence and blank detection. PNG comparison separately
                // decodes the exported PNG into straight RGBA bytes.
                var pixels = Data(capacity: rep.pixelsWide * rep.pixelsHigh * 4)
                for row in 0..<rep.pixelsHigh {
                    pixels.append(bytes.advanced(by: row * rep.bytesPerRow), count: rep.pixelsWide * 4)
                }
                // Two equal blank frames are not evidence of a finished SwiftUI tree.
                var hasAlpha = false
                var varies = false
                for i in stride(from: 0, to: pixels.count, by: 4) {
                    if pixels[i + 3] != 0 { hasAlpha = true }
                    if pixels[i] != pixels[0] || pixels[i + 1] != pixels[1]
                        || pixels[i + 2] != pixels[2] || pixels[i + 3] != pixels[3] { varies = true }
                }
                if convergence.observe(pixels, width: rep.pixelsWide, height: rep.pixelsHigh,
                                       hasContent: hasAlpha && varies) {
                    guard let png = rep.representation(using: .png, properties: [:]) else { throw RenderError.bitmap }
                    try png.write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
                    fputs("ShootRender samples=\(convergence.observations) stable size=\(rep.pixelsWide)x\(rep.pixelsHigh) scale=2 windowVisible=false\n", stderr)
                    return true
                }
            }
            fputs("ShootRender samples=\(convergence.observations) unstable (no consecutive equal dimensions and nonblank pixels)\n", stderr)
            throw RenderError.unstable
        } catch {
            fputs("ShootRender: \(error)\n", stderr)
            exit(1)
        }
    }
    private enum RenderError: Error {
        case invalidArguments, activationPolicy, bitmap, visibleWindow, unstable
        case sizeMismatch(String)
    }
}
#endif
#endif
