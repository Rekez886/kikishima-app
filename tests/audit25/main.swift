import Foundation

var failures = 0
func check(_ value: Bool, _ message: String) {
    if !value { failures += 1; print("FAIL audit25: \(message)") }
}
// Pure production function: current completions release exactly one slot; stale
// callbacks never take a slot from a newer session; zero never becomes negative.
for count in [0, 1, 3] {
    check(TranslationCompletionPolicy.remainingInflight(count, requestGeneration: 10, currentGeneration: 10)
          == max(0, count - 1), "current completion releases one slot, count=\(count)")
    check(TranslationCompletionPolicy.remainingInflight(count, requestGeneration: 10, currentGeneration: 11)
          == count, "stale completion preserves new-session slots, count=\(count)")
}

// Replay the source-extracted production retry transition with no network or UI.
// Cover local-only inflight (no attempt map) and remote registered attempts.
for count in [0, 1, 3] {
    for remote in [false, true] {
        let state = RetryTransitionHarness()
        state.inflight = count
        if remote {
            for _ in 0..<count { state.activeTranslationAttempts[UUID()] = UUID() }
        }
        let oldGeneration = state.sessionGen
        let oldAttempts = state.activeTranslationAttempts
        state.applyRetryTransition()
        check(state.meetingSummaryRecordID == "archived" && state.meetingSummaryGeneration != nil,
              "summary retry must still establish its own record and generation")
        if state.sessionGen == oldGeneration {
            check(state.inflight == count && state.activeTranslationAttempts == oldAttempts,
                  "preserving translation generation must preserve ownership, count=\(count), remote=\(remote)")
        } else {
            check(state.inflight == 0 && state.activeTranslationAttempts.isEmpty,
                  "advancing translation generation must clear BOTH counters, count=\(count), remote=\(remote)")
        }
        // Actual stale completion policy runs AFTER the real retry transition.
        var remaining = state.inflight
        for _ in 0..<count {
            remaining = TranslationCompletionPolicy.remainingInflight(remaining,
                requestGeneration: oldGeneration, currentGeneration: state.sessionGen)
        }
        check(remaining == 0,
              "retry + old completions must leave no permanently occupied slots, count=\(count), remote=\(remote), remaining=\(remaining)")
        // A new session already owning 3 slots is untouched by the old callback.
        check(TranslationCompletionPolicy.remainingInflight(3, requestGeneration: oldGeneration,
              currentGeneration: oldGeneration + 1) == 3, "late callback cannot consume replacement-session capacity")
    }
}
if failures > 0 { exit(1) }
print("PASS audit25 retry transition, completion policy and inflight ownership")
