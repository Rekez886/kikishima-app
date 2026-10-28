#if SHOOT || DEBUG
import AppKit

/// OPEN_MENU uses Cocoa screen coordinates throughout; AX coordinates are top-left based.
enum ShootMenuPlacement {
    static func frame(menuSize: CGSize, buttonFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        let size = CGSize(width: min(menuSize.width, visibleFrame.width),
                          height: min(menuSize.height, visibleFrame.height))
        let x = min(max(buttonFrame.midX - size.width / 2, visibleFrame.minX),
                    visibleFrame.maxX - size.width)
        return CGRect(x: x, y: visibleFrame.maxY - size.height, width: size.width, height: size.height)
    }

    @MainActor static func position(_ menu: NSWindow, below button: NSStatusBarButton?) -> Bool {
        guard let button, let host = button.window, let screen = host.screen,
              button.bounds.width > 0, button.bounds.height > 0,
              menu.frame.width > 0, menu.frame.height > 0 else { return false }
        let anchor = host.convertToScreen(button.convert(button.bounds, to: nil))
        // Do not position against a zero/origin placeholder while the status item is attaching.
        guard anchor.intersects(screen.frame), anchor.minY >= screen.visibleFrame.maxY - 1 else { return false }
        menu.setFrame(frame(menuSize: menu.frame.size, buttonFrame: anchor,
                            visibleFrame: screen.visibleFrame), display: false)
        let expected = frame(menuSize: menu.frame.size, buttonFrame: anchor, visibleFrame: screen.visibleFrame)
        return screen.visibleFrame.contains(menu.frame) && abs(menu.frame.maxY - expected.maxY) < 1
            && abs(menu.frame.minX - expected.minX) < 1
    }
}
#endif
