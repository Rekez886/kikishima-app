import CoreGraphics
import Foundation

/// Discrete caption chrome: sliders reflow the island on every tick and flicker
/// during live translation. Small / medium / large (and off / fast / medium / slow
/// for auto-collapse) change the geometry once per click.
enum CaptionSizeLevel: String, CaseIterable {
    case small, medium, large
}

enum CaptionCollapseLevel: String, CaseIterable {
    case off, fast, medium, slow
}

enum CaptionAppearance {
    static func wantsExpanded(hasContent: Bool, dormant: Bool, paused: Bool, hasBanner: Bool) -> Bool {
        hasContent && (!dormant || paused || hasBanner)
    }

    static let fontLevelKey = "captionFontLevel"
    static let widthLevelKey = "captionWidthLevel"
    static let heightLevelKey = "islandHeightLevel"
    static let collapseLevelKey = "islandCollapseLevel"

    static func fontSize(_ level: CaptionSizeLevel) -> Double {
        switch level {
        case .small: 15
        case .medium: 18
        case .large: 26
        }
    }

    static func widthFraction(_ level: CaptionSizeLevel) -> Double {
        switch level {
        case .small: 0.26
        case .medium: 0.50
        case .large: 0.80
        }
    }

    static func islandHeight(_ level: CaptionSizeLevel) -> Double {
        switch level {
        case .small: 100
        case .medium: 148
        case .large: 240
        }
    }

    static func collapseSeconds(_ level: CaptionCollapseLevel) -> Double {
        switch level {
        case .off: 0
        case .fast: 4
        case .medium: 8
        case .slow: 16
        }
    }

    static func parseSize(_ raw: String?) -> CaptionSizeLevel? {
        raw.flatMap(CaptionSizeLevel.init(rawValue:))
    }

    static func parseCollapse(_ raw: String?) -> CaptionCollapseLevel? {
        raw.flatMap(CaptionCollapseLevel.init(rawValue:))
    }

    static func snapFont(points: Double) -> CaptionSizeLevel {
        if points <= 0 { return .medium }
        if points < 17 { return .small }
        if points >= 23 { return .large }
        return .medium
    }

    static func snapWidth(fraction: Double) -> CaptionSizeLevel {
        if fraction <= 0 { return .medium }
        if fraction < 0.38 { return .small }
        if fraction >= 0.66 { return .large }
        return .medium
    }

    static func snapHeight(points: Double) -> CaptionSizeLevel {
        if points <= 0 { return .medium }
        if points < 124 { return .small }
        if points >= 190 { return .large }
        return .medium
    }

    static func snapCollapse(seconds: Double) -> CaptionCollapseLevel {
        if seconds <= 0 { return .off }
        if seconds <= 5 { return .fast }
        if seconds >= 13 { return .slow }
        return .medium
    }

    static func storedFontLevel(fontLevel: String?, fontPoints: Double) -> CaptionSizeLevel {
        parseSize(fontLevel) ?? snapFont(points: fontPoints)
    }

    static func storedWidthLevel(widthLevel: String?, fraction: Double?) -> CaptionSizeLevel {
        parseSize(widthLevel) ?? snapWidth(fraction: fraction ?? 0)
    }

    static func storedHeightLevel(heightLevel: String?, points: Double?) -> CaptionSizeLevel {
        parseSize(heightLevel) ?? snapHeight(points: points ?? 0)
    }

    static func storedCollapseLevel(collapseLevel: String?, seconds: Double?) -> CaptionCollapseLevel {
        parseCollapse(collapseLevel) ?? snapCollapse(seconds: seconds ?? 8)
    }
}

/// Geometry for the meeting caption island: a capsule under the camera housing
/// that grows downward into the subtitle panel. No AppKit so tests can compile it.
enum CaptionIslandLayout {
    /// An explicit width selection overrides a dragged width, preserving height
    /// and position unless the new width would extend beyond the host display.
    static func desktopFrame(selectingWidth fraction: CGFloat, current: CGRect, visibleFrame: CGRect) -> CGRect {
        let width = min(max(1, visibleFrame.width - 24), max(480, visibleFrame.width * fraction))
        let x = min(max(current.minX, visibleFrame.minX), visibleFrame.maxX - width)
        return CGRect(x: x, y: current.minY, width: width, height: current.height)
    }

    /// Final black shape width, including the host's 15pt side insets.
    static func compactWidth(notchWidth: CGFloat) -> CGFloat { max(0, notchWidth) + 240 }

    /// Final black capsule width, including the host's 30pt horizontal padding.
    /// Approved build-spec §3.1: expanded widths do not depend on notch width.
    static func expandedWidth(screenWidth: CGFloat, widthLevel: CaptionSizeLevel = .medium) -> CGFloat {
        let available = screenWidth - 24
        let minimum: CGFloat = 31 // 1pt content + the host's fixed 30pt padding
        let large = min(800, max(minimum + 2, floor(available)))
        // Below 111pt, two 40pt gaps plus host padding and positive content
        // cannot fit. Reduce the gap to the largest fitting integer (>= 1pt).
        // Below 33pt, three renderable integer tiers cannot fit at all: use
        // 31/32/33pt, accepting overflow instead of zero content or equal tiers.
        let gap = min(40, floor((large - minimum) / 2))
        let proposedSmall = available >= 800 ? 420 : floor(min(420, available * 0.5))
        let proposedMedium = available >= 800 ? 560 : floor(min(560, available * 0.7))
        // Compress narrow first; only move medium when the upper gap or the
        // positive narrow tier cannot otherwise be preserved.
        let small = max(minimum, min(proposedSmall, proposedMedium - gap, large - 2 * gap))
        let medium = min(large - gap, max(proposedMedium, small + gap))
        switch widthLevel {
        case .small: return small
        case .medium: return medium
        case .large: return large
        }
    }

    /// Content-only caps; the host adds its existing vertical padding separately.
    static func expandedContentHeight(visibleHeight: CGFloat, heightLevel: CaptionSizeLevel) -> CGFloat {
        let cap = floor(visibleHeight * 33 / 100)
        // Merge toward the lower tier. Hold merged tiers at 64 until a full
        // 24pt gap fits; splitting can only increase a tier, never shrink it.
        let large = cap < 88 ? 64 : min(CGFloat(240), cap)
        let medium = large < 112 ? 64 : min(CGFloat(148), large - 24)
        let small = max(64, min(CGFloat(100), medium - 24))
        switch heightLevel {
        case .small: return small
        case .medium: return medium
        case .large: return large
        }
    }

    /// Text margins are measured from the final capsule, not its host content.
    static func textColumnWidth(islandWidth: CGFloat) -> CGFloat {
        max(1, islandWidth - 40)
    }

    static func islandContentHeight(measured: CGFloat, visibleHeight: CGFloat,
                                    heightLevel: CaptionSizeLevel) -> CGFloat {
        let cap = expandedContentHeight(visibleHeight: visibleHeight, heightLevel: heightLevel)
        return min(cap, max(64, ceil(measured)))
    }

    static func notchContentSize(visibleFrame: CGRect, widthLevel: CaptionSizeLevel = .medium,
                                 heightLevel: CaptionSizeLevel) -> CGSize {
        CGSize(width: max(1, expandedWidth(screenWidth: visibleFrame.width, widthLevel: widthLevel) - 30),
               height: expandedContentHeight(visibleHeight: visibleFrame.height, heightLevel: heightLevel))
    }

    /// Preserve the real-screen menu-bar height (frame.maxY - visibleFrame.maxY).
    /// contentSize excludes the host's existing horizontal and bottom padding.
    static func notchedWindowFrame(screenFrame: CGRect, notchHeight: CGFloat,
                                   contentSize: CGSize) -> CGRect {
        let size = CGSize(width: contentSize.width + 30,
                          height: contentSize.height + notchHeight + 15)
        return CGRect(x: screenFrame.midX - size.width / 2,
                      y: screenFrame.maxY - size.height, width: size.width, height: size.height)
    }

    static let idleHeight: CGFloat = 36
    static let idleMinWidth: CGFloat = 128
    static let expandedCompactHeight: CGFloat = 132
    static let expandedFullHeight: CGFloat = 220
    static let topGap: CGFloat = 0

    static func notchWidth(auxiliaryTopLeft: CGRect, auxiliaryTopRight: CGRect) -> CGFloat {
        guard auxiliaryTopLeft.width > 1, auxiliaryTopRight.width > 1 else { return 0 }
        let gap = auxiliaryTopRight.minX - auxiliaryTopLeft.maxX
        return gap > 8 ? gap : 0
    }

    static func centerX(
        visibleFrame: CGRect,
        auxiliaryTopLeft: CGRect,
        auxiliaryTopRight: CGRect
    ) -> CGFloat {
        let width = notchWidth(auxiliaryTopLeft: auxiliaryTopLeft, auxiliaryTopRight: auxiliaryTopRight)
        if width > 0 {
            return (auxiliaryTopLeft.maxX + auxiliaryTopRight.minX) / 2
        }
        return visibleFrame.midX
    }

    static func idleRect(
        visibleFrame: CGRect,
        centerX: CGFloat,
        notchWidth: CGFloat
    ) -> CGRect {
        let width = max(idleMinWidth, notchWidth > 0 ? min(notchWidth + 12, visibleFrame.width * 0.42) : idleMinWidth)
        return pinned(width: width, height: idleHeight, centerX: centerX, visibleFrame: visibleFrame)
    }

    static func expandedRect(
        visibleFrame: CGRect,
        centerX: CGFloat,
        widthLevel: CaptionSizeLevel = .medium,
        compact: Bool
    ) -> CGRect {
        let height = compact ? expandedCompactHeight : expandedFullHeight
        let width = expandedWidth(screenWidth: visibleFrame.width, widthLevel: widthLevel)
        return pinned(width: width, height: height, centerX: centerX, visibleFrame: visibleFrame)
    }

    /// Top edge stays on the menu-bar / camera line while the island grows down.
    private static func pinned(width: CGFloat, height: CGFloat, centerX: CGFloat, visibleFrame: CGRect) -> CGRect {
        let width = min(width, max(80, visibleFrame.width - 16))
        let minX = visibleFrame.minX + 8
        let maxX = visibleFrame.maxX - width - 8
        let x = min(max(centerX - width / 2, minX), max(minX, maxX))
        let y = visibleFrame.maxY - height - topGap
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Presentation only: does not change storage, display-mode guards or caption routing.
enum CaptionHierarchy {
    static let currentSize: Double = 17
    static let sourceSize: Double = 13
    static let historySize: Double = 15
    static let maximumHistory = 3
    static func opacity(age: Int) -> Double {
        [0.85, 0.65, 0.50][min(2, max(0, age - 1))]
    }
    /// Height is the caption viewport, after title/status/pause chrome. The
    /// slab keeps its existing 8pt top/bottom padding. No island setting is read.
    static func desktopHistoryCount(availableHeight: Double, userSize: Double,
                                    showTranslation: Bool, showSource: Bool, currentHeight: Double? = nil) -> Int {
        let scale = userSize / 18
        let current = (showTranslation ? 48.0 + (showSource ? 22 : 0) : 24.0) * scale
        let history = 21 * scale + 4
        return max(1, Int(max(0, availableHeight - 16 - (currentHeight ?? current)) / max(1, history)))
    }
    /// Only current bilingual captions have a source line. Source-only history
    /// uses the primary 21pt line, just like translated history.
    static func historyLimit(userSize: Double, showTranslation: Bool, showSource: Bool, banner: Bool, height: Double = 153) -> Int {
        let scale = userSize / 18
        let current = ((showTranslation ? 48.0 : 0) + (showSource ? 22.0 : 0)) * scale
        let history = historyLineHeight(showTranslation: showTranslation, showSource: showSource) * scale + 4
        let available = height - 16 - current - (banner ? 40 : 0)
        return min(maximumHistory, max(0, Int(available / max(1, history))))
    }
    /// The source-only display choice remains authoritative. Only translation-only
    /// waiting rows use an ellipsis; every other missing translation uses source.
    static func row(source: String, translation: String, waiting: Bool,
                    current: Bool, showTranslation: Bool, showSource: Bool) -> CaptionRowText {
        if !showTranslation { return CaptionRowText(primary: source, secondary: nil, placeholder: false) }
        if translation.isEmpty {
            let placeholder = waiting && !showSource
            return CaptionRowText(primary: placeholder ? "…" : source, secondary: nil, placeholder: placeholder)
        }
        return CaptionRowText(primary: translation,
            secondary: current && showSource && !source.isEmpty ? source : nil, placeholder: false)
    }

    static func showsSource(current: Bool, showTranslation: Bool, showSource: Bool) -> Bool {
        showSource && (current || !showTranslation)
    }
    static func historyLineHeight(showTranslation: Bool, showSource: Bool) -> Double {
        (showTranslation || showSource) ? 25 : 0
    }
    static func fontSize(current: Bool, userSize: Double) -> Double {
        (current ? currentSize : historySize) * userSize / 18
    }
}


enum CaptionToolbarMode { case island, captionWindow }
enum CaptionToolbarAction: Hashable { case pause, stop, compact, settings, review }

enum CaptionToolbar {
    static func buttons(mode: CaptionToolbarMode, running: Bool, paused: Bool) -> [CaptionToolbarAction] {
        switch mode {
        case .island:
            return paused ? [.settings] : [.pause, .settings]
        case .captionWindow:
            return running ? [.pause, .stop, .compact, .settings, .review] : [.compact, .settings, .review]
        }
    }
}

/// Top-left coordinates relative to the caption viewport, including host side
/// insets. The notched toolbar occupies negative y in the existing camera row.
struct CaptionIslandToolbarLayout {
    static let buttonSize: CGFloat = 20
    static let stripHeight: CGFloat = 24
    let columnWidth: CGFloat
    let toolbar: CGRect
    let contentTop: CGFloat
    let statusText: CGRect
    let resumeButton: CGRect
    let currentText: CGRect

    static func extraHeight(notchHeight: CGFloat) -> CGFloat {
        notchHeight > 0 ? 0 : stripHeight
    }

    static func floatingWindowHeight(contentHeight: CGFloat, expanded: Bool) -> CGFloat {
        contentHeight + (expanded ? stripHeight : 0) + 8 + 15
    }

    init(islandWidth: CGFloat, paused: Bool, hovering: Bool,
         notchWidth: CGFloat = 0, notchHeight: CGFloat = 0,
         statusRowHeight: CGFloat = 44, currentTextHeight: CGFloat = 100) {
        columnWidth = CaptionIslandLayout.textColumnWidth(islandWidth: islandWidth)
        let count = CaptionToolbar.buttons(mode: .island, running: true, paused: paused).count
        let width = CGFloat(count) * Self.buttonSize + CGFloat(count - 1) * 6
        contentTop = Self.extraHeight(notchHeight: notchHeight)
        let rightAlignedX = islandWidth - 20 - width
        let x = notchHeight > 0 ? max(rightAlignedX, (islandWidth + notchWidth) / 2 + 4) : rightAlignedX
        toolbar = CGRect(x: x, y: notchHeight > 0 ? -(notchHeight + Self.buttonSize) / 2 : 0,
                         width: width, height: Self.buttonSize)
        let rowHeight = paused ? max(0, statusRowHeight) : 0
        statusText = CGRect(x: 20, y: contentTop, width: columnWidth, height: rowHeight)
        resumeButton = statusText
        currentText = CGRect(x: 20, y: contentTop + rowHeight + (paused ? 4 : 0),
                             width: columnWidth, height: max(0, currentTextHeight))
    }
}

struct CaptionRowText: Equatable {
    let primary: String
    let secondary: String?
    let placeholder: Bool
    /// Only currently visible text belongs in the accessibility tree.
    var accessibilityText: String { [primary, secondary].compactMap { $0 }.joined(separator: "\n") }
}

/// The outer island may remain at its 64pt floor while its status slot grows.
/// Interpolate the internal boundary independently of native window resizing.
struct IslandCaptionColumnGeometry {
    let status: CGRect
    let captions: CGRect
    init(bounds: CGRect, statusHeight: CGFloat, fraction: CGFloat) {
        let height = min(bounds.height, max(0, statusHeight) * min(1, max(0, fraction)))
        status = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: height)
        captions = CGRect(x: bounds.minX, y: bounds.minY + height,
                          width: bounds.width, height: max(0, bounds.height - height))
    }
}
