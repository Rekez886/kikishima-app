import Foundation

private enum FakeFailure: Error {
    case upstream
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

private actor MemorySummaryStore: MeetingSummaryPersisting {
    private(set) var documents: [MeetingSummaryDocument] = []
    private var holdNextSave = false
    private var heldSave: CheckedContinuation<Void, Never>?
    func holdNext() { holdNextSave = true }
    func isSaveHeld() -> Bool { heldSave != nil }
    func releaseSave() { heldSave?.resume(); heldSave = nil }

    func save(_ document: MeetingSummaryDocument, beside transcriptURL: URL) async throws {
        documents.append(document)
        if holdNextSave {
            holdNextSave = false
            await withCheckedContinuation { heldSave = $0 }
        }
    }

    func latest() -> MeetingSummaryDocument? { documents.last }
}

private actor FakeSummaryClient: MeetingSummaryServicing {
    private struct Pending {
        let request: SummarizeRequest
        let continuation: CheckedContinuation<SummarizeResponse, Error>
    }

    private var requests: [SummarizeRequest] = []
    private var pending: [Pending] = []
    private var manual = false
    private var failuresRemaining = 0
    private var active = 0
    private(set) var maximumActive = 0

    func setManual(_ value: Bool) { manual = value }
    func failNext(_ count: Int = 1) { failuresRemaining = count }

    func summarize(_ request: SummarizeRequest) async throws -> SummarizeResponse {
        requests.append(request)
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw FakeFailure.upstream
        }
        if manual {
            return try await withCheckedThrowingContinuation { continuation in
                pending.append(Pending(request: request, continuation: continuation))
            }
        }
        return Self.makeResponse(for: request)
    }

    func resolveFirst() {
        let item = pending.removeFirst()
        item.continuation.resume(returning: Self.makeResponse(for: item.request))
    }

    func requestCount() -> Int { requests.count }
    func request(at index: Int) -> SummarizeRequest { requests[index] }

    private static func makeResponse(for request: SummarizeRequest) -> SummarizeResponse {
        let first = request.segments[0]
        let last = request.segments[request.segments.count - 1]
        let overview = SummaryBlock(
            id: "overview-\(last.id)",
            text: "Summary through \(last.id)",
            sourceRefs: [SummarySourceRef(segmentID: first.id, startSeconds: first.startSeconds)]
        )
        return SummarizeResponse(
            content: MeetingSummaryContent(
                overview: [overview],
                currentState: [],
                decisions: [],
                actionItems: [],
                personalItems: [],
                openQuestions: []
            ),
            processedThrough: last.id,
            schemaVersion: request.schemaVersion,
            promptVersion: request.promptVersion
        )
    }
}

private func waitForRequests(_ count: Int, client: FakeSummaryClient, line: UInt = #line) async {
    for _ in 0..<20_000 {
        if await client.requestCount() >= count { return }
        await Task.yield()
    }
    preconditionFailure("Timed out waiting for \(count) requests at line \(line)")
}

private func segment(_ id: String, text: String, second: Int = 0) -> SummarySourceSegment {
    SummarySourceSegment(id: id, startSeconds: second, text: text)
}

private func makeCoordinator(
    client: FakeSummaryClient,
    store: MemorySummaryStore,
    generation: Int = 1,
    startedAt: Date = Date(timeIntervalSince1970: 0)
) async -> MeetingSummaryCoordinator {
    let coordinator = MeetingSummaryCoordinator(client: client, store: store)
    await coordinator.begin(
        generation: generation,
        recordID: "record-\(generation)",
        transcriptURL: URL(fileURLWithPath: "/tmp/meeting-\(generation).md"),
        startedAt: startedAt,
        targetLanguage: "English",
        aliases: ["Ken"]
    )
    return coordinator
}

private func testCostSessionOwnership() async {
    let client = FakeSummaryClient(), store = MemorySummaryStore()
    let coordinator = MeetingSummaryCoordinator(client: client, store: store)
    let firstID = UUID().uuidString, secondID = UUID().uuidString
    for (generation, recordID) in [(1, firstID), (2, secondID)] {
        await coordinator.begin(generation: generation, recordID: recordID,
            transcriptURL: URL(fileURLWithPath: "/tmp/cost-fixture-\(generation).md"),
            startedAt: Date(timeIntervalSince1970: 0), targetLanguage: "English", aliases: [])
        await client.failNext()
        await coordinator.accept(segment("cost-\(generation)", text: String(repeating: "a", count: 600)), generation: generation)
        await coordinator.tick(now: Date(timeIntervalSince1970: 180), generation: generation)
        await coordinator.tick(now: Date(timeIntervalSince1970: 181), generation: generation)
        let initial = await client.request(at: (generation - 1) * 2)
        let retry = await client.request(at: (generation - 1) * 2 + 1)
        precondition(initial.costSessionID == recordID.lowercased())
        precondition(retry.costSessionID == initial.costSessionID)
        precondition(initial.requestID == retry.requestID)
    }
}

private func testTriggerThresholds() async {
    let client = FakeSummaryClient()
    let store = MemorySummaryStore()
    let coordinator = await makeCoordinator(client: client, store: store)
    await coordinator.accept(segment("a", text: String(repeating: "a", count: 600)), generation: 1)
    await coordinator.tick(now: Date(timeIntervalSince1970: 179), generation: 1)
    var requestCount = await client.requestCount()
    precondition(requestCount == 0, "No summary before three minutes")
    await coordinator.tick(now: Date(timeIntervalSince1970: 180), generation: 1)
    requestCount = await client.requestCount()
    precondition(requestCount == 1, "Initial summary starts at three minutes with enough text")

    await coordinator.accept(segment("b", text: "follow-up", second: 200), generation: 1)
    await coordinator.tick(now: Date(timeIntervalSince1970: 479), generation: 1)
    requestCount = await client.requestCount()
    precondition(requestCount == 1)
    await coordinator.tick(now: Date(timeIntervalSince1970: 480), generation: 1)
    requestCount = await client.requestCount()
    precondition(requestCount == 2, "Five elapsed minutes trigger the next summary")

    await coordinator.accept(segment("c", text: String(repeating: "c", count: 6_100), second: 481), generation: 1)
    await coordinator.tick(now: Date(timeIntervalSince1970: 481), generation: 1)
    requestCount = await client.requestCount()
    precondition(requestCount == 3, "About 6,000 new characters trigger immediately")
}

private func testByteAwareBatching() async throws {
    let client = FakeSummaryClient()
    let store = MemorySummaryStore()
    let coordinator = await makeCoordinator(client: client, store: store)
    await coordinator.accept(segment("huge", text: String(repeating: "界", count: 30_000)), generation: 1)
    await coordinator.tick(now: Date(timeIntervalSince1970: 180), generation: 1)
    let sent = await client.request(at: 0)
    let requestBytes = try JSONEncoder().encode(sent).count
    let segmentBytes = try JSONEncoder().encode(sent.segments).count
    precondition(requestBytes <= 60 * 1_024)
    precondition(segmentBytes <= 32 * 1_024)
    precondition(sent.segments.allSatisfy { $0.id.hasPrefix("huge:") }, "Oversized segments use deterministic child IDs")
    let snapshot = await coordinator.snapshot()
    precondition(snapshot.pendingCount > 0, "Unsent split parts remain pending")
}

private func testInFlightFinalizationAndStaleGeneration() async {
    let client = FakeSummaryClient()
    await client.setManual(true)
    let store = MemorySummaryStore()
    let coordinator = await makeCoordinator(client: client, store: store, generation: 7)
    await coordinator.accept(segment("a", text: String(repeating: "a", count: 600)), generation: 7)
    let tick = Task { await coordinator.tick(now: Date(timeIntervalSince1970: 180), generation: 7) }
    await waitForRequests(1, client: client)
    await coordinator.accept(segment("b", text: "arrived while A was running", second: 190), generation: 7)
    let final = Task { await coordinator.finalize(remaining: [], transcriptURL: URL(fileURLWithPath: "/tmp/meeting-7.md"), generation: 7) }
    for _ in 0..<100 { await Task.yield() }
    let requestCountBeforeResolving = await client.requestCount()
    precondition(requestCountBeforeResolving == 1, "Finalization waits for the stage request")
    await client.resolveFirst()
    await waitForRequests(2, client: client)
    let finalRequest = await client.request(at: 1)
    precondition(finalRequest.final)
    precondition(finalRequest.segments.map(\.id) == ["b"], "Only the segment arriving in-flight is sent in final merge")
    await client.resolveFirst()
    await tick.value
    await final.value
    let maximumActive = await client.maximumActive
    let finishedSnapshot = await coordinator.snapshot()
    precondition(maximumActive == 1, "Only one request may exist at a time")
    precondition(finishedSnapshot.state == .finished(generation: 7))

    let staleClient = FakeSummaryClient()
    await staleClient.setManual(true)
    let staleStore = MemorySummaryStore()
    let staleCoordinator = await makeCoordinator(client: staleClient, store: staleStore, generation: 7)
    await staleCoordinator.accept(segment("old", text: String(repeating: "o", count: 600)), generation: 7)
    let staleTick = Task { await staleCoordinator.tick(now: Date(timeIntervalSince1970: 180), generation: 7) }
    await waitForRequests(1, client: staleClient)
    await staleCoordinator.begin(
        generation: 8,
        recordID: "record-8",
        transcriptURL: URL(fileURLWithPath: "/tmp/meeting-8.md"),
        startedAt: Date(timeIntervalSince1970: 200),
        targetLanguage: "English",
        aliases: []
    )
    await staleClient.resolveFirst()
    await staleTick.value
    let snapshot = await staleCoordinator.snapshot()
    precondition(snapshot.state == .active(generation: 8))
    precondition(snapshot.document?.processedThrough == nil, "Generation 7 response must not touch generation 8")
}

private func testFailureRetryKeepsCursorAndMergesOnce() async {
    let client = FakeSummaryClient()
    await client.failNext()
    let store = MemorySummaryStore()
    let coordinator = await makeCoordinator(client: client, store: store)
    await coordinator.accept(segment("a", text: String(repeating: "a", count: 600)), generation: 1)
    await coordinator.tick(now: Date(timeIntervalSince1970: 180), generation: 1)
    var snapshot = await coordinator.snapshot()
    let failedStoredDocument = await store.latest()
    precondition(snapshot.document?.processedThrough == nil)
    precondition(snapshot.pendingCount == 1)
    precondition(failedStoredDocument?.sourceIndex["a"] != nil, "Failed pending segments remain available for a later retry")
    await coordinator.tick(now: Date(timeIntervalSince1970: 181), generation: 1)
    snapshot = await coordinator.snapshot()
    precondition(snapshot.document?.processedThrough == "a")
    let firstID = await client.request(at: 0).requestID
    let retryID = await client.request(at: 1).requestID
    precondition(firstID == retryID, "A failed request retries with the same idempotency ID")

    let finalClient = FakeSummaryClient()
    await finalClient.failNext()
    let finalStore = MemorySummaryStore()
    let finalCoordinator = await makeCoordinator(client: finalClient, store: finalStore, generation: 2)
    await finalCoordinator.accept(segment("final", text: "final item"), generation: 2)
    await finalCoordinator.finalize(remaining: [], transcriptURL: URL(fileURLWithPath: "/tmp/meeting-2.md"), generation: 2)
    var finalSnapshot = await finalCoordinator.snapshot()
    precondition(finalSnapshot.state.isFailed)
    await finalCoordinator.retryFinal(transcriptURL: URL(fileURLWithPath: "/tmp/meeting-2.md"), generation: 2)
    finalSnapshot = await finalCoordinator.snapshot()
    precondition(finalSnapshot.state == .finished(generation: 2))
    await finalCoordinator.retryFinal(transcriptURL: URL(fileURLWithPath: "/tmp/meeting-2.md"), generation: 2)
    let finalRequestCount = await finalClient.requestCount()
    let finalStoredDocument = await finalStore.latest()
    precondition(finalRequestCount == 2, "A finished final response is never merged twice")
    precondition(finalStoredDocument?.sourceIndex.count == 1)
}

private func testLifecycleBufferSendsTranslationOnceAndFallsBackAtStop() {
    let startedAt = Date(timeIntervalSince1970: 100)
    var buffer = MeetingSummaryLifecycleBuffer(startedAt: startedAt)
    let translated = buffer.acceptTranslated(
        id: "a",
        createdAt: Date(timeIntervalSince1970: 105),
        text: "Translated A"
    )
    precondition(translated?.text == "Translated A")
    precondition(buffer.acceptTranslated(
        id: "a",
        createdAt: Date(timeIntervalSince1970: 105),
        text: "Translated A again"
    ) == nil, "A finalized translation is emitted once")

    let remaining = buffer.finalize([
        MeetingSummaryCandidate(id: "a", createdAt: Date(timeIntervalSince1970: 105), preferredText: "Translated A", fallbackText: "Source A"),
        MeetingSummaryCandidate(id: "b", createdAt: Date(timeIntervalSince1970: 111), preferredText: nil, fallbackText: "Source B"),
    ])
    precondition(remaining.map(\.id) == ["b"])
    precondition(remaining.first?.text == "Source B", "Untranslated final chunks fall back to source text")
    precondition(remaining.first?.startSeconds == 11)
}

private func testLifecycleBufferRetractsWithdrawnSpeech() {
    let startedAt = Date(timeIntervalSince1970: 100)
    var buffer = MeetingSummaryLifecycleBuffer(startedAt: startedAt)
    _ = buffer.acceptTranslated(id: "old", createdAt: Date(timeIntervalSince1970: 105), text: "We can")
    buffer.retract(["old"])
    let again = buffer.acceptTranslated(id: "old", createdAt: Date(timeIntervalSince1970: 105), text: "We cannot")
    precondition(again?.text == "We cannot", "A withdrawn source id can be summarized again")
}

private func testCoordinatorRetractsPendingSegments() async {
    let client = FakeSummaryClient()
    let store = MemorySummaryStore()
    let coordinator = await makeCoordinator(client: client, store: store)
    await coordinator.accept(segment("old", text: "We can"), generation: 1)
    await coordinator.retract(["old"], generation: 1)
    var snapshot = await coordinator.snapshot()
    precondition(snapshot.pendingCount == 0, "Withdrawn speech leaves the summary queue")
    await coordinator.accept(segment("new", text: "We cannot"), generation: 1)
    snapshot = await coordinator.snapshot()
    precondition(snapshot.pendingCount == 1)
}

private func testCoordinatorRetractsGeneratedOverview() async {
    let client = FakeSummaryClient()
    let store = MemorySummaryStore()
    let coordinator = await makeCoordinator(client: client, store: store)
    await coordinator.accept(segment("old", text: String(repeating: "a", count: 600)), generation: 1)
    await coordinator.tick(now: Date(timeIntervalSince1970: 180), generation: 1)
    await waitForRequests(1, client: client)
    for _ in 0..<20_000 {
        if await coordinator.snapshot().document?.content.overview.isEmpty == false { break }
        await Task.yield()
    }
    var snapshot = await coordinator.snapshot()
    precondition(snapshot.document?.content.overview.isEmpty == false, "Generated overview exists before retract")
    await coordinator.retract(["old"], generation: 1)
    snapshot = await coordinator.snapshot()
    let refs = snapshot.document?.content.overview.flatMap(\.sourceRefs).map(\.segmentID) ?? []
    precondition(!refs.contains("old"), "Retracted speech leaves generated overview")
    precondition(snapshot.document?.sourceIndex["old"] == nil)
}

private func testCoordinatorRetractsInFlightRequest() async {
    let client = FakeSummaryClient()
    await client.setManual(true)
    let store = MemorySummaryStore()
    let coordinator = await makeCoordinator(client: client, store: store)
    await coordinator.accept(segment("old", text: String(repeating: "a", count: 600)), generation: 1)
    let tick = Task { await coordinator.tick(now: Date(timeIntervalSince1970: 180), generation: 1) }
    await waitForRequests(1, client: client)
    await coordinator.retract(["old"], generation: 1)
    await client.resolveFirst()
    await tick.value
    let snapshot = await coordinator.snapshot()
    let refs = snapshot.document?.content.overview.flatMap(\.sourceRefs).map(\.segmentID) ?? []
    precondition(!refs.contains("old"), "In-flight summarize must not restore retracted speech")
    precondition(snapshot.document?.sourceIndex["old"] == nil)
    precondition(snapshot.pendingCount == 0)
    let stored = await store.latest()
    precondition(stored?.sourceIndex["old"] == nil, "Retract persists stripped sidecar")
}

private func testBeginDoesNotDropPreviousFinalize() async {
    let client = FakeSummaryClient()
    await client.setManual(true)
    let store = MemorySummaryStore()
    let coordinator = await makeCoordinator(client: client, store: store, generation: 7)
    await coordinator.accept(segment("keep", text: String(repeating: "k", count: 600)), generation: 7)
    let tick = Task { await coordinator.tick(now: Date(timeIntervalSince1970: 180), generation: 7) }
    await waitForRequests(1, client: client)
    await coordinator.begin(
        generation: 8,
        recordID: "record-8",
        transcriptURL: URL(fileURLWithPath: "/tmp/meeting-8.md"),
        startedAt: Date(timeIntervalSince1970: 200),
        targetLanguage: "English",
        aliases: []
    )
    await client.resolveFirst()
    await tick.value
    let savedIDs = await store.documents.map(\.recordID)
    precondition(savedIDs.contains("record-7"), "Previous meeting finalize still writes its sidecar")
    let snapshot = await coordinator.snapshot()
    precondition(snapshot.state == .active(generation: 8))
    precondition(snapshot.document?.recordID == "record-8")
}

private func testRetractThenBeginNextDoesNotRestoreWithdrawnSpeech() async {
    let client = FakeSummaryClient()
    await client.setManual(true)
    let store = MemorySummaryStore()
    let coordinator = await makeCoordinator(client: client, store: store, generation: 7)
    await coordinator.accept(segment("old", text: String(repeating: "a", count: 600)), generation: 7)
    let tick = Task { await coordinator.tick(now: Date(timeIntervalSince1970: 180), generation: 7) }
    await waitForRequests(1, client: client)
    await coordinator.retract(["old"], generation: 7)
    await coordinator.begin(
        generation: 8,
        recordID: "record-8",
        transcriptURL: URL(fileURLWithPath: "/tmp/meeting-8.md"),
        startedAt: Date(timeIntervalSince1970: 200),
        targetLanguage: "English",
        aliases: []
    )
    await client.resolveFirst()
    await tick.value
    let saved = await store.documents.last(where: { $0.recordID == "record-7" })
    let refs = saved?.content.overview.flatMap(\.sourceRefs).map(\.segmentID) ?? []
    precondition(!refs.contains("old"), "Starting the next meeting must not restore retracted speech")
    precondition(saved?.sourceIndex["old"] == nil)
}

private func testFinalizeAfterBeginStillWritesRemaining() async {
    let client = FakeSummaryClient()
    await client.setManual(true)
    let store = MemorySummaryStore()
    let changes = ChangeCounter()
    let coordinator = MeetingSummaryCoordinator(client: client, store: store, onChange: { _ in changes.increment() })
    await coordinator.begin(generation: 7, recordID: "record-7",
        transcriptURL: URL(fileURLWithPath: "/tmp/meeting-7.md"), startedAt: Date(timeIntervalSince1970: 0),
        targetLanguage: "English", aliases: [])
    await coordinator.accept(segment("keep", text: String(repeating: "k", count: 600)), generation: 7)
    let tick = Task { await coordinator.tick(now: Date(timeIntervalSince1970: 180), generation: 7) }
    await waitForRequests(1, client: client)
    await coordinator.begin(
        generation: 8,
        recordID: "record-8",
        transcriptURL: URL(fileURLWithPath: "/tmp/meeting-8.md"),
        startedAt: Date(timeIntervalSince1970: 200),
        targetLanguage: "English",
        aliases: []
    )
    // Freeze the older response AFTER it snapshots detached work. Register the
    // tail during that save, then release it. No scheduler race is required.
    await store.holdNext()
    await client.resolveFirst()
    for _ in 0..<20_000 {
        if await store.isSaveHeld() { break }
        await Task.yield()
    }
    let saveHeld = await store.isSaveHeld()
    precondition(saveHeld, "Old response must be paused inside persistence")
    let beforeFinalize = changes.count()
    let final = Task {
        await coordinator.finalize(
            remaining: [segment("tail", text: String(repeating: "t", count: 600), second: 190)],
            transcriptURL: URL(fileURLWithPath: "/tmp/meeting-7.md"),
            generation: 7
        )
    }
    for _ in 0..<20_000 {
        if changes.count() > beforeFinalize { break }
        await Task.yield()
    }
    precondition(changes.count() > beforeFinalize, "Detached finalization must register its tail before releasing save")
    await store.releaseSave()
    await waitForRequests(2, client: client)
    let tailRequest = await client.request(at: 1)
    precondition(tailRequest.final, "Previous meeting still sends a final batch after the next meeting begins")
    precondition(tailRequest.segments.map(\.id).contains("tail"), "Remaining speech is not dropped when the next meeting begins")
    await client.resolveFirst()
    await tick.value
    await final.value
    let saved = await store.documents.last(where: { $0.recordID == "record-7" })
    precondition(saved?.sourceIndex["tail"] != nil, "Previous meeting sidecar keeps remaining speech")
    let snapshot = await coordinator.snapshot()
    precondition(snapshot.state == .active(generation: 8))
    precondition(snapshot.document?.recordID == "record-8")
}

private func testStaleBeginDoesNotStealNewerSession() async {
    let client = FakeSummaryClient()
    let store = MemorySummaryStore()
    let coordinator = await makeCoordinator(client: client, store: store, generation: 8)
    await coordinator.accept(segment("live", text: "New meeting speech"), generation: 8)
    await coordinator.begin(
        generation: 7,
        recordID: "record-7",
        transcriptURL: URL(fileURLWithPath: "/tmp/meeting-7.md"),
        startedAt: Date(timeIntervalSince1970: 0),
        targetLanguage: "English",
        aliases: []
    )
    let snapshot = await coordinator.snapshot()
    precondition(snapshot.state == .active(generation: 8), "A late previous-meeting begin must not replace the live session")
    precondition(snapshot.document?.recordID == "record-8")
    precondition(snapshot.pendingCount == 1)
    await coordinator.finalize(
        remaining: [segment("late", text: "Previous meeting tail")],
        transcriptURL: URL(fileURLWithPath: "/tmp/meeting-7.md"),
        generation: 7
    )
    let saved = await store.documents.last(where: { $0.recordID == "record-7" })
    precondition(saved?.sourceIndex["late"] != nil, "Late previous-meeting finalize still writes its sidecar")
    let live = await coordinator.snapshot()
    precondition(live.state == .active(generation: 8))
    precondition(live.document?.recordID == "record-8")
}

private func testRetrySameRecordWhileDetachedDoesNotStartSecondJob() async {
    let client = FakeSummaryClient()
    await client.setManual(true)
    let store = MemorySummaryStore()
    let coordinator = await makeCoordinator(client: client, store: store, generation: 7)
    await coordinator.accept(segment("keep", text: String(repeating: "k", count: 600)), generation: 7)
    let tick = Task { await coordinator.tick(now: Date(timeIntervalSince1970: 180), generation: 7) }
    await waitForRequests(1, client: client)
    await coordinator.begin(
        generation: 8,
        recordID: "record-8",
        transcriptURL: URL(fileURLWithPath: "/tmp/meeting-8.md"),
        startedAt: Date(timeIntervalSince1970: 200),
        targetLanguage: "English",
        aliases: []
    )
    var snapshot = await coordinator.snapshot()
    precondition(snapshot.workingRecordIDs.contains("record-7"), "Detached previous meeting is still working")
    let busy = await coordinator.isWorking(recordID: "record-7")
    precondition(busy, "Coordinator reports the detached record as working")
    await coordinator.begin(
        generation: 9,
        recordID: "record-7",
        transcriptURL: URL(fileURLWithPath: "/tmp/meeting-7.md"),
        startedAt: Date(timeIntervalSince1970: 0),
        targetLanguage: "English",
        aliases: []
    )
    snapshot = await coordinator.snapshot()
    precondition(snapshot.state == .active(generation: 8), "Retry must not steal the live meeting")
    precondition(snapshot.document?.recordID == "record-8")
    await client.resolveFirst()
    await tick.value
    let requestCount = await client.requestCount()
    precondition(requestCount == 1, "Retry of a busy record must not start a second summarize")
    snapshot = await coordinator.snapshot()
    precondition(snapshot.state == .active(generation: 8))
}


private func testRetractDuringSave(beginNext: Bool) async {
    let client = FakeSummaryClient()
    let store = MemorySummaryStore()
    let coordinator = await makeCoordinator(client: client, store: store)
    await store.holdNext()
    await coordinator.accept(segment("old", text: String(repeating: "a", count: 600)), generation: 1)
    let tick = Task { await coordinator.tick(now: Date(timeIntervalSince1970: 180), generation: 1) }
    while !(await store.isSaveHeld()) { await Task.yield() }
    let retract = Task { await coordinator.retract(["old"], generation: 1) }
    while await coordinator.snapshot().pendingCount != 0 { await Task.yield() }
    if beginNext {
        await coordinator.begin(generation: 2, recordID: "record-2",
            transcriptURL: URL(fileURLWithPath: "/tmp/meeting-2.md"),
            startedAt: Date(), targetLanguage: "English", aliases: [])
    }
    await store.releaseSave()
    await retract.value
    await tick.value
    if beginNext {
        await coordinator.finalize(remaining: [], transcriptURL: URL(fileURLWithPath: "/tmp/meeting-1.md"), generation: 1)
    }
    let snapshot = await coordinator.snapshot()
    precondition(snapshot.document?.sourceIndex["old"] == nil, "Save completion cannot restore a retracted source")
    precondition(snapshot.document?.content.overview.isEmpty == true, "Save completion cannot restore old overview")
    let stored = await store.latest()
    precondition(stored?.sourceIndex["old"] == nil, "Last persisted document must reflect retract")
    precondition(stored?.content.overview.isEmpty == true)
    precondition(!snapshot.isRequestInFlight, "Old completion cannot leave an in-flight task stuck")
}

@main
struct MeetingSummaryCoordinatorTest {
    static func main() async throws {
        await testCostSessionOwnership()
        await testRetractDuringSave(beginNext: false)
        await testRetractDuringSave(beginNext: true)
        if CommandLine.arguments.contains("--save-race-only") {
            print("PASS: retract during save, including next meeting")
            return
        }
        await testTriggerThresholds()
        try await testByteAwareBatching()
        await testInFlightFinalizationAndStaleGeneration()
        await testFailureRetryKeepsCursorAndMergesOnce()
        testLifecycleBufferSendsTranslationOnceAndFallsBackAtStop()
        testLifecycleBufferRetractsWithdrawnSpeech()
        await testCoordinatorRetractsPendingSegments()
        await testCoordinatorRetractsGeneratedOverview()
        await testCoordinatorRetractsInFlightRequest()
        await testBeginDoesNotDropPreviousFinalize()
        await testStaleBeginDoesNotStealNewerSession()
        await testFinalizeAfterBeginStillWritesRemaining()
        await testRetractThenBeginNextDoesNotRestoreWithdrawnSpeech()
        await testRetrySameRecordWhileDetachedDoesNotStartSecondJob()
        print("PASS: meeting summary coordinator state machine")
    }
}
