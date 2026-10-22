#if SHOOT
import AppKit
import DynamicNotchKit

struct ShootNotchConfiguration: Equatable {
    let top: CGFloat
    let left: CGFloat
    let right: CGFloat
    let screen: CGFloat
    // 暂定，非实测 / provisional, not measured. SHOOT artwork only.
    static let provisionalRadius: CGFloat = 8
    let radius: CGFloat
    let menubar: CGFloat
    var width: CGFloat { screen - left - right }

    enum Invalid: Error { case configuration }
    static func parse(_ raw: String) throws -> Self {
        var values: [String: CGFloat] = [:]
        let requiredKeys: Set<String> = ["top", "left", "right", "screen"]
        let keys = requiredKeys.union(["radius", "menubar"])
        for entry in raw.split(separator: ",", omittingEmptySubsequences: false) {
            let pair = entry.split(separator: "=", omittingEmptySubsequences: false)
            guard pair.count == 2, keys.contains(String(pair[0])),
                  values[String(pair[0])] == nil,
                  let number = Double(pair[1]), number.isFinite, number >= 0 else {
                throw Invalid.configuration
            }
            values[String(pair[0])] = CGFloat(number)
        }
        guard requiredKeys.isSubset(of: Set(values.keys)) else { throw Invalid.configuration }
        let result = Self(top: values["top"]!, left: values["left"]!, right: values["right"]!,
                          screen: values["screen"]!, radius: values["radius"] ?? provisionalRadius,
                          menubar: values["menubar"] ?? values["top"]!)
        guard result.top > 0, result.width > 0,
              result.radius <= min(result.top, result.width / 2) else { throw Invalid.configuration }
        return result
    }

    static func requested(arguments: [String], environment: [String: String]) throws -> Self? {
        let key = "-KikishimaShootNotch"
        let raw: String?
        if arguments.contains(key) {
            guard let value = ShootSimulation.argument(key, in: arguments) else { throw Invalid.configuration }
            raw = value
        } else { raw = environment["KIKISHIMA_SHOOT_NOTCH"] }
        return try raw.map(parse)
    }
}

@MainActor
enum ShootNotch {
    static let configuration: ShootNotchConfiguration? = {
        do {
            return try ShootNotchConfiguration.requested(arguments: ProcessInfo.processInfo.arguments,
                                                         environment: ProcessInfo.processInfo.environment)
        } catch {
            fputs("Invalid KikishimaShootNotch / KIKISHIMA_SHOOT_NOTCH: require top,left,right,screen; optional radius (8pt provisional, not measured), menubar (defaults to top); finite nonnegative numbers, positive height/width, and radius fitting the bottom corners\n", stderr)
            exit(1)
        }
    }()
    private static var panel: NSPanel?

    static func selectedScreen() -> NSScreen? {
        guard let configuration else { return nil }
        // Stable selection: first external display, then the first display as fallback.
        let screens = NSScreen.screens
        let selected = screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(id.uint32Value)) == 0
        } ?? screens.first
        ShootNotchInjection.screen = selected
        ShootNotchInjection.size = CGSize(width: configuration.width, height: configuration.top)
        ShootNotchInjection.menuBarHeight = configuration.menubar
        return selected
    }

    static func size(on screen: NSScreen) -> CGSize? {
        guard let selected = selectedScreen(), selected === screen, let configuration else { return nil }
        return CGSize(width: configuration.width, height: configuration.top)
    }

    static func menuBarHeight(on screen: NSScreen) -> CGFloat? {
        guard let selected = selectedScreen(), selected === screen else { return nil }
        return configuration?.menubar
    }

    static func show(on screen: NSScreen, sharingType: NSWindow.SharingType, above level: NSWindow.Level) {
        guard let size = size(on: screen), let configuration else { panel?.orderOut(nil); return }
        let window = panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        panel = window
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.sharingType = sharingType
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.level = NSWindow.Level(rawValue: level.rawValue + 1)
        let view = ShootNotchMask(frame: CGRect(origin: .zero, size: size), radius: configuration.radius)
        window.contentView = view
        window.setFrame(CGRect(x: screen.frame.midX - size.width / 2,
                               y: screen.frame.maxY - size.height, width: size.width, height: size.height), display: true)
        window.orderFrontRegardless()
    }
    static func hide() { panel?.orderOut(nil) }
}

// SHOOT 下角圆角默认 8pt：暂定，非实测 / provisional, not measured.
private final class ShootNotchMask: NSView {
    let radius: CGFloat
    init(frame: CGRect, radius: CGFloat) {
        self.radius = radius
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("ShootNotchMask requires an explicit radius") }
    override func draw(_ dirtyRect: NSRect) {
        let r = radius
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: bounds.maxY))
        path.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY))
        path.line(to: NSPoint(x: bounds.maxX, y: r))
        if r > 0 {
            path.appendArc(withCenter: NSPoint(x: bounds.maxX - r, y: r), radius: r,
                           startAngle: 0, endAngle: -90, clockwise: true)
        }
        path.line(to: NSPoint(x: r, y: 0))
        if r > 0 {
            path.appendArc(withCenter: NSPoint(x: r, y: r), radius: r,
                           startAngle: -90, endAngle: -180, clockwise: true)
        }
        path.close()
        NSColor.black.setFill()
        path.fill()
    }
}
#endif
