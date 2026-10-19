import AppKit

/// AppKit adapter; selection itself is pure and never uses the focused/main window.
@MainActor
enum CaptionIslandScreen {
    static func hasNotch(_ screen: NSScreen) -> Bool {
        (screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil)
            || (isBuiltIn(screen) && screen.safeAreaInsets.top > 0)
    }

    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }

    static func selected() -> NSScreen? {
        let screens = NSScreen.screens
        let displays = screens.map {
            CaptionScreenPolicy.Display(isBuiltIn: isBuiltIn($0), hasNotch: hasNotch($0))
        }
        guard let index = CaptionScreenPolicy.islandIndex(displays: displays) else { return nil }
        return screens[index]
    }
}
