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
