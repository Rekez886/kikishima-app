import CoreGraphics

@main struct CapsuleGeometryChecks {
    static func main() {
        for (width, height, menuHeight, expectedTop) in [(1280.0, 720.0, 24.0, 688.0), (1920, 1080, 25, 1047)] {
            let screen = CGRect(x: 0, y: 0, width: width, height: height)
            let visible = CGRect(x: 0, y: 0, width: width, height: height - menuHeight)
            let menuBar = CGRect(x: 0, y: visible.maxY, width: width, height: menuHeight)
            let statusIcon = CGRect(x: 702, y: visible.maxY, width: 36, height: menuHeight)
            // Expanded, paused, and hover-expanded sizes use segment A's content clamp.
            // The collapsed capsule uses the same placement policy.
            for (state, measured) in [("expanded", 110.0), ("paused", 148), ("hover-expanded", 300), ("collapsed", 0)] {
                let collapsed = state == "collapsed"
                let contentHeight = CaptionIslandLayout.islandContentHeight(measured: measured, visibleHeight: visible.height, heightLevel: .large)
                let size = CGSize(width: collapsed ? CaptionIslandLayout.compactWidth(notchWidth: 0) : 800,
                                  height: CaptionIslandToolbarLayout.floatingWindowHeight(
                                    contentHeight: collapsed ? 12 : contentHeight, expanded: !collapsed))
                let frame = CaptionScreenPolicy.floatingFrame(screenFrame: screen, visibleFrame: visible, size: size)
                precondition(frame.maxY == expectedTop, state)
                precondition(frame.midX == screen.midX, state)
                precondition(!frame.intersects(menuBar), state)
                precondition(!frame.intersects(statusIcon), state)
                let autoHidden = CaptionScreenPolicy.floatingFrame(screenFrame: screen, visibleFrame: screen, size: size)
                precondition(autoHidden.maxY == screen.maxY - 8, state)
                precondition(autoHidden.midX == screen.midX, state)
            }
        }
        print("PASS notchless capsule: menu bar and status icon clearance, all states, auto-hidden menu bar")
    }
}
