import AppKit
@main struct PlacementTest {
    static func main() {
        // Fixture, not an asserted measurement of the developer's unavailable status-button coordinates.
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 944) // 38pt menu bar
        let button = CGRect(x: 1200, y: 944, width: 24, height: 38)
        let result = ShootMenuPlacement.frame(menuSize: CGSize(width: 304, height: 752), buttonFrame: button, visibleFrame: visible)
        precondition(result == CGRect(x: 1060, y: 192, width: 304, height: 752))
        precondition(visible.contains(result) && result.maxY == visible.maxY)
        print("PASS 1512x982 fixture: Cocoa 1060,192,304x752; AX 1060,38,304x752; bar=\(screen.maxY-visible.maxY)")
        for vf in [visible, CGRect(x: -1920, y: -100, width: 1920, height: 1042), CGRect(x: 0, y: 80, width: 1512, height: 864)] {
            for x in [vf.minX, vf.midX, vf.maxX] {
                for size in [CGSize(width:304,height:752), CGSize(width:2000,height:2000)] {
                    let frame = ShootMenuPlacement.frame(menuSize:size, buttonFrame:CGRect(x:x,y:vf.maxY,width:24,height:38), visibleFrame:vf)
                    precondition(vf.contains(frame) && frame.maxY == vf.maxY)
                }
            }
        }
        print("PASS left/right clamp, offset screen, Dock inset, oversized menu; no window created")
    }
}
