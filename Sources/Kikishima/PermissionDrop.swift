// 「把 Kikishima 拖进系统设置的列表」浮动提示条（参考 Screenflare；拖拽实现改编自 PermissionFlow，MIT，见 NOTICE.md）
// 用法：打开系统设置某个隐私页后调用 PermissionDropHelper.shared.show(listName:)，权限拿到后 hide()
import AppKit
import SwiftUI

@MainActor
final class PermissionDropHelper {
    static let shared = PermissionDropHelper()
    private var panel: NSPanel?
    private var autoHide: DispatchWorkItem?

    func show(listName: String) {
        hide()
        let view = DropHintView(listName: listName, appURL: Bundle.main.bundleURL, onClose: { [weak self] in self?.hide() })
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: max(420, size.width), height: max(96, size.height))),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = hosting
        // 放在主屏底部居中：系统设置窗一般在屏幕中间，提示条不挡列表
        if let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: vf.midX - p.frame.width / 2, y: vf.minY + 40))
        }
        p.orderFrontRegardless()
        panel = p
        // 五分钟没动作自动收起（去系统设置找列表、解锁、拖 app，两分钟常不够）
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        autoHide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: w)
    }

    func hide() {
        autoHide?.cancel(); autoHide = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct DropHintView: View {
    let listName: String
    let appURL: URL
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold))
                Text(tr("把 Kikishima 拖进「%@」列表", listName)).font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                    .buttonStyle(KKPlainButtonStyle()).foregroundStyle(KKColor.textSecondary)
                    .accessibilityLabel(tr("关闭"))
            }
            AppDragItemView(url: appURL)
                .frame(height: 52)
            Text(tr("也可以点列表下方的 + 号，在 应用程序 里选 Kikishima。")).font(.caption).foregroundStyle(KKColor.textSecondary)
        }
        .padding(14)
        .frame(width: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.primary.opacity(0.08)))
        .padding(8)
    }
}

// ---- 可拖拽的 app 卡片：拖出去的是 .app 的文件 URL，系统设置的列表接受它 ----

private struct AppDragItemView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> AppDragSourceView { AppDragSourceView(url: url) }
    func updateNSView(_ nsView: AppDragSourceView, context: Context) {}
}

private final class AppDragSourceView: NSView, NSDraggingSource {
    private let url: URL
    private let hosting: NSHostingView<AnyView>
    private var mouseDownPoint: NSPoint?
    private var dragging = false

    init(url: URL) {
        self.url = url
        hosting = NSHostingView(rootView: AnyView(AppDragCard(url: url).allowsHitTesting(false)))
        super.init(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor), hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor), hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) { mouseDownPoint = convert(event.locationInWindow, from: nil); dragging = false }
    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil; dragging = false }
    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let start = mouseDownPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        dragging = true
        // 载荷尽量像 Finder 拖出来的文件：fileURL + 文件名列表 + 路径字串
        let item = NSDraggingItem(pasteboardWriter: AppBundlePasteboardWriter(url: url))
        let icon = NSWorkspace.shared.icon(forFile: url.path); icon.size = NSSize(width: 56, height: 56)
        item.setDraggingFrame(NSRect(x: p.x - 28, y: p.y - 28, width: 56, height: 56), contents: icon)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { mouseDownPoint = nil; dragging = false }
}

private final class AppBundlePasteboardWriter: NSObject, NSPasteboardWriting {
    private let url: URL
    init(url: URL) { self.url = url }
    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, NSPasteboard.PasteboardType("NSFilenamesPboardType"), NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"), .string]
    }
    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL, .URL, NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"): return url.absoluteString
        case NSPasteboard.PasteboardType("NSFilenamesPboardType"): return [url.path]
        case .string: return url.path
        default: return nil
        }
    }
}

private struct AppDragCard: View {
    let url: URL
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32).cornerRadius(8)
            Text(url.deletingPathExtension().lastPathComponent).font(.system(size: 15))
            Spacer()
            Image(systemName: "line.3.horizontal").foregroundStyle(KKColor.textSecondary)
        }
        .padding(8)
        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.primary.opacity(0.1)))
    }
}
