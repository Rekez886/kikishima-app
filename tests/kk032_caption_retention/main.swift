import Foundation
import AppKit
var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL \(message)"); failures += 1 }
}
let ids = (0..<65).map { _ in UUID() }
func items(_ flags: [Bool]) -> [CaptionReadingPolicy.DesktopItem] {
    flags.enumerated().map { .init(id: ids[$0.offset], finalized: $0.element, translated: $0.element) }
}
var q = CaptionReadingPolicy.DesktopQueue()
func layout(_ flags: [Bool], _ time: Double, limit: Int = 3, pending: Bool = false) -> CaptionReadingPolicy.DesktopLayout {
    CaptionReadingPolicy.desktopLayout(items: items(flags), historyLimit: limit, pending: pending, now: time, queue: &q)
}
var r = layout([true,false,false,false,false], 0)
check(r.current == ids[1] && r.ids == [ids[0],ids[1]], "Boss B remains current; later requests hidden")
r = layout([true,false,true,false,false], 4.9)
check(r.current == ids[1] && !r.ids.contains(ids[2]), "4.9 seconds blocks C")
r = layout([true,false,true,false,false], 5)
check(r.current == ids[1], "exactly 5 seconds blocks C")
r = layout([true,false,true,false,false], 5.1)
check(r.history == [ids[0],ids[1],ids[2]] && r.current == ids[3], "timeout advances B and C in source order")
check(r.sourceOnly == [ids[1]], "timed out B has blank translation")
r = layout([true,true,true,false,false], 5.2)
check(r.history == [ids[0],ids[1],ids[2]] && r.sourceOnly.isEmpty, "late translation fills same slot")
q = .init(); _ = layout([true,false,false], 0)
r = layout([true,false,false], 30)
check(r.current == ids[1], "no later completed request means no timeout")
q = .init(); _ = layout([true,false,true,false], 0, limit: 1)
r = layout([true,false,true,false], 5.1, limit: 1)
check(r.history == [ids[1]] && r.current == ids[2], "pinned history blocks further promotion at capacity one")
r = layout([true,true,true,false], 6, limit: 1)
check(r.history == [ids[2]] && r.current == ids[3], "completion releases capacity")
q = .init(); _ = layout([true,false,true], 0)
r = layout([true,true,true], 4)
check(r.ids == [ids[0],ids[1],ids[2]], "B completes before timeout; B C ordered")
q = .init(); r = layout([true,true], 0, pending: true)
check(r.current == nil && r.showsPending, "ASR pending alone occupies current slot")
q = .init(); r = layout([true,false], 0, pending: true)
check(r.current == ids[1] && !r.showsPending, "no second ASR current")
for compact in [false,true] {
    for status in [false,true] {
        let chrome = compact ? 28.0 : (status ? 32.0 : 0)
        let small = CaptionHierarchy.desktopHistoryCount(availableHeight: 220-chrome, userSize: 18, showTranslation: true, showSource: true)
        let large = CaptionHierarchy.desktopHistoryCount(availableHeight: 600-chrome, userSize: 18, showTranslation: true, showSource: true)
        print("HEIGHT compact=\(compact) status=\(status) 220=\(small) 600=\(large)")
        check(large > small && small >= 1, "height-dependent history")
    }
}
check(CaptionHierarchy.desktopHistoryCount(availableHeight: 0, userSize: 24, showTranslation: true, showSource: true) == 1, "capacity floor")
// Typography is executed with real system font metrics, including CJK and
// composed characters. Explicit newlines and wrapped long sentences use the
// same production splitter and preserve the latest two complete lines.
let three = CaptionReadingPolicy.desktopText(primary: "first\nsecond\nthird", secondary: "source", translated: true, width: 400, userSize: 18)
check(three.primary == "second\nthird" && three.overflow == ["first"] && three.lineCount == 2, "three translated lines retain newest two and move old line to history")
check(three.height(scale: 1) == 70, "two lines plus source actual height")
let single = CaptionReadingPolicy.desktopText(primary: "short", secondary: nil, translated: true, width: 400, userSize: 18)
check(single.height(scale: 1) == 24, "one-line current does not reserve two lines")
for family in ["system", "rounded", "serif", "mono"] {
    let text = "We review the complete draft together before Friday. 日本語の長い字幕と中文。 👨‍👩‍👧‍👦"
    let all = CaptionReadingPolicy.desktopWrappedLines(text, width: 130, font: CaptionReadingPolicy.desktopFont(size: 17, family: family, medium: true))
    let shown = CaptionReadingPolicy.desktopText(primary: text, secondary: nil, translated: true, width: 130, userSize: 18, family: family)
    check(shown.primary == all.suffix(2).joined(separator: "\n") && shown.overflow == Array(all.dropLast(2)), "real wrapping retains exact suffix for " + family)
}
let tail = CaptionReadingPolicy.desktopSourceTail("An unusually long source sentence with latest words", width: 130, font: CaptionReadingPolicy.desktopFont(size: 13, family: "system"))
check(tail.hasPrefix("…") && tail.hasSuffix("words"), "source truncates head with ellipsis")
for mode in [(true,true),(true,false),(false,true)] {
    let two = CaptionHierarchy.desktopHistoryCount(availableHeight: 220, userSize: 18, showTranslation: mode.0, showSource: mode.1, currentHeight: 70)
    let one = CaptionHierarchy.desktopHistoryCount(availableHeight: 220, userSize: 18, showTranslation: mode.0, showSource: mode.1, currentHeight: 24)
    check(one > two, "actual current height releases history capacity")
}
var exhaustedQueue = CaptionReadingPolicy.DesktopQueue()
let exhausted = [CaptionReadingPolicy.DesktopItem(id: ids[0], finalized: true, translated: false), .init(id: ids[1], finalized: true, translated: true), .init(id: ids[2], finalized: false, translated: false)]
let exhaustedResult = CaptionReadingPolicy.desktopLayout(items: exhausted, historyLimit: 1, pending: false, now: 0, queue: &exhaustedQueue)
check(exhaustedResult.history == [ids[1]] && exhaustedResult.current == ids[2], "retry-exhausted source-only is finalized and evictable")
q = .init(); _ = layout([true,false,true,false,false], 0)
_ = layout([true,false,true,false,false], 5.1)
r = layout([true,false,true,true,false], 10)
check(r.history.contains(ids[1]) && r.history.contains(ids[3]) && r.current == ids[4], "30-second delayed B does not stop later finalized requests")
r = layout([true,false,true,true,false], 30)
check(r.history.contains(ids[1]) && r.current == ids[4], "late B stays visible through thirty seconds")
// Fixed seed event stream. Three requests in flight at most; delayed requests
// occupy a slot until completion, while the other two continue accepting work.
var seed: UInt64 = 032
func random() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1; return seed >> 32 }
for capacity in [1,3,20] {
    q = .init()
    var done: [Bool] = [], deadlines: [Int:Int] = [:], seen: Set<UUID> = []
    var timeoutSegments = 0
    for tick in 0...1200 {
        for (index, deadline) in deadlines where tick >= deadline { done[index] = true; deadlines.removeValue(forKey: index) }
        if tick % 15 == 0 && done.count < 60 && deadlines.count < 3 {
            let index = done.count
            done.append(false)
            let delay = [3,18,36].contains(index) ? (index == 3 ? 300 : 65) : 3 + Int(random() % 25)
            if delay > 50 { timeoutSegments += 1 }
            deadlines[index] = tick + delay + (index % 7 == 0 ? 15 : 0)
        }
        let priorCurrent = q.current
        let priorSince = q.currentSince
        let pinnedBefore = done.indices.filter { q.advanced.contains(ids[$0]) && !done[$0] }.count
        let out = layout(done, Double(tick)/10, limit: capacity)
        if let prior = priorCurrent, let index = ids.firstIndex(of: prior), index < done.count,
           !done[index], Double(tick)/10 - priorSince > 5,
           done.dropFirst(index + 1).contains(true), pinnedBefore < capacity {
            check(out.current != prior && out.history.contains(prior), "timeout promotes at first eligible simulation tick")
        }
        let availableHistory = q.advanced.count - (out.current.map { q.advanced.contains($0) ? 1 : 0 } ?? 0)
        check(out.history.count == min(capacity, availableHistory), "no vanished history leaving an empty slot")
        let unfinished = Set(done.indices.filter { !done[$0] }.map { ids[$0] })
        check(seen.intersection(unfinished).isSubset(of: Set(out.ids)), "simulation visible unfinished retained")
        check(out.history.compactMap { ids.firstIndex(of: $0) } == out.history.compactMap { ids.firstIndex(of: $0) }.sorted(), "simulation source order")
        check(out.history.count <= capacity, "simulation capacity")
        check(out.ids.count == Set(out.ids).count, "simulation single current")
        seen.formUnion(out.ids)
    }
    check(done.count == 60 && timeoutSegments == 3, "60 requests / three slow requests / 120 seconds")
}
if failures > 0 { exit(1) }
print("PASS KK-032 queue, heights, timeout boundaries, late results, 120-second simulation")
