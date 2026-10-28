import Foundation
// A stale local translation completes while a new session already has 3 requests.
for inflight in [0, 1, 3] {
    precondition(TranslationCompletionPolicy.remainingInflight(inflight,
        requestGeneration: 10, currentGeneration: 11) == inflight,
        "audit16: stale local completion must not release the new session's slot")
}
precondition(TranslationCompletionPolicy.remainingInflight(3, requestGeneration: 11,
    currentGeneration: 11) == 2, "audit16: current completion releases one slot")
precondition(TranslationCompletionPolicy.remainingInflight(0, requestGeneration: 11,
    currentGeneration: 11) == 0, "audit16: counter cannot become negative")
print("PASS audit16 generation isolation")
