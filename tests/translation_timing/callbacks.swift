import Foundation

struct Metadata { var row = 0 }
struct Chunk {
    let id = UUID()
    var zh = "old"
    var isDraft = false
    var translationComplete = false
    var timingPendingAt: TimeInterval?
    var timingCreatedAt: TimeInterval = 0
    var timingMetadata: Metadata?
}
@MainActor final class Recorder {
    var readCurrent: () -> String = { "<missing>" }
    var observedAtFirst: [String] = []
    var events: [String] = []
    var firstByAttempt: [UUID: TimeInterval] = [:]
    var finishedFirst: TimeInterval?
    func first(_ attempt: UUID, at time: TimeInterval) {
        observedAtFirst.append(readCurrent()); events.append("first")
        if firstByAttempt[attempt] == nil { firstByAttempt[attempt] = time }
    }
    func finish(_ attempt: UUID, pending: TimeInterval?, chunk: TimeInterval,
                request: TimeInterval, end: TimeInterval, succeeded: Bool, metadata: Int? = nil) {
        events.append("finish"); finishedFirst = firstByAttempt.removeValue(forKey: attempt)
    }
}
@MainActor final class Fixture {
    var sessionGen = 1
    var chunks = [Chunk()]
    var activeTranslationAttempts: [UUID: UUID] = [:]
    var inflight = 1
    let timingRecorder = Recorder()
    init() { timingRecorder.readCurrent = { [weak self] in self?.chunks.first?.zh ?? "<missing>" } }
    func delta(_ live: String, gen: Int, id: UUID, attempt: UUID) async {
        let callback: (String) -> Task<Void, Never> = { [weak self] live in
            Task { @MainActor in
// DELTA
            }
        }
        await callback(live).value
    }
    func done(_ final: String?, gen: Int, id: UUID, attempt: UUID) async {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let callback: (String?) -> Task<Void, Never> = { [weak self] final in
            Task { @MainActor in
// DONE
            }
        }
        await callback(final).value
    }
}
@main struct Checks {
    @MainActor static func fixture() -> (Fixture, UUID, UUID) {
        let state = Fixture(), attempt = UUID()
        state.activeTranslationAttempts[state.chunks[0].id] = attempt
        return (state, state.chunks[0].id, attempt)
    }
    @MainActor static func main() async {
        do {
            let (s, id, attempt) = fixture()
            await s.delta("delta", gen: 1, id: id, attempt: attempt)
            precondition(s.timingRecorder.observedAtFirst == ["delta"])
            let first = s.timingRecorder.firstByAttempt[attempt]
            await s.delta("later", gen: 1, id: id, attempt: attempt)
            precondition(s.timingRecorder.firstByAttempt[attempt] == first)
            await s.done("final", gen: 1, id: id, attempt: attempt)
            precondition(s.timingRecorder.finishedFirst == first)
            precondition(s.timingRecorder.observedAtFirst.last == "final")
            precondition(s.activeTranslationAttempts.isEmpty && s.inflight == 0)
        }
        do {
            let (s, id, attempt) = fixture()
            await s.done("final-only", gen: 1, id: id, attempt: attempt)
            precondition(s.chunks[0].zh == "final-only")
            precondition(s.timingRecorder.observedAtFirst == ["final-only"])
            precondition(s.timingRecorder.events == ["first", "finish"] && s.timingRecorder.finishedFirst != nil)
            await s.done("duplicate", gen: 1, id: id, attempt: attempt)
            precondition(s.chunks[0].zh == "final-only" && s.timingRecorder.events == ["first", "finish"])
        }
        for final in [nil, " \n"] as [String?] {
            let (s, id, attempt) = fixture()
            await s.delta(" \n", gen: 1, id: id, attempt: attempt)
            precondition(s.timingRecorder.events.isEmpty)
            await s.done(final, gen: 1, id: id, attempt: attempt)
            precondition(s.timingRecorder.events == ["finish"] && s.timingRecorder.finishedFirst == nil)
        }
        for draft in [true, false] {
            let (s, id, attempt) = fixture()
            s.chunks[0].isDraft = draft; s.chunks[0].translationComplete = !draft
            await s.delta("ignored", gen: 1, id: id, attempt: attempt)
            precondition(s.chunks[0].zh == "old" && s.timingRecorder.events.isEmpty)
        }
        for staleGeneration in [true, false] {
            let (s, id, attempt) = fixture()
            if staleGeneration { s.sessionGen = 2 } else { s.activeTranslationAttempts[id] = UUID() }
            let original = s.activeTranslationAttempts
            await s.delta("stale", gen: 1, id: id, attempt: attempt)
            await s.done("stale-final", gen: 1, id: id, attempt: attempt)
            precondition(s.chunks[0].zh == "old" && s.timingRecorder.events.isEmpty)
            precondition(s.activeTranslationAttempts == original && s.inflight == 1)
        }
        do {
            let (s, id, attempt) = fixture(); s.chunks = []
            await s.delta("missing", gen: 1, id: id, attempt: attempt)
            await s.done("missing-final", gen: 1, id: id, attempt: attempt)
            precondition(s.timingRecorder.events.isEmpty && s.chunks.isEmpty)
        }
        print("PASS: actual callbacks, ownership, ignored deltas, final-only and assignment-before-first")
    }
}
