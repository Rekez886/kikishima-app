import Foundation

/// Monotonic time is supplied by the caller, making expiry deterministic in tests.
struct CopyFeedback {
    static let duration: TimeInterval = 1.5
    static let fadeDuration: TimeInterval = 0.15
    private(set) var id: String?
    private(set) var deadline: TimeInterval?

    mutating func show(_ id: String, now: TimeInterval) {
        self.id = id
        deadline = now + Self.duration
    }

    @discardableResult
    mutating func expire(now: TimeInterval) -> Bool {
        guard let deadline, now >= deadline else { return false }
        id = nil
        self.deadline = nil
        return true
    }
}
