import Foundation
import CoreGraphics

/// Every assignment is a new occurrence, including the same error after Esc.
struct CaptionErrorStatusVisibility {
    private(set) var isVisible = true
    mutating func receive() { isVisible = true }
    mutating func dismiss() { isVisible = false }
}

/// Top-origin window geometry. Hover never changes reserved space.
struct CaptionDesktopStatusLayout {
    static let minimumSize = CGSize(width: 360, height: 90)
    static let statusRowHeight: CGFloat = 28
    static let compactHeaderHeight: CGFloat = 28
    // Five existing 28pt controls, four 6pt gaps, two 8pt insets on each side.
    static let toolbarWidth: CGFloat = 5 * 28 + 4 * 6 + 4 * 8
    let headerHeight: CGFloat
    let toolbar: CGRect
    let status: CGRect
    let captions: CGRect

    init(width: CGFloat, height: CGFloat, compact: Bool, titlebarHeight: CGFloat,
         statusHeight: CGFloat, hasStatus: Bool, leadingInset: CGFloat, statusTopInset: CGFloat = 4) {
        headerHeight = compact ? Self.compactHeaderHeight : titlebarHeight
        toolbar = CGRect(x: max(0, width - Self.toolbarWidth), y: 0,
                         width: min(width, Self.toolbarWidth), height: headerHeight)
        status = CGRect(x: leadingInset, y: compact ? 0 : headerHeight + (hasStatus ? statusTopInset : 0),
                        width: max(0, (compact ? toolbar.minX : width - leadingInset) - leadingInset),
                        height: compact ? headerHeight : (hasStatus ? Self.statusRowHeight : 0))
        let captionTop = compact ? headerHeight : status.maxY
        captions = CGRect(x: 0, y: captionTop, width: width, height: max(0, height - captionTop))
    }
}

/// Measured text shrinks before its action. The action follows the actual text
/// width, not the trailing edge of the available status region.
struct CaptionStatusInlineGeometry {
    static let gap: CGFloat = 10
    let dot: CGRect
    let text: CGRect
    let action: CGRect
    init(width: CGFloat, height: CGFloat, textWidth: CGFloat, actionWidth: CGFloat) {
        let dotWidth = min(6, max(0, width))
        let actionWidth = min(actionWidth, max(0, width - dotWidth - 2 * Self.gap))
        let textWidth = min(textWidth, max(0, width - dotWidth - 2 * Self.gap - actionWidth))
        dot = CGRect(x: 0, y: (height - 6) / 2, width: dotWidth, height: 6)
        text = CGRect(x: dotWidth + Self.gap, y: 0, width: textWidth, height: height)
        action = CGRect(x: text.maxX + Self.gap, y: 0, width: actionWidth, height: height)
    }
}

// AppKit lays out a right accessory using its NSView frame, not SwiftUI's frame.
import AppKit

@MainActor
enum CaptionTitlebarAccessory {
    static func install(on window: NSWindow, view: NSView, titlebarHeight: CGFloat) {
        let accessory = NSTitlebarAccessoryViewController()
        view.frame = NSRect(x: 0, y: 0, width: CaptionDesktopStatusLayout.toolbarWidth,
                            height: titlebarHeight)
        view.autoresizingMask = []
        // Keep the hosting view's measured size from collapsing during resize.
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: CaptionDesktopStatusLayout.toolbarWidth),
            view.heightAnchor.constraint(equalToConstant: titlebarHeight)
        ])
        accessory.view = view
        accessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(accessory)
    }
}

/// Independent of NSHostingView's mutable window minSize/contentMinSize.
enum CaptionDesktopResizePolicy {
    static func constrained(_ proposed: CGSize) -> CGSize {
        let minimum = CaptionDesktopStatusLayout.minimumSize
        return CGSize(width: max(proposed.width, minimum.width),
                      height: max(proposed.height, minimum.height))
    }
}

/// NSWindow.minSize limits interactive resizing; setFrame can bypass it.
/// Keep restored/programmatic frames within the same desktop minimum.
class CaptionMinimumSizePanel: NSPanel {
    // Default to unbounded until build() identifies the surface, including during init.
    var isIslandPanel = true
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if !isIslandPanel {
            frame.size = CaptionDesktopResizePolicy.constrained(frame.size)
        }
        super.setFrame(frame, display: flag)
    }
}
