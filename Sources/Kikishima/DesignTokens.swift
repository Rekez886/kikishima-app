import SwiftUI
import AppKit

/// Build-spec §2.1: adaptive app chrome colors (kk.color.*).
/// Caption surfaces use the same system appearance as the host.
enum KKColor {
    static let surfaceBase = adaptive("kk.color.surface.base", dark: 0x151515, light: 0xFFFFFF)
    static let textSecondary = adaptive("kk.color.text.secondary", dark: 0xA6A6A6, light: 0x6B6B70)
    static let notchBackground = adaptive("kk.color.notch.bg", dark: 0x000000, light: 0xFFFFFF)
    static let historyInk = adaptive("kk.color.caption.history.ink", dark: 0xFFFFFF, light: 0x1A1A1C)
    static let historyFloor = adaptive("kk.color.caption.history.floor", dark: 0x808080, light: 0x808080)
    static let borderSubtle = adaptive("kk.color.border.subtle", dark: 0xFFFFFF, light: 0x000000).opacity(0.08)
    static let error = adaptive("kk.color.status.error", dark: 0xFF6B6B, light: 0xC62828)
    static let surfaceRaised = adaptive("kk.color.surface.raised", dark: 0x202123, light: 0xF7F7F8)
    static let surfaceSelected = adaptive("kk.color.surface.selected", dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.10, lightAlpha: 0.07)
    static let textPrimary = adaptive("kk.color.text.primary", dark: 0xF5F5F5, light: 0x1A1A1C)
    static let textTertiary = adaptive("kk.color.text.tertiary", dark: 0x8A8A8A, light: 0x6B6B70)
    static let warning = adaptive("kk.color.status.warning", dark: 0xF5B841, light: 0x9A6700)
    static let brand = adaptive("kk.color.brand", dark: 0xF2603D, light: 0xC8401F)
    static let focusRing = brand // kk.color.focus.ring
    static let brandOn = adaptive("kk.color.brand.on", dark: 0x151515, light: 0xFFFFFF)

    private static func adaptive(_ name: String, dark: UInt32, light: UInt32, darkAlpha: Double = 1, lightAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name), dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255,
                           green: Double((hex >> 8) & 0xFF) / 255,
                           blue: Double(hex & 0xFF) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        }))
    }
}

/// The colored-background calculation needs 0.95, so keep the slider and use an opaque text area.
enum CaptionOpacityPolicy {
    static let minimum = 0.60
    static let requiredMinimum = 0.95
    static let usesOpaqueTextBackground = requiredMinimum > 0.70
    static let minimumHistoryInkOpacity = 0.65
    static let defaultValue = 0.92
    static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(1, max(minimum, value)) : defaultValue
    }
}

enum KKRadius { static let md: CGFloat = 8 } // kk.radius.md

enum KKSpace {
    static let two: CGFloat = 8 // kk.space.2
    static let three: CGFloat = 12 // kk.space.3
    static let five: CGFloat = 20 // kk.space.5
    static let one: CGFloat = 4 // kk.space.1
}

extension View {
    /// Native chrome stays gray even when the macOS accent preference is colored.
    /// Brand color belongs on individual approved controls, never their container.
    func kkNeutralControls() -> some View {
        self.tint(KKColor.textSecondary).accentColor(KKColor.textSecondary)
            .focusEffectDisabled()
    }

    @ViewBuilder
    func kkPrimaryButton(active: Bool) -> some View {
        if active {
            self.buttonStyle(KKFilledButtonStyle(active: true))
                .tint(KKColor.surfaceRaised).foregroundStyle(KKColor.textPrimary)
        } else {
            self.kkPrimaryButton()
        }
    }

    func kkPrimaryButton() -> some View {
        self.buttonStyle(KKFilledButtonStyle(active: false))
            .foregroundStyle(KKColor.brandOn)
    }
}

/// Preserve native Button actions/shortcuts while observing focus on the control,
/// never on its styled label. There is no AX enumeration or event monitor.
private struct KKSystemFocusButton<Artwork: ButtonStyle>: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let artwork: Artwork
    let radius: CGFloat
    var body: some View {
        Button(configuration)
            .buttonStyle(artwork)
            .kkFocusRing(radius: radius)
    }
}
struct KKFilledButtonStyle: PrimitiveButtonStyle {
    var active: Bool
    func makeBody(configuration: Configuration) -> some View {
        KKSystemFocusButton(configuration: configuration, artwork: KKFilledButtonArtwork(active: active), radius: 8)
    }
}
struct KKQuietButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        KKSystemFocusButton(configuration: configuration, artwork: KKQuietButtonArtwork(), radius: 6)
    }
}
struct KKPlainButtonStyle: PrimitiveButtonStyle {
    var radius: CGFloat = 6
    func makeBody(configuration: Configuration) -> some View {
        KKSystemFocusButton(configuration: configuration, artwork: KKPlainButtonArtwork(radius: radius), radius: radius)
    }
}
struct KKLinkButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        KKSystemFocusButton(configuration: configuration, artwork: KKLinkButtonArtwork(), radius: 6)
    }
}

/// Opaque fills avoid AppKit's prominent-button tint and white-title substitutions.
private struct KKFilledButtonArtwork: ButtonStyle {
    var active: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? KKColor.textPrimary : KKColor.brandOn)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(minWidth: 28, minHeight: 28)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(active ? KKColor.surfaceRaised : KKColor.brand, in: RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.65)
    }
}

private struct KKQuietButtonArtwork: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(KKColor.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(minWidth: 28, minHeight: 28)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background(KKColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 6))
            .brightness(configuration.isPressed ? -0.03 : 0)
    }
}

/// Retain the proven whole-row NSSwitch, hosted child label,
/// and 2pt brand body ring with 2pt gap. Whole-row AX bounds are a known issue.
/// Never override AX frame to pretend it matches the body ring.
struct KKSwitchToggleStyle: ToggleStyle {
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var enabled
    private var size: CGSize {
        switch controlSize {
        case .mini: return CGSize(width: 26, height: 15)
        case .small: return CGSize(width: 32, height: 18)
        case .large, .extraLarge: return CGSize(width: 44, height: 26)
        default: return CGSize(width: 38, height: 22)
        }
    }
    func makeBody(configuration: Configuration) -> some View {
        KKNativeSwitchHost(label: AnyView(configuration.label.foregroundStyle(KKColor.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)),
                           isOn: configuration.$isOn, enabled: enabled, bodySize: size)
    }
}
private struct KKNativeSwitchHost: NSViewRepresentable {
    let label: AnyView
    @Binding var isOn: Bool
    let enabled: Bool
    let bodySize: CGSize
    func makeNSView(context: Context) -> KKNativeSwitch { KKNativeSwitch() }
    func updateNSView(_ view: KKNativeSwitch, context: Context) {
        view.label.rootView = label
        view.labelMeasurement.rootView = label
        view.bodySize = bodySize
        view.isEnabled = enabled
        view.state = isOn ? .on : .off
        view.changed = { isOn = $0 }
        view.label.alphaValue = enabled ? 1 : 0.65
        view.needsLayout = true; view.needsDisplay = true
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: KKNativeSwitch, context: Context) -> CGSize? {
        let ideal = nsView.label.fittingSize.width + bodySize.width + 12
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal
        let labelSize = nsView.labelMeasurement.sizeThatFits(in: CGSize(width: max(1, width-bodySize.width-12), height: 10000))
        return CGSize(width: max(bodySize.width+8, width), height: max(28, max(labelSize.height, bodySize.height)+8))
    }
}
private final class KKSwitchLabelView: NSHostingView<AnyView> {
    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
final class KKNativeSwitch: NSSwitch {
    let label: NSHostingView<AnyView> = KKSwitchLabelView(rootView: AnyView(EmptyView()))
    let labelMeasurement = NSHostingController(rootView: AnyView(EmptyView()))
    var bodySize = CGSize(width: 38, height: 22)
    var changed: (Bool) -> Void = { _ in }
    private var windowObservers: [NSObjectProtocol] = []
    private var readingLabel = false
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { false } // Always use our grayscale draw(_:), not native accent layer rendering.
    override var acceptsFirstResponder: Bool { isEnabled }
    var hasKeyboardFocus: Bool { window?.isKeyWindow == true && window?.firstResponder === self }
    var switchBodyRect: CGRect {
        CGRect(x: max(4, bounds.maxX-bodySize.width-4), y: (bounds.height-bodySize.height)/2,
               width: bodySize.width, height: bodySize.height)
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        target = self; action = #selector(toggled)
        focusRingType = .none
        addSubview(label)
        suppressSystemArtwork()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func toggled() { changed(state == .on); needsDisplay = true }
    override func layout() {
        super.layout()
        suppressSystemArtwork()
        label.frame = CGRect(x: 0, y: 0, width: max(0, switchBodyRect.minX-8), height: bounds.height)
    }
    private func suppressSystemArtwork() {
        // macOS renders NSSwitch's center artwork in a system-owned hosting
        // subview, independently of draw(_:). Keep it installed for AppKit/AX,
        // but make only those pixels transparent. The hosted label stays visible.
        for child in subviews where child !== label { child.alphaValue = 0 }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Route clicks on the passive label and the custom right-hand artwork
        // to this control, never to the transparent system switch in the center.
        guard !isHiddenOrHasHiddenAncestor else { return nil }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }
    private func toggleFromInput() {
        guard isEnabled else { return }
        state = state == .on ? .off : .on
        toggled()
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        toggleFromInput()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 {
            if !event.isARepeat { toggleFromInput() }
            return
        }
        super.keyDown(with: event) // Keep the system Tab loop and other key handling.
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        toggleFromInput()
        return true
    }
    override func draw(_ dirtyRect: NSRect) {
        let body = switchBodyRect
        NSColor(state == .on ? KKColor.textPrimary : KKColor.textTertiary).withAlphaComponent(isEnabled ? 1 : 0.65).setFill()
        NSBezierPath(roundedRect: body, xRadius: body.height/2, yRadius: body.height/2).fill()
        let diameter = body.height-4
        let thumb = CGRect(x: state == .on ? body.maxX-diameter-2 : body.minX+2, y: body.minY+2, width: diameter, height: diameter)
        NSColor(KKColor.surfaceBase).setFill()
        NSBezierPath(ovalIn: thumb).fill()
        if hasKeyboardFocus {
            let outset = KKFocusGeometry.centerOutset
            let path = NSBezierPath(roundedRect: body.insetBy(dx: -outset, dy: -outset), xRadius: body.height/2+outset, yRadius: body.height/2+outset)
            NSColor(KKColor.surfaceBase).setStroke(); path.lineWidth = KKFocusGeometry.baseWidth; path.stroke()
            NSColor(KKColor.focusRing).setStroke(); path.lineWidth = KKFocusGeometry.ringWidth; path.stroke()
        }
    }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityLabel() -> String? {
        guard !readingLabel else { return nil }
        readingLabel = true
        defer { readingLabel = false }
        if let supplied = super.accessibilityLabel(), !supplied.isEmpty { return supplied }
        var remaining = 64
        func texts(_ object: Any, depth: Int) -> [String] {
            guard remaining > 0, depth < 10, let node = object as? NSObject else { return [] }
            remaining -= 1
            func read(_ name: String) -> Any? {
                let selector = NSSelectorFromString(name)
                return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
            }
            let own = [read("accessibilityLabel"), read("accessibilityValue")].compactMap { $0 as? String }.filter { !$0.isEmpty }
            if let first = own.first { return [first] } // AX label and value can expose the same text.
            return (read("accessibilityChildren") as? [Any] ?? []).flatMap { texts($0, depth: depth+1) }
        }
        let values = texts(label, depth: 0)
        return values.isEmpty ? nil : values.joined(separator: " ")
    }
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.hasKeyboardFocus else { return }
            self.scrollToVisible(self.switchBodyRect.insetBy(dx: -4, dy: -4))
        }
        return true
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder(); needsDisplay = true; return result
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }; windowObservers = []
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.needsDisplay = true })
            }
        }
    }
    deinit { windowObservers.forEach { NotificationCenter.default.removeObserver($0) } }
}

/// Text links keep their native Button keyboard behavior and a 28pt hit area.
private struct KKLinkButtonArtwork: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        KKLinkButtonLabel(label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct KKLinkButtonLabel<Label: View>: View {
    let label: Label
    let pressed: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        label.foregroundStyle(KKColor.textSecondary)
            .underline(hovering && enabled)
            .frame(minWidth: 28, minHeight: 28)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .opacity(enabled ? (pressed ? 0.85 : 1) : 0.65)
    }
}

/// Native Buttons remain in the system key loop; focus is attached to the control.
private struct KKFocusRing: ViewModifier {
    @FocusState private var focused: Bool
    @AccessibilityFocusState private var accessibilityFocused: Bool
#if DEBUG
    @Environment(\.kkFocusAuditID) private var auditID
#endif
    var radius: CGFloat
    func body(content: Content) -> some View {
        content.focused($focused).focusEffectDisabled()
            .accessibilityFocused($accessibilityFocused)
            .onChange(of: focused) { _, value in accessibilityFocused = value }
            .overlay { KKFocusOutline(active: focused, radius: radius) }
            .background { KKFocusedControlReveal(active: focused).allowsHitTesting(false).accessibilityHidden(true) }
#if DEBUG
            .preference(key: KKFocusSamples.self, value: auditID.isEmpty ? [:] : [auditID: focused])
#endif
    }
}
/// Scroll the leaf's actual bounds, including the 4pt outline, rather than a
/// ScrollViewReader ID whose layout frame can include a caller's large padding.
/// Resolve only this focused leaf's local accessibility representation, once per
/// focus edge. No application-wide candidates, polling, or extra key view.
private struct KKFocusedControlReveal: NSViewRepresentable {
    let active: Bool
    func makeNSView(context: Context) -> KKFocusRevealView { KKFocusRevealView() }
    func updateNSView(_ view: KKFocusRevealView, context: Context) {
        guard view.active != active else { return }
        view.active = active
        guard active else { return }
        // One layout turn after a focus edge. No polling or scroll-driven update loop.
        DispatchQueue.main.async { [weak view] in
            guard let view, view.active, view.window != nil else { return }
            view.window?.contentView?.layoutSubtreeIfNeeded()
            view.scrollToVisible(view.bounds.insetBy(dx: -4, dy: -4))
            view.synchronizeAccessibilityFocus()
        }
    }
}
private final class KKFocusRevealView: NSView {
    var active = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func synchronizeAccessibilityFocus() {
        guard active, let window, window.isKeyWindow else { return }
        let target = window.convertToScreen(convert(bounds, to: nil))
        var remaining = 256
        func leaf(_ object: Any, depth: Int) -> (any NSAccessibilityProtocol)? {
            guard remaining > 0, depth < 20 else { return nil }
            remaining -= 1
            let children: [Any]
            if let element = object as? any NSAccessibilityProtocol {
                let frame = element.accessibilityFrame()
                let role = element.accessibilityRole()?.rawValue ?? ""
                if KKAXFocusGeometry.matches(frame, target),
                   KKAXFocusGeometry.controlRoles.contains(role) { return element }
                children = element.accessibilityChildren() ?? []
            } else if let node = object as? NSObject,
                      node.responds(to: NSSelectorFromString("accessibilityChildren")) {
                // SwiftUI AccessibilityNode implements the informal getter but
                // does not declare NSAccessibilityProtocol. Traverse through it;
                // only concrete native controls below it are mutated.
                children = node.perform(NSSelectorFromString("accessibilityChildren"))?.takeUnretainedValue() as? [Any] ?? []
            } else { return nil }
            for child in children {
                if let found = leaf(child, depth: depth + 1) { return found }
            }
            return nil
        }
        // Start at the control's wrapper, never traverse the window/application.
        var ancestor = superview
        for _ in 0..<4 {
            guard let container = ancestor, container !== window.contentView else { break }
            if let control = leaf(container, depth: 0) {
                if let native = control as? NSView, native.acceptsFirstResponder,
                   window.firstResponder !== native {
                    guard window.makeFirstResponder(native) else { return }
                }
                control.setAccessibilityFocused(true)
                NSAccessibility.post(element: control, notification: .focusedUIElementChanged)
                return
            }
            ancestor = container.superview
        }
    }
}

enum KKAXFocusGeometry {
    static let controlRoles: Set<String> = ["AXButton", "AXCheckBox", "AXSwitch", "AXRadioButton",
        "AXTextField", "AXTextArea", "AXSlider", "AXPopUpButton", "AXComboBox", "AXOutline", "AXLink"]
    static func matches(_ frame: CGRect, _ target: CGRect) -> Bool {
        frame.width > 0 && frame.height > 0 &&
        abs(frame.minX - target.minX) <= 2 && abs(frame.minY - target.minY) <= 2 &&
        abs(frame.width - target.width) <= 2 && abs(frame.height - target.height) <= 2
    }
}

/// NSTextView normally inserts Tab in a multiline editor. Keep the SwiftUI editor
/// and its delegate, intercepting only the two native navigation commands.
enum KKEditorTabDirection {
    static func command(_ selector: Selector) -> Int {
        switch NSStringFromSelector(selector) {
        case "insertTab:": return 1
        case "insertBacktab:": return -1
        default: return 0
        }
    }
}
private final class KKEditorTabDelegate: NSObject, NSTextViewDelegate {
    weak var original: NSTextViewDelegate?
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch KKEditorTabDirection.command(commandSelector) {
        case 1: textView.window?.selectNextKeyView(nil); return true
        case -1: textView.window?.selectPreviousKeyView(nil); return true
        default: return original?.textView?(textView, doCommandBy: commandSelector) ?? false
        }
    }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        if original?.responds(to: selector) == true { return original }
        return super.forwardingTarget(for: selector)
    }
}
private final class KKEditorTabView: NSView {
    private let proxy = KKEditorTabDelegate()
    private weak var editor: NSTextView?
    private var pending = false
    private var retired = false
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func schedule() {
        guard !retired, !pending else { return }
        if let editor, editor.delegate === proxy { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            guard !self.retired, self.window != nil else { return }
            let target = self.convert(self.bounds, to: nil)
            var ancestor = self.superview
            while let container = ancestor {
                func find(_ view: NSView) -> NSTextView? {
                    if let text = view as? NSTextView, !text.isHiddenOrHasHiddenAncestor,
                       text.convert(text.bounds, to: nil).intersects(target) { return text }
                    return view.subviews.lazy.compactMap(find).first
                }
                if let text = find(container) {
                    if self.editor !== text { self.detach(); self.editor = text }
                    if text.delegate !== self.proxy {
                        self.proxy.original = text.delegate
                        text.delegate = self.proxy
                    }
                    return
                }
                ancestor = container.superview
            }
        }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
    override func layout() { super.layout(); schedule() }
    func retire() { retired = true; detach() }
    func detach() {
        if let editor, editor.delegate === proxy { editor.delegate = proxy.original }
        editor = nil
    }
}
private struct KKEditorTabNavigation: NSViewRepresentable {
    func makeNSView(context: Context) -> KKEditorTabView { KKEditorTabView() }
    func updateNSView(_ view: KKEditorTabView, context: Context) { view.schedule() }
    static func dismantleNSView(_ view: KKEditorTabView, coordinator: ()) { view.retire() }
}
extension View {
    func kkTabNavigation() -> some View {
        background { KKEditorTabNavigation().allowsHitTesting(false).accessibilityHidden(true) }
    }
}

/// Replacement for the automatic sidebar item, using the same native Button and ring.
struct KKSidebarToggle: View {
    @Binding var visibility: NavigationSplitViewVisibility
    let showTitle: String
    let hideTitle: String
    var body: some View {
        Button { visibility = visibility == .detailOnly ? .all : .detailOnly } label: {
            Image(systemName: "sidebar.left").frame(width: 28, height: 28)
                .foregroundStyle(KKColor.textPrimary)
        }
        .buttonStyle(KKPlainButtonStyle())
        .accessibilityLabel(visibility == .detailOnly ? showTitle : hideTitle)
        .accessibilityIdentifier("kk-sidebar-toggle")
        .help(visibility == .detailOnly ? showTitle : hideTitle)
    }
}

#if DEBUG
// Passive diagnostics of the SAME FocusState that drives the ring. No focus writes.
private struct KKFocusAuditID: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    var kkFocusAuditID: String {
        get { self[KKFocusAuditID.self] }
        set { self[KKFocusAuditID.self] = newValue }
    }
}
struct KKFocusSamples: PreferenceKey {
    static let defaultValue: [String: Bool] = [:]
    static func reduce(value: inout [String: Bool], nextValue: () -> [String: Bool]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
#endif
enum KKFocusGeometry {
    static let ringWidth: CGFloat = 2
    static let gap: CGFloat = 2
    static let centerOutset = gap + ringWidth / 2
    static let baseWidth = ringWidth + gap * 2
}
struct KKFocusOutline: View {
    let active: Bool
    var radius: CGFloat = 6
    var body: some View {
        Group {
            if active {
                RoundedRectangle(cornerRadius: radius + KKFocusGeometry.centerOutset)
                    .stroke(KKColor.surfaceBase, lineWidth: KKFocusGeometry.baseWidth)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius + KKFocusGeometry.centerOutset)
                            .stroke(KKColor.focusRing, lineWidth: KKFocusGeometry.ringWidth)
                    }
                    .padding(-KKFocusGeometry.centerOutset) // inner edge at 2pt outside the control, 2pt brand stroke.
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
extension View {
    func kkFocusRing(radius: CGFloat = 6) -> some View { modifier(KKFocusRing(radius: radius)) }
}

/// Keep link/icon artwork unchanged while enlarging the actual Button label hit area.
private struct KKPlainButtonArtwork: ButtonStyle {
    var radius: CGFloat = 6
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 28, minHeight: 28)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Binding values and option order match the replaced native segmented Pickers.
struct KKSegmentedPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(String, Value)]
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = selection == option.1
                Button { selection = option.1 } label: {
                    Text(option.0).font(.system(size: 12))
                        .frame(minWidth: 28, maxWidth: .infinity, minHeight: 28)
                        .padding(.horizontal, 6)
                        .foregroundStyle(selected ? KKColor.textPrimary : KKColor.textSecondary)
                        .background(selected ? KKColor.surfaceSelected : KKColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 5))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(KKColor.textPrimary.opacity(selected ? 1 : 0), lineWidth: 1)
                        }
                }
                .buttonStyle(KKPlainButtonStyle(radius: 5))
                .accessibilityLabel(option.0)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2).background(KKColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain).accessibilityLabel(title)
        .opacity(enabled ? 1 : 0.75)
    }
}


extension Text {
    /// Use font metrics rather than adding the full line-height difference as
    /// spacing: a 17pt system font already has a line box taller than 17pt.
    func kkCaptionLineHeight(fontSize: Double, lineHeight: Double) -> some View {
        let natural = NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: fontSize))
        return self.lineSpacing(max(0, lineHeight - natural))
            .frame(minHeight: lineHeight, alignment: .topLeading)
    }
}

/// The six main pages use their sidebar key and a single title style.
struct MainPageTitle: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 24, weight: .bold))
            .foregroundStyle(KKColor.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Identity destroys the outgoing SwiftUI page and its key views. No candidate cache.
extension View {
    func kkKeyboardPage(_ id: String) -> some View {
        self.id(id).accessibilityElement(children: .contain)
            .accessibilityIdentifier("kk-page-" + id)
            .focusSection()
    }
}

/// Window activation only. SwiftUI defaultFocus and the native key loop choose controls.
struct KKMenuKeyboardAccess: NSViewRepresentable {
    let presented: Bool
    func makeNSView(context: Context) -> KKMenuFocusView { KKMenuFocusView() }
    func updateNSView(_ view: KKMenuFocusView, context: Context) { view.setPresented(presented) }
}
final class KKMenuFocusView: NSView {
    private var presented = false
    private var pending = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func setPresented(_ value: Bool) {
        guard presented != value else { return }
        presented = value
        if value { activate() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.setAccessibilityIdentifier("kk-menu-panel")
        if presented { activate() }
    }
    private func activate() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            guard self.presented, let window = self.window else { return }
            if let panel = window as? NSPanel { panel.becomesKeyOnlyIfNeeded = false }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.recalculateKeyViewLoop()
#if DEBUG
            let evidence="KKMenuWindow class=\(type(of: window)) canBecomeKey=\(window.canBecomeKey) isKey=\(window.isKeyWindow) number=\(window.windowNumber) responder=\(String(describing: window.firstResponder.map { type(of: $0) }))\n"
            FileHandle.standardError.write(Data(evidence.utf8))
#endif
        }
    }
}
