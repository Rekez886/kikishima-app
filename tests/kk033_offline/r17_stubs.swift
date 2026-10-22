// Subset view/entry fixtures only. The real diagnostics and state machine have
// their own runtime tests; no app/session/window is constructed by these stubs.
#if SHOOT || DEBUG
import AppKit
final class ShootDiagnosticLog {
    static var shared: ShootDiagnosticLog? { nil }
    var enabled: Bool { false }
    static func start(at anchor: UInt64) {}
}
@MainActor enum ShootWindowLog { static func start() {} }
@MainActor final class ShootOpenMenu {
    static let shared = ShootOpenMenu()
    func start(openMenu: Bool = true) {}
    func attached(_ window: NSWindow) {}
}
#endif
