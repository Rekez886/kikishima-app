#if SHOOT || DEBUG
import Foundation

/// No AppKit dependencies or side effects. All deadlines use the caller's monotonic clock.
struct ShootMenuState {
    enum Phase: String { case waitingForStatusItem, requestingSession, waitingForWindow, anchoring, shown, failed }
    struct Input {
        var statusReady = false
        var sessionAvailable = false
        var sessionActive = false
        var windowVisible = false
        var anchored: Bool? = nil
    }
    private(set) var phase: Phase = .waitingForStatusItem
    private(set) var attempt = 0
    private(set) var reason = ""
    private var entered: Double
    let timeout: Double
    let maxAttempts: Int
    init(now: Double, timeout: Double = 5, maxAttempts: Int = 3) {
        entered = now; self.timeout = timeout; self.maxAttempts = maxAttempts
    }
    mutating func step(now: Double, input: Input) {
        guard phase != .failed else { return }
        func expired() -> Bool { now - entered >= timeout }
        switch phase {
        case .waitingForStatusItem:
            if input.statusReady { attempt += 1; move(.requestingSession, now) }
            else if expired() { fail("status-item-timeout", now) }
        case .requestingSession:
            if !input.sessionAvailable { fail("session-unavailable", now) }
            else { move(.waitingForWindow, now) }
        case .waitingForWindow:
            if input.sessionActive && input.windowVisible { move(.anchoring, now) }
            else if expired() { fail("window-timeout", now) }
        case .anchoring:
            if input.anchored == true { move(.shown, now) }
            else if input.anchored == false { fail("anchor-outside-visible-frame", now) }
            else if expired() { fail("anchor-timeout", now) }
        case .shown:
            if !input.windowVisible || !input.sessionActive {
                if attempt >= maxAttempts { fail("reopen-limit", now) }
                else { move(.waitingForStatusItem, now) }
            }
        case .failed: break
        }
    }
    private mutating func move(_ next: Phase, _ now: Double) { phase = next; entered = now }
    private mutating func fail(_ why: String, _ now: Double) { reason = why; move(.failed, now) }
}

/// Count distinct native objects, not duplicate window references or AX replicas.
enum ShootStatusInventory {
    static func count(_ objects: [ObjectIdentifier]) -> Int { Set(objects).count }
}
#endif
