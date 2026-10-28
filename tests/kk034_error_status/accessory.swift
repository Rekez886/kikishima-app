import AppKit
import SwiftUI

@main
struct AccessoryTest {
    @MainActor static func main() {
        let widths = CommandLine.arguments.dropFirst().compactMap(Double.init)
        precondition(widths.count == 2)
        // Execute both mismatches before asserting, so the baseline log records A and B.
        var changedSettingResults: [CGSize] = []
        for builtAsIsland in [false, true] {
            let window = CaptionMinimumSizePanel(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 320),
                styleMask: builtAsIsland ? [.borderless, .resizable, .nonactivatingPanel] :
                    [.titled, .closable, .resizable, .nonactivatingPanel],
                backing: .buffered, defer: false)
            configureResizePanel(window, island: builtAsIsland)
            window.contentView = NSHostingView(rootView: Color.clear.frame(minWidth: 300, minHeight: 50))
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            let delegate = ResizeDelegate()
            delegate.usesIsland = !builtAsIsland
            window.delegate = delegate
            let result = delegate.windowWillResize(window, to: CGSize(width: 200, height: 60))
            print("R7B case \(builtAsIsland ? "B" : "A"): builtIsland=\(builtAsIsland), currentIsland=\(delegate.usesIsland), request=200x60, result=\(result)")
            changedSettingResults.append(result)
        }
        fflush(stdout)
        precondition(changedSettingResults[0] == CaptionDesktopStatusLayout.minimumSize,
                     "r7b A: built desktop must clamp after settings switch to island")
        precondition(changedSettingResults[1] == CGSize(width: 200, height: 60),
                     "r7b B: built island must not clamp after settings switch to desktop")
        precondition(resizeUsesBuiltWindow, "delegate must read sender build identity, not current settings")
        let unrelated = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 320),
                                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let unrelatedDelegate = ResizeDelegate()
        precondition(unrelatedDelegate.windowWillResize(unrelated, to: CGSize(width: 200, height: 60)) ==
                     CGSize(width: 200, height: 60), "unrelated window must pass through")
        let compactPanel = CaptionMinimumSizePanel(
            contentRect: NSRect(x: 0, y: 0, width: widths[1], height: 320),
            styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        configureResizePanel(compactPanel, island: false)
        compactPanel.minSize = CaptionDesktopStatusLayout.minimumSize
        compactPanel.contentView = NSHostingView(rootView: Color.clear.frame(minWidth: 300, minHeight: 50))
        compactPanel.contentView?.superview?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        let compactDelegate = ResizeDelegate()
        compactPanel.delegate = compactDelegate
        CaptionState.shared.compactCaptions = true
        let compactDrag = compactDelegate.windowWillResize(compactPanel, to: CGSize(width: 200, height: 60))
        print("COMPACT minSize=\(compactPanel.minSize), contentMinSize=\(compactPanel.contentMinSize), request=200x60, result=\(compactDrag)")
        fflush(stdout)
        precondition(compactDrag.width >= CaptionDesktopStatusLayout.minimumSize.width &&
                     compactDrag.height >= CaptionDesktopStatusLayout.minimumSize.height,
                     "KK-034 r7: compact live resize bypasses desktop minimum")
        compactPanel.setFrame(NSRect(x: 0, y: 0, width: 200, height: 60), display: false)
        precondition(compactPanel.frame.width >= CaptionDesktopStatusLayout.minimumSize.width &&
                     compactPanel.frame.height >= CaptionDesktopStatusLayout.minimumSize.height)
        let islandPanel = CaptionMinimumSizePanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        configureResizePanel(islandPanel, island: true)
        let islandDelegate = ResizeDelegate()
        islandDelegate.usesIsland = true
        islandPanel.delegate = islandDelegate
        let islandDrag = islandDelegate.windowWillResize(islandPanel, to: CGSize(width: 200, height: 60))
        precondition(islandDrag == CGSize(width: 200, height: 60), "island delegate must not clamp")
        islandPanel.setFrame(NSRect(x: 0, y: 0, width: 200, height: 60), display: false)
        precondition(islandPanel.frame.size == CGSize(width: 200, height: 60), "island setFrame must not clamp")
        print("PASS compact live/programmatic minimum; island remains 200x60")
        CaptionState.shared.compactCaptions = false
        let mask: NSWindow.StyleMask = [.titled, .closable, .resizable, .nonactivatingPanel]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let panel = CaptionMinimumSizePanel(contentRect: NSRect(x: 0, y: 0, width: widths[1], height: 320),
                                styleMask: mask, backing: .buffered, defer: false)
            configureResizePanel(panel, island: false)
            panel.minSize = CaptionDesktopStatusLayout.minimumSize
            // Reproduce the production hosting-view minimum overwrite without showing a window.
            panel.contentView = NSHostingView(rootView: Color.clear.frame(minWidth: 300, minHeight: 50))
            panel.contentView?.superview?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            print("Hosting layout overwrote minSize: \(panel.minSize), contentMinSize: \(panel.contentMinSize)")
            precondition(panel.minSize.width < CaptionDesktopStatusLayout.minimumSize.width,
                         "fixture must reproduce hosting minimum overwrite")
            let drag = CaptionDesktopResizePolicy.constrained(CGSize(width: 200, height: 60))
            precondition(drag.width >= CaptionDesktopStatusLayout.minimumSize.width &&
                         drag.height >= CaptionDesktopStatusLayout.minimumSize.height)
            precondition(CaptionDesktopResizePolicy.constrained(CGSize(width: 780, height: 320)) == CGSize(width: 780, height: 320))
            print("PASS live resize request 200x60 -> \(drag), independent of overwritten minSize")
            panel.title = "Captions"
            panel.titlebarAppearsTransparent = true
            panel.appearance = NSAppearance(named: appearance)
            let sample = NSRect(x: 0, y: 0, width: widths[1], height: 320)
            let height = sample.height - NSWindow.contentRect(forFrameRect: sample,
                styleMask: [.titled, .closable, .resizable]).height
            let host = NSHostingView(rootView: HStack(spacing: 6) {
                ForEach(0..<5) { _ in Color.clear.frame(width: 28, height: 28) }
            }.frame(width: CaptionDesktopStatusLayout.toolbarWidth, height: height))
            CaptionTitlebarAccessory.install(on: panel, view: host, titlebarHeight: height)
            precondition(host.frame.size == NSSize(width: CaptionDesktopStatusLayout.toolbarWidth, height: height))
            // Test narrowing and widening the same installed hosting view.
            for width in widths + widths.reversed() {
                panel.setFrame(NSRect(x: 0, y: 0, width: width, height: 320), display: false)
                panel.contentView?.superview?.layoutSubtreeIfNeeded()
                host.layoutSubtreeIfNeeded()
                let rect = host.convert(host.bounds, to: nil)
                guard host.superview != nil else {
                    print("UNAVAILABLE offscreen AppKit titlebar layout; helper frame verified")
                    panel.setFrame(NSRect(x: 0, y: 0, width: 100, height: 320), display: false)
                    print("AppKit minimum frame width: \(panel.frame.width)")
                    exit(77)
                }
                let bounds = NSRect(origin: .zero, size: panel.frame.size)
                precondition(bounds.insetBy(dx: -1, dy: -1).contains(rect), "accessory outside window")
                precondition(abs(rect.width - CaptionDesktopStatusLayout.toolbarWidth) <= 0.01)
                precondition(abs(rect.maxX - bounds.maxX) <= 1, "right edge")
                precondition(!rect.intersects(panel.contentLayoutRect), "over content")
                for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    if let button = panel.standardWindowButton(kind) {
                        precondition(!rect.intersects(button.convert(button.bounds, to: nil)), "over traffic lights")
                    }
                }
                func textFields(_ view: NSView) -> [NSTextField] {
                    (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(textFields)
                }
                let titles = textFields(panel.contentView!.superview!).filter { $0.stringValue == panel.title }
                precondition(!titles.isEmpty, "AppKit title layout unavailable")
                for title in titles {
                    let titleRect = title.convert(title.bounds, to: nil)
                    precondition(!titleRect.intersects(rect), "title overlaps toolbar")
                    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                        if let button = panel.standardWindowButton(kind) {
                            precondition(!titleRect.intersects(button.convert(button.bounds, to: nil)), "title overlaps lights")
                        }
                    }
                }
                for textWidth: CGFloat in [20, 2000] {
                    let layout = CaptionDesktopStatusLayout(width: width, height: 320, compact: false,
                        titlebarHeight: height, statusHeight: 18, hasStatus: true, leadingInset: 32)
                    precondition(layout.status.minY == height + 4 && layout.status.height == 28)
                    let inline = CaptionStatusInlineGeometry(width: layout.status.width, height: layout.status.height,
                        textWidth: textWidth, actionWidth: 28)
                    let action = inline.action.offsetBy(dx: layout.status.minX, dy: layout.status.minY)
                    precondition(action.size == CGSize(width: 28, height: 28) && layout.status.contains(action))
                    precondition(action.minY >= height + 4 && action.maxX <= width - 32)
                    precondition(inline.action.minX == inline.text.maxX + CaptionStatusInlineGeometry.gap)
                    precondition(layout.captions.minY == layout.status.maxY)
                    if textWidth == 20 { precondition(inline.action.maxX < layout.status.width) }
                    else { precondition(inline.text.width < textWidth) }
                    print("PASS status \(appearance.rawValue) width=\(width) text=\(textWidth) action=\(action)")
                }
                print("PASS accessory \(appearance.rawValue) width=\(width) rect=\(rect)")
            }
            panel.setFrame(NSRect(x: 0, y: 0, width: 100, height: 320), display: false)
            precondition(panel.frame.width >= CaptionDesktopStatusLayout.minimumSize.width)
            print("AppKit minimum frame width (\(appearance.rawValue)): \(panel.frame.width)")
        }
    }
}
