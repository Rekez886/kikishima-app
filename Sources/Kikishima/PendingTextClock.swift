import Foundation

/// In-memory character observation times, never persisted with transcript text.
struct PendingTextClock {
    private var characters: [Character] = []
    private var observed: [TimeInterval] = []
    private(set) var changedAt: TimeInterval?
    var firstAt: TimeInterval? {
        characters.firstIndex(where: { !$0.isWhitespace }).map { observed[$0] }
    }

    mutating func update(_ text: String, now: TimeInterval) {
        let next = Array(text)
        guard next != characters else { return }
        var shared = 0
        while shared < min(next.count, characters.count), next[shared] == characters[shared] { shared += 1 }
        observed = Array(observed.prefix(shared)) + Array(repeating: now, count: next.count - shared)
        characters = next
        changedAt = next.isEmpty ? nil : now
    }

    mutating func consume(_ count: Int) {
        let count = min(max(0, count), characters.count)
        characters.removeFirst(count)
        observed.removeFirst(count)
        if characters.isEmpty { changedAt = nil }
    }

    func stable(now: TimeInterval, for duration: TimeInterval) -> Bool {
        changedAt.map { now - $0 >= duration } ?? false
    }
}
