// 漫画气泡覆盖层：透明、置顶、点击穿透，气泡跟随发言者格子
import SwiftUI
import AppKit

@MainActor
final class BubbleOverlayController {
    static let shared = BubbleOverlayController()
    private var window: NSWindow?

    func show() {
        if window == nil { build() }
        window?.orderFrontRegardless()
    }

    func hide() { window?.orderOut(nil) }

    /// 覆盖窗对齐会议窗口（CG 坐标原点左上 → Cocoa 原点左下）
    func align(to cgFrame: CGRect) {
        guard let screen = NSScreen.screens.first else { return }
        let cocoaFrame = NSRect(x: cgFrame.origin.x,
                                y: screen.frame.height - cgFrame.origin.y - cgFrame.height,
                                width: cgFrame.width, height: cgFrame.height)
        window?.setFrame(cocoaFrame, display: true)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.ignoresMouseEvents = true            // 点击穿透
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: BubbleView(state: CaptionState.shared))
        window = w
    }
}

struct BubbleView: View {
    @Bindable var state: CaptionState

    var body: some View {
        GeometryReader { geo in
            // 调试框：绿=检测到的发言者格子，红=人脸（定位问题一眼看穿）
            if state.debugBubble, let t = state.speakerTile {
                Rectangle().stroke(.green, lineWidth: 3)
                    .frame(width: t.width * geo.size.width, height: t.height * geo.size.height)
                    .position(x: t.midX * geo.size.width, y: t.midY * geo.size.height)
            }
            if state.debugBubble, let f = state.speakerFace {
                Rectangle().stroke(.red, lineWidth: 3)
                    .frame(width: f.width * geo.size.width, height: f.height * geo.size.height)
                    .position(x: f.midX * geo.size.width, y: f.midY * geo.size.height)
            }
            if let loc = state.speakerTile, !state.bubbleText.isEmpty {
                let tile = CGRect(x: loc.minX * geo.size.width,
                                  y: loc.minY * geo.size.height,
                                  width: loc.width * geo.size.width,
                                  height: loc.height * geo.size.height)
                // 有人脸锚脸旁（头顶偏右，尾巴指向嘴），没有则锚格子右上
                let anchor = Self.anchorPoint(face: state.speakerFace, tile: tile, size: geo.size)
                ComicBubble(text: state.bubbleText)
                    .frame(maxWidth: min(460, geo.size.width * 0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .position(anchor)
                    .animation(.spring(duration: 0.35), value: state.speakerTile)
            }
        }
        .allowsHitTesting(false)
    }

    static func anchorPoint(face: CGRect?, tile: CGRect, size: CGSize) -> CGPoint {
        if let f = face {
            let fr = CGRect(x: f.minX * size.width, y: f.minY * size.height,
                            width: f.width * size.width, height: f.height * size.height)
            return CGPoint(x: min(fr.maxX + 70, size.width - 180),
                           y: max(fr.minY - 46, 70))
        }
        return CGPoint(x: min(tile.maxX + 40, size.width - 180),
                       y: max(tile.minY - 10, 80))
    }
}

/// 漫画吹き出し：白底黑边圆气泡 + 指向左下的尾巴
struct ComicBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 22, weight: .heavy, design: .rounded))
            .foregroundStyle(.black)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .padding(.horizontal, 26)
            .padding(.vertical, 18)
            .background(
                // 描边层在下、填充层在上：气泡与尾巴的内部接缝被白色盖掉，轮廓自然融合
                ZStack {
                    BubbleShape().stroke(.black, lineWidth: 7)
                    BubbleShape().fill(.white)
                }
                .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
            )
    }
}

struct BubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path(roundedRect: rect, cornerRadius: min(rect.height / 2, 34))
        // 尾巴：从气泡左下伸出、更长更尖，指向说话人的嘴
        var tail = Path()
        tail.move(to: CGPoint(x: rect.minX + 34, y: rect.maxY - 6))
        tail.addLine(to: CGPoint(x: rect.minX - 4, y: rect.maxY + 40))
        tail.addLine(to: CGPoint(x: rect.minX + 64, y: rect.maxY - 3))
        tail.closeSubpath()
        p.addPath(tail)
        return p
    }
}
