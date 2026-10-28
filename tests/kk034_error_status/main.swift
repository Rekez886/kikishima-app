import Foundation
import CoreGraphics

for compact in [false, true] {
    for width: CGFloat in [360, 480, 780] {
        for fontSize: CGFloat in [12, 18, 24, 32] {
            for hasStatus in [false, true] {
                var previous: CaptionDesktopStatusLayout?
                for _ in [false, true] { // hidden / hovered: same production reservation
                    let layout = CaptionDesktopStatusLayout(width: width, height: 320, compact: compact,
                        titlebarHeight: 28, statusHeight: fontSize, hasStatus: hasStatus, leadingInset: 32)
                    precondition(!layout.toolbar.intersects(layout.captions))
                    precondition(!layout.toolbar.intersects(layout.status))
                    if let previous {
                        precondition(layout.captions == previous.captions)
                        precondition(layout.status == previous.status && layout.toolbar == previous.toolbar)
                    }
                    if compact {
                        precondition(layout.headerHeight == 28 && layout.status.height == 28)
                        precondition(layout.captions.minY == 28)
                        precondition(layout.status.maxX <= layout.toolbar.minX)
                    } else {
                        precondition(layout.status.minY == layout.toolbar.maxY + (hasStatus ? 4 : 0))
                        precondition(layout.status.height == (hasStatus ? 28 : 0))
                        precondition(layout.captions.minY == layout.status.maxY)
                    }
                    for textWidth: CGFloat in [12, 40, 1000] {
                        let inline = CaptionStatusInlineGeometry(width: layout.status.width, height: 18,
                            textWidth: textWidth, actionWidth: 60)
                        precondition(inline.action.minX == inline.text.maxX + CaptionStatusInlineGeometry.gap)
                        precondition(inline.action.maxX <= layout.status.width)
                        precondition(!inline.text.intersects(inline.action))
                        if textWidth == 12 { precondition(inline.action.maxX < layout.status.width) }
                        if compact { precondition(layout.status.minX + inline.action.maxX <= layout.toolbar.minX) }
                    }
                    previous = layout
                }
            }
        }
    }
}
print("PASS geometry: no hover intersection, compact fixed 28pt, stable reserved width, adjacent action")

let engineSources = ["启动失败", "转写引擎中断", "转写引擎反复中断", "输出设备切换后无法继续捕获音频", "音频仍无法捕获", "无法继续"]
for source in engineSources {
    let host = StatusHost()
    host.errorBanner = CaptionBanner(text: source, action: .retry)
    precondition(host.desktopErrorStatus?.action?.title == "修复")
}

for (source, action, title) in [
    ("permission", CaptionBanner.Action.openSettings, "修复"),
] {
    let banner = CaptionBanner(text: source, action: action)
    precondition(banner.showsStatusLine && banner.action?.title == title)
}
for source in ["network", "timeout", "5xx", "部分字幕未翻译完成，可重试", "部分字幕未翻译完成，可在记录中重试"] {
    precondition(!CaptionBanner(text: source, severity: .info, action: .retry).showsStatusLine)
}
// Regression: an error without a repair action is still shown, with no button.
precondition(CaptionBanner(text: "切换会议语言失败").showsStatusLine)
precondition(CaptionBanner(text: "切换会议语言失败").action == nil)
print("PASS classification: capture repair titles, permission action, informational status and errors without actions")

let host = StatusHost()
let identical = CaptionBanner(text: "same error", action: .retry)
host.errorBanner = identical
precondition(host.desktopErrorStatus != nil)
host.dismissDesktopErrorStatus()
precondition(host.desktopErrorStatus == nil && host.errorBanner == identical)
host.errorBanner = identical
precondition(host.desktopErrorStatus == identical)
host.errorBanner = nil
precondition(host.desktopErrorStatus == nil)
print("PASS Esc hides one occurrence; identical reassignment reappears; resolution removes status")
