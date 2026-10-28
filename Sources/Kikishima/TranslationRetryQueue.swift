import Foundation

struct TranslationRetryQueue {
    private(set) var pending: [UUID] = []

    var isEmpty: Bool { pending.isEmpty }

    mutating func enqueue(_ id: UUID) {
        guard !pending.contains(id) else { return }
        pending.append(id)
    }

    mutating func takeRecent(limit: Int) -> [UUID] {
        guard limit > 0, !pending.isEmpty else { return [] }
        let start = max(0, pending.count - limit)
        let recent = Array(pending[start...])
        pending.removeSubrange(start...)
        return recent
    }

    mutating func requeue(_ ids: [UUID]) {
        ids.forEach { enqueue($0) }
    }

    mutating func remove(_ ids: Set<UUID>) {
        pending.removeAll { ids.contains($0) }
    }
}
