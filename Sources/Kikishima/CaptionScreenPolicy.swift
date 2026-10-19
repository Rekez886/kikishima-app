import CoreGraphics

enum CaptionScreenPolicy {
    struct Display {
        let isBuiltIn: Bool
        let hasNotch: Bool
    }

    /// Input order is NSScreen.screens order: first is the menu-bar display.
    static func islandIndex(displays: [Display]) -> Int? {
        displays.firstIndex(where: { $0.isBuiltIn && $0.hasNotch })
            ?? (displays.isEmpty ? nil : 0)
    }

    static func floatingFrame(screenFrame: CGRect, size: CGSize) -> CGRect {
        CGRect(x: screenFrame.midX - size.width / 2,
               y: screenFrame.maxY - 8 - size.height,
               width: size.width, height: size.height)
    }

    static func selectedIndex(meetingFrame: CGRect?, screenFrames: [CGRect], fallbackIndex: Int) -> Int? {
        guard !screenFrames.isEmpty else { return nil }
        if let frame = meetingFrame,
           let index = screenFrames.firstIndex(where: { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }) { return index }
        return screenFrames.indices.contains(fallbackIndex) ? fallbackIndex : 0
    }
    static func shouldMigrate(shown: Bool, currentScreenID: Int?, selectedScreenID: Int?, force: Bool, expansionChanged: Bool) -> Bool {
        !shown || force || currentScreenID != selectedScreenID || expansionChanged
    }
}
