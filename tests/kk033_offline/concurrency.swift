import Foundation

// External services only. Request admission, retry dispatch, onDone and consumer
// below come verbatim from CaptionState; no parallel implementation of them.
enum TranslateFailure: Sendable { case network(String), server(Int), cancelled, unauthorized }
enum TranslationText {
    static func acknowledgement(_ text: String) -> String? { nil }
    static func frozenPreviousSource(immediatePredecessorIsMarker: Bool, lastNonMarker: String?) -> String { lastNonMarker ?? "" }
    static func repeatedAcknowledgement(_ text: String, after: String, interval: Double) -> Bool { false }
}
struct TranslationTiming: Sendable {
    var attemptNumber: Int?, sessionID: Int?, chunkID: Int?, requestID: Int?
    var sampleKind = 0
    var subrequestIndex = 0, subrequestCount = 0, networkRetry = 0
    var connectionReused: Bool?, transactionCount: Int?, requestToHeadersMs: Int?
    var headersToFirstMs: Int?, headersToEndMs: Int?, networkRequestToEndMs: Int?, worker: Int?
    static func sample(pending: Double?, chunk: Double, request: Double, first: Double?, end: Double, succeeded: Bool) -> Self { .init() }
}
struct TranslationNetworkTiming: Sendable {
    var subrequestIndex = 0, subrequestCount = 0, retry = 0
    var connectionReused: Bool?, transactionCount: Int?, requestToHeadersMs: Int?
    var headersToFirstMs: Int?, headersToEndMs: Int?, requestToEndMs: Int?, worker: Int?
}
struct TranslationTimingMetadata { var row = TranslationTiming() }
@MainActor final class TranslationTimingRecorder {
    static let shared = TranslationTimingRecorder()
    let enabled = false
    enum Event { case reused }
    func nextID() -> Int { 0 }
    func event(_ event: Event, metadata: TranslationTiming?) {}
    func beginAttempt(_ attempt: UUID, metadata: TranslationTiming) {}
    func first(_ attempt: UUID, at: Double) {}
    func finish(_ attempt: UUID, pending: Double?, chunk: Double, request: Double, end: Double, succeeded: Bool, metadata: TranslationTiming?) {}
    func record(_ row: TranslationTiming) {}
}
@MainActor final class LocalTranslator {
    static let shared = LocalTranslator()
    let unavailable = true
    func translate(_ text: String) async -> String? { nil }
}
// PRODUCTION TYPES

@MainActor final class FakeTranslator {
    var started: [UUID] = [], networkDone: [UUID] = []
    var releaseFirst = false
    func translate(id: UUID, chunk: String, previous: String,
                   timing: (@Sendable (TranslationNetworkTiming) -> Void)?,
                   onLive: @escaping @Sendable (String) -> Void,
                   onDone: @escaping @Sendable (String?) -> Void) {
        started.append(id)
        print("request \(chunk)")
        Task { @MainActor in
            // Hold the slow response until the assertions about fast responses
            // finish. The gate prevents loaded CI machines reversing timing.
            try? await Task.sleep(nanoseconds: chunk == "1" ? 1_000_000_000 : 50_000_000)
            while chunk == "1" && !releaseFirst {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            networkDone.append(id)
            print("network done \(chunk)")
            onDone("translated \(chunk)")
        }
    }
}

@MainActor final class ConcurrencyHost {
    var chunks = (1...4).map { CaptionChunk(en: String($0)) }
    var inflight = 0, sessionGen = 1, lastFinalMs = 0
    var activeTranslationAttempts: [UUID: UUID] = [:]
    var translationPaused = false, captionsToExtension = false, localForVideo = false
    var running = true, finishingCaptions = false, starting = false, switchingMeetingLanguage = false
    var rateLimitedUntil: Date?, status = "running"
    var translationRetryQueue = TranslationRetryQueue()
    let timingRecorder = TranslationTimingRecorder()
    let translator = FakeTranslator()
    var translationCallbackContinuation: AsyncStream<TranslationCallbackEvent>.Continuation?
    var consumerTask: Task<Void, Never>?
    var handled: [UUID] = []
    func start() {
        let channel = AsyncStream<TranslationCallbackEvent>.makeStream()
        translationCallbackContinuation = channel.continuation
        consumerTask = Task { await consumeTranslationCallbacks(channel.stream, generation: sessionGen) }
    }
    func submit(_ index: Int) { requestTranslation(for: chunks[index].id, text: chunks[index].en) }
    func pushChunk(_ chunk: CaptionChunk, index: Int) {
        handled.append(chunk.id)
        print("handled \(chunk.en)")
    }
    func translationSucceeded() {}
    func updateRunningStatus() {}
    func queueTranslatedChunksForMeetingSummary() {}
    func scheduleTranscriptSave() {}
    func handleFailure(_ failure: TranslateFailure, chunk: UUID?) { fatalError("unexpected failure") }
    // PRODUCTION METHODS
}

@main struct ConcurrencyRegression {
    @MainActor static func check(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL concurrency: \(message)"); exit(1) }
    }
    @MainActor static func waitFor(_ predicate: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !predicate() && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return predicate()
    }
    @MainActor static func main() async {
        let host = ConcurrencyHost()
        host.start()
        let ids = host.chunks.map(\.id)
        host.submit(0); host.submit(1); host.submit(2)
        check(host.translator.started == Array(ids.prefix(3)), "requests 2/3 must issue before slow request 1 completes (requests serialized)")
        check(!host.translator.networkDone.contains(ids[0]), "slow request must still be pending")
        check(host.inflight == 3, "three requests occupy all slots")
        host.submit(3)
        check(!host.translator.started.contains(ids[3]), "request 4 must not issue when inflight is full")
        check(host.translationRetryQueue.pending == [ids[3]], "request 4 must enter the real retry queue")
        let fastFinished = await waitFor { ids[1...2].allSatisfy { host.handled.contains($0) } }
        check(fastFinished, "completion handling for 2/3 must not wait for slow request 1")
        check(!host.translator.networkDone.contains(ids[0]), "2/3 handled before network completion 1")
        check(host.translator.started.contains(ids[3]), "request 4 must issue after a completion frees a slot")
        check(host.translationRetryQueue.isEmpty, "queued request must be consumed")
        check(host.chunks[3].translationAttempts == 1, "queued request dispatched exactly once")
        host.translator.releaseFirst = true
        let allFinished = await waitFor { host.handled.count == 4 }
        check(allFinished, "all four real completion bodies must finish")
        check(host.inflight == 0 && host.activeTranslationAttempts.isEmpty, "all slots and attempts released")
        check(host.translator.started == ids, "no duplicate or missing requests")
        host.translationCallbackContinuation?.finish()
        await host.consumerTask?.value
        print("PASS concurrency: overlapping requests, 3-slot admission, real queued refill, fast completions bypass slow request")
    }
}
