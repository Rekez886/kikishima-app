import Foundation

// Translation networking is linked but never called by these deterministic tests.
func trAny(_ text: String, _ args: CVarArg...) -> String { text }

var checks = 0
func check(_ condition: Bool) { precondition(condition); checks += 1 }
func cut(_ text: String, age: Double = 10, stable: Double = 0, done: Int = 0,
         tuning: ChunkTuning = .medium) -> Int {
    translationCutoff(text, doneChars: done, tuning: tuning, age: age, stableFor: stable)
}
for text in ["Yes", "OK", "はい", "好", "We agree", "明日確認します"] {
    check(cut(text, stable: 0.3) == 0)
    check(cut(text, stable: 2.1) == text.count)
}
check(cut("Yes.", age: 0.5) == 0)
check(cut("Yes.", age: 1.4) == 4)
check(cut("好。", age: 1.4) == 2)
check(cut("We will launch next week", stable: 0.2) == 0)
check(cut("We will launch next week", stable: 2.1) == 24)
check(cut("...", stable: 5) == 0)
check(cut("We agree", stable: 2.1, tuning: .long) == 0)
check(cut("We agree", stable: 2.8, tuning: .long) == 8)
let continuous = "We will review the complete proposal together before we confirm the release date"
let boundary = cut(continuous)
check(boundary > 0 && boundary < continuous.count)
check(Array(continuous)[boundary - 1].isWhitespace)
check(cut(continuous, stable: 2.1, done: boundary) == continuous.count)
let cjk = String(repeating: "明日確認します", count: 8)
check(cut(cjk) == ChunkTuning.medium.hardCutCJK)
check(cut("We agree. Next topic", age: 0) == 9)

var clock = PendingTextClock()
clock.update("First. ", now: 1)
clock.update("First. Next", now: 4)
check(clock.firstAt == 1)
clock.consume(7)
clock.update("Next", now: 5)
check(clock.firstAt == 4) // Remaining text must not inherit First's arrival.
check(clock.changedAt == 4) // Consuming a prefix is not new speech.
clock.update("Next topic", now: 6)
check(clock.firstAt == 4 && clock.changedAt == 6)
clock.update("New topic", now: 7)
check(clock.firstAt == 4) // Shared prefix retains its actual observation.
clock.update("Other", now: 8)
check(clock.firstAt == 8)
clock.update("", now: 9)
check(clock.firstAt == nil && clock.changedAt == nil)
clock.update("はい", now: 10)
check(clock.firstAt == 10)
print("PASS: \(checks) dispatch and observation-clock checks; no network calls")

func reason(_ text: String, age: Double = 10, stable: Double = 0,
            tuning: ChunkTuning = .medium, final: Bool = false, forced: Bool = false) -> TranslationCutReason? {
    translationCutReason(text, doneChars: 0, tuning: tuning, age: age, stableFor: stable, finalized: final, forced: forced)
}
check(reason("We agree. Next topic", age: 0) == .sentence)
check(reason("We review the complete proposal, then continue with the release") == .clause)
check(reason("Yes.", age: 1.4) == .shortTimeout)
check(reason("Yes.", age: 0.5) == nil)
check(reason("We agree", stable: 2.1) == .stable)
check(reason("We agree", age: 2.5, stable: 2.1, final: true) == .stable)
check(reason("We agree", age: 2.1, stable: 2.1, final: true) == nil)
check(reason(continuous) == .length)
check(reason(cjk) == .length)
check(reason("Tail", forced: true) == .forced)
check(reason("好。", age: 1.4) == .shortTimeout)
check(reason("明日確認してから、予定について改めて全員と相談します", tuning: .short) == .clause)
check(reason("...") == nil)
print("PASS: all six numeric cut reasons, suppressed short sentence and Latin/CJK boundaries")

func expectTail(_ text: String, tuning: ChunkTuning, age: Double, stable: Double,
                final: Bool, cuts: Bool) {
    let cutoff = translationCutoff(text, doneChars: 0, tuning: tuning, age: age,
                                   stableFor: stable, finalized: final)
    check(cutoff == (cuts ? text.count : 0))
    check(reason(text, age: age, stable: stable, tuning: tuning, final: final) == (cuts ? .stable : nil))
}
for tuning in [ChunkTuning.short, .medium] {
    for text in ["We can approve", "明日確認"] {
        expectTail(text, tuning: tuning, age: 2.5, stable: 0.9, final: true, cuts: false)
        expectTail(text, tuning: tuning, age: 1, stable: 1, final: true, cuts: true)
        expectTail(text, tuning: tuning, age: 2.4, stable: 1, final: false, cuts: false)
        expectTail(text, tuning: tuning, age: 2.5, stable: 1, final: false, cuts: true)
        expectTail(text, tuning: tuning, age: 8, stable: 0.9, final: false, cuts: false)
    }
    for text in ["We agree", "Yes", "確認中", "はい", "不"] {
        expectTail(text, tuning: tuning, age: 2.4, stable: 1, final: true, cuts: false)
        expectTail(text, tuning: tuning, age: 2.5, stable: 1, final: true, cuts: true)
    }
}
for stable in [1.0, 2.5] {
    expectTail("We can approve", tuning: .long, age: 5, stable: stable, final: true, cuts: false)
}
expectTail("We agree", tuning: .long, age: 2.7, stable: 2.7, final: true, cuts: true)
expectTail("We agree", tuning: .long, age: 3.9, stable: 3, final: false, cuts: false)
expectTail("We agree", tuning: .long, age: 4, stable: 3, final: false, cuts: true)

// Synthetic ASR replay through the shared meeting/video chunker and ledger.
var ledger = TranslationSourceLedger()
var replayClock = PendingTextClock()
let positive = "We can approve"
replayClock.update(positive, now: 0)
_ = ledger.reconcile(positive)
let positiveCut = translationCutoff(positive, doneChars: 0, tuning: .medium,
    age: 2.5 - replayClock.firstAt!, stableFor: 2.5 - replayClock.changedAt!, finalized: false)
check(positiveCut == positive.count)
let oldChunk = UUID()
ledger.register(oldChunk, range: 0..<positiveCut)
let negative = "We cannot approve"
let revision = ledger.reconcile(negative)
check(revision.removed.contains(oldChunk) && revision.rewind == 0)
expectTail(negative, tuning: .medium, age: 1, stable: 1, final: true, cuts: true)

// Volatile word expansions reset stability on the retained prefix.
for pair in [("Yes", "Yesterday we agreed"), ("不", "不能批准这个方案")] {
    var pending = PendingTextClock()
    pending.update(pair.0, now: 0)
    expectTail(pair.0, tuning: .medium, age: 1 - pending.firstAt!, stable: 1 - pending.changedAt!, final: false, cuts: false)
    pending.update(pair.1, now: 1.5)
    check(pending.changedAt == 1.5)
    expectTail(pair.1, tuning: .medium, age: 2.4 - pending.firstAt!, stable: 2.4 - pending.changedAt!, final: false, cuts: false)
    expectTail(pair.1, tuning: .medium, age: 2.5 - pending.firstAt!, stable: 2.5 - pending.changedAt!, final: false, cuts: true)
}
// A finalized acknowledgement stays committed and joins an appended final phrase.
var finalClock = PendingTextClock()
finalClock.update("Yes", now: 0)
expectTail("Yes", tuning: .medium, age: 1, stable: 1, final: true, cuts: false)
finalClock.update("Yes we agreed", now: 1.2)
expectTail("Yes we agreed", tuning: .medium, age: 2.2 - finalClock.firstAt!,
           stable: 2.2 - finalClock.changedAt!, final: true, cuts: true)
print("PASS: \(checks) total checks including thresholds, fragments, negation and continuation replay")
