import Foundation
var failures = 0
func check(_ ok: Bool, _ text: String) { if !ok { print("FAIL " + text); failures += 1 } }
let ids = (0..<65).map { _ in UUID() }
func items(_ states: [Bool]) -> [CaptionReadingPolicy.DesktopItem] {
    states.enumerated().map { .init(id: ids[$0.offset], finalized: $0.element, translated: $0.element) }
}
var queue = CaptionReadingPolicy.DesktopQueue()
func read(_ states: [Bool], _ time: Double = 0, limit: Int = 3, pending: Bool = false, sourceOnly: Bool = false) -> CaptionReadingPolicy.DesktopLayout {
    readLayout(items(states), limit: limit, pending: pending, sourceOnly: sourceOnly, now: time, queue: &queue)
}
var result = read([true,false,false,false,false])
check(result.current == ids[1] && result.ids == [ids[0],ids[1]], "Item B remains on island as sole current; A above B")
if ProcessInfo.processInfo.environment["KK036_ADAPTER"] == "baseline" {
    exit(failures == 0 ? 0 : 1)
}
result = read([true,false,true,false], 4.9)
check(result.current == ids[1] && !result.ids.contains(ids[2]), "4.9 seconds blocks completed C")
result = read([true,false,true,false], 5)
check(result.current == ids[1], "exactly 5 seconds blocks completed C")
result = read([true,false,true,false], 5.1)
check(result.history == [ids[0],ids[1],ids[2]] && result.current == ids[3], "5.1 seconds promotes B C before D")
check(result.sourceOnly == [ids[1]], "B promoted with blank translation")
check(compactIDs(result) == [ids[3]], "compact and expanded use same current")
result = read([true,true,true,false], 6)
check(result.history == [ids[0],ids[1],ids[2]] && result.sourceOnly.isEmpty, "late B fills same history position")
queue = .init(); _ = read([true,false,true], 0)
result = read([true,true,true], 4)
check(result.history == [ids[0],ids[1]] && result.current == ids[2], "B C complete in source order before timeout")
queue = .init(); _ = read([true,false,false], 0)
result = read([true,false,false], 30)
check(result.current == ids[1], "no later completed request means no timeout")
queue = .init(); _ = read([true,false,true,false], 0, limit: 1)
result = read([true,false,true,false], 5.1, limit: 1)
check(result.history == [ids[1]] && result.current == ids[2], "one history slot pins unfinished B and pauses more promotions")
queue = .init(); _ = read([true,false,true,false,false], 0)
_ = read([true,false,true,false,false], 5.1)
result = read([true,false,true,true,false], 30)
check(result.history.contains(ids[1]) && result.history.contains(ids[3]) && result.current == ids[4], "thirty-second B does not block later results")
for limit in 0...3 {
    queue = .init(); result = read([true,true,true,true,true], limit: limit)
    check(result.history.count == limit && result.current == ids[4], "steady history count equals existing capacity")
    check(result.history.compactMap { ids.firstIndex(of: $0) } == result.history.compactMap { ids.firstIndex(of: $0) }.sorted(), "steady source order")
    for pending in [false,true] {
        for flags in [[true,false,false,true,true], [true,true,true,true,true]] {
            queue = .init(); let source = read(flags, limit: limit, pending: pending, sourceOnly: true)
            let expected = CaptionReadingPolicy.retainedIndices(readable: flags.map { _ in false }, recentLimit: pending ? limit : limit + 1).map { ids[$0] }
            check(source.ids == expected && source.showsPending == pending, "source-only exactly matches BASE")
        }
    }
}
queue = .init(); result = read([true,false], pending: true)
check(result.current == ids[1] && !result.showsPending, "pending cannot add another current")
queue = .init(); result = read([true,true], pending: true)
check(result.current == nil && result.showsPending, "ASR occupies current after finalized requests")
queue = .init()
let exhaustedItems = [CaptionReadingPolicy.DesktopItem(id: ids[0], finalized: true, translated: false), .init(id: ids[1], finalized: true, translated: true), .init(id: ids[2], finalized: false, translated: false)]
result = readLayout(exhaustedItems, limit: 1, pending: false, sourceOnly: false, now: 0, queue: &queue)
check(result.history == [ids[1]] && result.current == ids[2], "retry-exhausted source is finalized and evictable")
struct Baseline: Decodable {
    struct Case: Decodable { let size: Int; let translation: Bool; let source: Bool; let banner: Bool; let paused: Bool; let height: Double; let expected: Int }
    let cases: [Case]
    let maximumHistory: Int
}
let baseline = try JSONDecoder().decode(Baseline.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
check(CaptionHierarchy.maximumHistory == baseline.maximumHistory, "maximumHistory remains three")
for c in baseline.cases {
    check(CaptionHierarchy.historyLimit(userSize: Double(c.size), showTranslation: c.translation, showSource: c.source, banner: c.banner || c.paused, height: c.height) == c.expected, "recorded BASE island capacity")
}
print("PASS capacity comparison: \(baseline.cases.count) recorded BASE inputs")
var seed: UInt64 = 36
func random() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1; return seed >> 32 }
for limit in 1...3 {
    queue = .init(); var done: [Bool] = []; var deadlines: [Int:Int] = [:]; var seen: Set<UUID> = []
    for tick in 0...1200 {
        for (index, deadline) in deadlines where tick >= deadline { done[index] = true; deadlines.removeValue(forKey: index) }
        if tick % 15 == 0 && done.count < 60 && deadlines.count < 3 {
            let index = done.count; done.append(false)
            let delay = index == 3 ? 300 : [18,36].contains(index) ? 65 : 3 + Int(random() % 25)
            deadlines[index] = tick + delay + (index % 7 == 0 ? 15 : 0)
        }
        let previous = queue.current; let since = queue.currentSince
        let pinned = done.indices.filter { queue.advanced.contains(ids[$0]) && !done[$0] }.count
        result = read(done, Double(tick)/10, limit: limit)
        let unfinished = Set(done.indices.filter { !done[$0] }.map { ids[$0] })
        check(seen.intersection(unfinished).isSubset(of: Set(result.ids)), "simulation keeps every displayed unfinished sentence")
        check(Set(result.ids).count == result.ids.count && !result.history.contains(result.current ?? UUID()), "simulation sole current")
        check(result.history.compactMap { ids.firstIndex(of: $0) } == result.history.compactMap { ids.firstIndex(of: $0) }.sorted(), "simulation source order")
        check(result.history.count <= limit, "simulation existing capacity")
        if let id = previous, let index = ids.firstIndex(of: id), index < done.count,
           !done[index], Double(tick)/10 - since > 5, done.dropFirst(index + 1).contains(true), pinned < limit {
            check(result.current != id && result.history.contains(id), "simulation timeout promotes on first eligible tick")
        }
        seen.formUnion(result.ids)
    }
    check(done.count == 60, "simulation runs sixty segments over two minutes")
}
if failures > 0 { exit(1) }
print("PASS KK-036 island source order, retention, timeout, compact, source-only, two-minute simulation")
