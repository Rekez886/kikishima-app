import Foundation

for running in [false, true] {
    for paused in [false, true] {
        let desktop: [CaptionToolbarAction] = running ? [.pause, .stop, .compact, .settings, .review] : [.compact, .settings, .review]
        precondition(CaptionToolbar.buttons(mode: .captionWindow, running: running, paused: paused) == desktop)
        let island = CaptionToolbar.buttons(mode: .island, running: running, paused: paused)
        precondition(island == (paused ? [.settings] : [.pause, .settings]))
        precondition(!island.contains(.stop) && !island.contains(.compact) && !island.contains(.review))
    }
}
for width: CGFloat in [420, 560, 800] {
    for notchHeight: CGFloat in [0, 32, 33] {
        for notchWidth: CGFloat in (notchHeight == 0 ? [0] : [185, 200]) {
            for paused in [false, true] {
                for rowHeight: CGFloat in [28, 44, 100, 300] {
                    let hidden = CaptionIslandToolbarLayout(islandWidth: width, paused: paused, hovering: false,
                        notchWidth: notchWidth, notchHeight: notchHeight, statusRowHeight: rowHeight)
                    for hovering in [false, true] {
                        let layout = CaptionIslandToolbarLayout(islandWidth: width, paused: paused, hovering: hovering,
                            notchWidth: notchWidth, notchHeight: notchHeight, statusRowHeight: rowHeight)
                        precondition(layout.toolbar.height == 20)
                        precondition(layout.toolbar.width == (paused ? 20 : 46))
                        precondition(layout.toolbar.maxX <= width - 20)
                        precondition(layout.contentTop == (notchHeight > 0 ? 0 : 24))
                        if notchHeight > 0 {
                            let notch = CGRect(x: (width - notchWidth) / 2, y: -notchHeight,
                                               width: notchWidth, height: notchHeight)
                            precondition(layout.toolbar.minY >= -notchHeight && layout.toolbar.maxY <= 0)
                            precondition(layout.toolbar.midY == -notchHeight / 2)
                            precondition(layout.toolbar.minX >= notch.maxX)
                            precondition(!layout.toolbar.intersects(notch))
                        }
                        for frame in [layout.statusText, layout.resumeButton, layout.currentText,
                                      CGRect(x: 20, y: layout.contentTop, width: width - 40, height: 240)] {
                            precondition(!layout.toolbar.intersects(frame))
                        }
                        precondition(layout.toolbar == hidden.toolbar)
                        precondition(layout.statusText == hidden.statusText)
                        precondition(layout.resumeButton == hidden.resumeButton)
                        precondition(layout.currentText == hidden.currentText)
                    }
                }
            }
        }
        for contentHeight: CGFloat in [64, 100, 148, 240] {
            if notchHeight > 0 {
                let frame = CaptionIslandLayout.notchedWindowFrame(
                    screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                    notchHeight: notchHeight, contentSize: CGSize(width: width - 30, height: contentHeight))
                precondition(frame.height == contentHeight + notchHeight + 15)
            } else {
                precondition(CaptionIslandToolbarLayout.floatingWindowHeight(contentHeight: contentHeight, expanded: true)
                             == contentHeight + 24 + 8 + 15)
                precondition(CaptionIslandToolbarLayout.floatingWindowHeight(contentHeight: contentHeight, expanded: false)
                             == contentHeight + 8 + 15)
            }
        }
    }
}
print("PASS island toolbar: camera-row placement, extra floating strip, disjoint content, stable hover geometry")
