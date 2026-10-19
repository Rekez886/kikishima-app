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
    static func wantsExpanded(hasContent: Bool, dormant: Bool, settingsOpen: Bool, paused: Bool, hasBanner: Bool) -> Bool {
        settingsOpen || (hasContent && (!dormant || paused || hasBanner))
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

    static func expandedWidth(screenWidth: CGFloat) -> CGFloat {
        min(max(1, screenWidth - 16), screenWidth < 1440 ? max(420, screenWidth * 0.4) : 560)
    }

    static func notchContentSize(visibleFrame: CGRect, widthFraction: CGFloat, height: CGFloat) -> CGSize {
        CGSize(width: expandedWidth(screenWidth: visibleFrame.width) - 30, height: height)
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
        widthFraction: CGFloat,
        compact: Bool
    ) -> CGRect {
        let height = compact ? expandedCompactHeight : expandedFullHeight
        let width = max(480, min(visibleFrame.width - 24, visibleFrame.width * widthFraction))
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
    /// Only current bilingual captions have a source line. Source-only history
    /// uses the primary 21pt line, just like translated history.
    static func historyLimit(userSize: Double, showTranslation: Bool, showSource: Bool, banner: Bool) -> Int {
        let scale = userSize / 18
        let current = ((showTranslation ? 48.0 : 0) + (showSource ? 22.0 : 0)) * scale
        let history = historyLineHeight(showTranslation: showTranslation, showSource: showSource) * scale + 4
        let available = 153 - 16 - current - (banner ? 40 : 0)
        return min(maximumHistory, max(0, Int(available / max(1, history))))
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
