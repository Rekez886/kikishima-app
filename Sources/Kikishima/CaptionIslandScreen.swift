import AppKit

/// AppKit adapter; selection itself is pure and never uses the focused/main window.
@MainActor
enum CaptionIslandScreen {
    static func hasNotch(_ screen: NSScreen) -> Bool {
#if SHOOT
        if ShootNotch.size(on: screen) != nil { return true }
#endif
        return (screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil)
            || (isBuiltIn(screen) && screen.safeAreaInsets.top > 0)
    }

    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }

    static func selected() -> NSScreen? {
#if SHOOT
        if let screen = ShootNotch.selectedScreen() { return screen }
#endif
        let screens = NSScreen.screens
        let displays = screens.map {
            CaptionScreenPolicy.Display(isBuiltIn: isBuiltIn($0), hasNotch: hasNotch($0))
        }
        guard let index = CaptionScreenPolicy.islandIndex(displays: displays) else { return nil }
        return screens[index]
    }
}
