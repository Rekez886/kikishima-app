import Foundation

var queue = TranslationRetryQueue()
let ids = (0..<10).map { _ in UUID() }
ids.forEach { queue.enqueue($0) }
queue.enqueue(ids[0])

let recent = queue.takeRecent(limit: 6)
precondition(recent == Array(ids.suffix(6)), "Newest waiting chunks should be retried first")
precondition(queue.pending == Array(ids.prefix(4)), "Older waiting chunks must remain queued")

queue.requeue([ids[8], ids[9], ids[8]])
precondition(queue.pending == Array(ids.prefix(4)) + [ids[8], ids[9]], "Requeued chunks must stay deduplicated")

queue.remove([ids[0], ids[8]])
precondition(!queue.pending.contains(ids[0]) && !queue.pending.contains(ids[8]), "Withdrawn chunks leave the retry queue")
let exhausted = UUID()
queue.enqueue(exhausted)
queue.remove([exhausted])
precondition(!queue.pending.contains(exhausted), "exhausted automatic retries leave the queue")

print("PASS: translation retry queue")
