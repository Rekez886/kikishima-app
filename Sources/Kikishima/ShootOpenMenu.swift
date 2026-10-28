#if SHOOT || DEBUG
import AppKit

@MainActor
final class ShootOpenMenu {
    static let shared = ShootOpenMenu()
    private var machine = ShootMenuState(now: ProcessInfo.processInfo.systemUptime)
    private var timer: Timer?
    private weak var item: NSStatusItem?
    private weak var menu: NSWindow?
    private var activationFinished: (() -> Void)?
    private var lastInventory = ""
    private var lastFrame: NSRect?
    private var started = false
    private var requested = false
    private var present: (() -> Void)?
    private static let begin = NSSelectorFromString("_beginExpandedInterfaceSession:")
    private static let delegate = NSSelectorFromString("expandedInterfaceDelegate")
    private static let session = NSSelectorFromString("expandedInterfaceSession")

    func start(openMenu: Bool = true) {
        guard !started else { return }
        started = true
        requested = openMenu
        machine = ShootMenuState(now: ProcessInfo.processInfo.systemUptime)
        if requested { ShootDiagnosticLog.shared?.event("open-menu", "from=idle to=waitingForStatusItem attempt=0 result=waiting") }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    func discovered(_ item: NSStatusItem, present: @escaping () -> Void) {
        self.item = item; self.present = present
        inventory(source: "MenuBarExtraAccess-index-0")
    }
    func attached(_ window: NSWindow, activationFinished: @escaping () -> Void) {
        menu = window
        self.activationFinished = activationFinished
        ShootWindowLog.watch(window, kind: "menu-panel")
    }
    private func object(_ item: NSStatusItem, _ selector: Selector) -> AnyObject? {
        guard item.responds(to: selector) else { return nil }
        return item.perform(selector)?.takeUnretainedValue()
    }
    private func inventory(source: String) {
        let windows = NSApp.windows.filter { $0.className.contains("NSStatusBarWindow") }
        let items = windows.compactMap { window -> NSStatusItem? in
            guard let value = (window.value(forKey: "statusItem") as? NSStatusItem
                ?? Mirror(reflecting: window).descendant("statusItem") as? NSStatusItem),
                  value.className == "NSSceneStatusItem" else { return nil }
            return value
        }
        let count = ShootStatusInventory.count(items.map(ObjectIdentifier.init))
        let identities = items.map { String(describing: ObjectIdentifier($0)) }.sorted().joined(separator: ",")
        let frame = item?.button.flatMap { button in button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) } }
        let fields = "count=\(count) windows=\(windows.count) identities=\(identities) frame=\(frame.map(ShootWindowLog.frame) ?? "unavailable") source=\(source)"
        if fields != lastInventory { lastInventory = fields; ShootDiagnosticLog.shared?.event("status-item", fields) }
    }
    private func tick() {
        inventory(source: "poll")
        guard requested else { return }
        let old = machine.phase
        var input = ShootMenuState.Input()
        if let item {
            input.statusReady = item.button?.window != nil
            if #available(macOS 27, *) {
                input.sessionAvailable = item.responds(to: Self.begin) && object(item, Self.delegate) != nil
                input.sessionActive = object(item, Self.session) != nil
            }
        }
        input.windowVisible = menu?.isVisible == true
        if old == .anchoring, let menu {
            input.anchored = ShootMenuPlacement.position(menu, below: item?.button)
            if input.anchored == true {
                if let panel = menu as? NSPanel { panel.becomesKeyOnlyIfNeeded = false }
                NSApp.activate(ignoringOtherApps: true)
                menu.makeKeyAndOrderFront(nil)
                menu.recalculateKeyViewLoop()
                activationFinished?()
            }
        }
        machine.step(now: ProcessInfo.processInfo.systemUptime, input: input)
        if old != machine.phase {
            ShootDiagnosticLog.shared?.event("open-menu", "from=\(old.rawValue) to=\(machine.phase.rawValue) attempt=\(machine.attempt) result=\(machine.reason.isEmpty ? machine.phase.rawValue : machine.reason)")
            if old == .shown { ShootDiagnosticLog.shared?.event("menu-panel", "closed attempt=\(machine.attempt)") }
            if machine.phase == .waitingForWindow, let item {
                // Same guarded SPI and timestamp ABI as MenuBarExtraAccess 1.3.1.
                // Never fall back to target/action when unavailable.
                if !input.sessionActive, let implementation = item.method(for: Self.begin) {
                    typealias Begin = @convention(c) (NSStatusItem, Selector, TimeInterval) -> Void
                    unsafeBitCast(implementation, to: Begin.self)(item, Self.begin, .greatestFiniteMagnitude)
                }
                ShootDiagnosticLog.shared?.event("open-menu-attempt", "attempt=\(machine.attempt) result=\(object(item, Self.session) != nil ? "session-active" : "session-pending")")
                present?()
            }
            if machine.phase == .shown, let menu {
                ShootDiagnosticLog.shared?.event("menu-panel", "shown frame=\(ShootWindowLog.frame(menu.frame))")
                lastFrame = menu.frame
            }
            if machine.phase == .failed {
                fputs("OPEN_MENU failed: \(machine.reason) attempt=\(machine.attempt)\n", stderr)
                // Stay alive so the tester can take the fallback screenshot; keep status-item polling.
                requested = false
            }
        }
        if machine.phase == .shown, let menu, lastFrame != menu.frame {
            ShootDiagnosticLog.shared?.event("menu-panel", "moved frame=\(ShootWindowLog.frame(menu.frame))")
            lastFrame = menu.frame
        }
    }
}

@MainActor
enum ShootWindowLog {
    private static var vendorObserver: NSObjectProtocol?
    private static var observers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    static func start() {
        guard ShootDiagnosticLog.shared?.enabled == true else { return }
        vendorObserver = NotificationCenter.default.addObserver(forName: .init("KikishimaShootFrameRequest"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow, let target = note.userInfo?["to"] as? NSRect else { return }
                request(window, to: target, caller: "show", animate: false,
                        site: note.userInfo?["site"] as? String ?? "DynamicNotchKit:unknown")
            }
        }
    }
    static func frame(_ value: NSRect) -> String {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return String(format: "%.1f,%.1f,%.1fx%.1f", value.minX, top - value.maxY, value.width, value.height)
    }
    static func request(_ window: NSWindow?, to: NSRect, caller: String, animate: Bool,
                        file: StaticString = #fileID, line: UInt = #line) {
        request(window, to: to, caller: caller, animate: animate, site: "\(file):\(line)")
    }
    private static func request(_ window: NSWindow?, to: NSRect, caller: String, animate: Bool, site: String) {
        guard ShootDiagnosticLog.shared?.enabled == true, let window else { return }
        watch(window)
        ShootDiagnosticLog.shared?.event("island-setFrame", "caller=\(caller) site=\(site) animate=\(animate) from=\(frame(window.frame)) to=\(frame(to))")
    }
    static func watch(_ window: NSWindow, kind: String = "island-window") {
        guard ShootDiagnosticLog.shared?.enabled == true, observers[ObjectIdentifier(window)] == nil else { return }
        observers[ObjectIdentifier(window)] = [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification, NSWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] note in
                MainActor.assumeIsolated {
                    guard let window else { return }
                    ShootDiagnosticLog.shared?.event(kind, "event=\(note.name.rawValue) frame=\(frame(window.frame))")
                }
            }
        }
    }
}
#endif
