import Foundation

private enum FakeCalendarError: Error { case unavailable }

private actor FakeCalendarProvider: CalendarProviding {
    nonisolated let source: CalendarSource
    private let events: [CalendarEventCandidate]
    private let shouldFail: Bool
    private let authorization: CalendarProviderAuthorization
    private let requestedAuthorization: CalendarProviderAuthorization
    private let requestDelayNanoseconds: UInt64
    private let fetchDelayNanoseconds: UInt64
    private var fetchCount = 0

    init(
        source: CalendarSource,
        events: [CalendarEventCandidate],
        shouldFail: Bool = false,
        authorization: CalendarProviderAuthorization = .authorized,
        requestedAuthorization: CalendarProviderAuthorization? = nil,
        requestDelayNanoseconds: UInt64 = 0,
        fetchDelayNanoseconds: UInt64 = 0
    ) {
        self.source = source
        self.events = events
        self.shouldFail = shouldFail
        self.authorization = authorization
        self.requestedAuthorization = requestedAuthorization ?? authorization
        self.requestDelayNanoseconds = requestDelayNanoseconds
        self.fetchDelayNanoseconds = fetchDelayNanoseconds
    }

    func authorizationStatus() async -> CalendarProviderAuthorization { authorization }
    func requestAccess() async -> CalendarProviderAuthorization {
        if requestDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: requestDelayNanoseconds)
        }
        return requestedAuthorization
    }
    func fetchEvents(in interval: DateInterval) async throws -> [CalendarEventCandidate] {
        fetchCount += 1
        if fetchDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: fetchDelayNanoseconds)
        }
        if shouldFail { throw FakeCalendarError.unavailable }
        return events.filter { $0.endDate >= interval.start && $0.startDate <= interval.end }
    }
    func disconnect() async {}
    func numberOfFetches() -> Int { fetchCount }
}

private let fixedNow = ISO8601DateFormatter().date(from: "2026-09-01T01:00:00Z")!
private let candidate = CalendarEventCandidate(
    providerEventIDs: [.macOS: "event-1"],
    sourceCalendarIDs: [.macOS: "calendar-1"],
    sourceNames: [.macOS: "Work"],
    title: "Design Review",
    startDate: fixedNow.addingTimeInterval(-600),
    endDate: fixedNow.addingTimeInterval(1_800),
    attendeeNames: ["Mika"],
    participationStatus: .accepted,
    isAllDay: false,
    isCancelled: false,
    sources: [.macOS]
)

@MainActor
private func testFiveMinuteCacheAndForcedRefresh() async {
    let provider = FakeCalendarProvider(source: .macOS, events: [candidate])
    let coordinator = CalendarCoordinator(
        providers: [provider],
        now: { fixedNow },
        calendar: Calendar(identifier: .gregorian)
    )

    await coordinator.refresh(force: false)
    await coordinator.refresh(force: false)
    let cachedFetchCount = await provider.numberOfFetches()
    precondition(cachedFetchCount == 1, "Fresh cached events must avoid a duplicate provider request")
    await coordinator.refresh(force: true)
    let forcedFetchCount = await provider.numberOfFetches()
    precondition(forcedFetchCount == 2, "Manual refresh must bypass the cache")
    precondition(coordinator.candidates.map(\.title) == ["Design Review"])
}

@MainActor
private func testOneProviderFailureKeepsOtherProviderResults() async {
    let working = FakeCalendarProvider(source: .macOS, events: [candidate])
    let failing = FakeCalendarProvider(source: .google, events: [], shouldFail: true)
    let coordinator = CalendarCoordinator(
        providers: [working, failing],
        now: { fixedNow },
        calendar: Calendar(identifier: .gregorian)
    )

    await coordinator.refresh(force: true)
    precondition(coordinator.candidates.map(\.title) == ["Design Review"])
    precondition(coordinator.failedSources == [.google])
    precondition(coordinator.lastError != nil)
}

@MainActor
private func testSelectionIsAnEphemeralValueCopy() async {
    let defaults = UserDefaults.standard
    let before = defaults.object(forKey: "selectedMeetingContext")
    defer {
        if let before { defaults.set(before, forKey: "selectedMeetingContext") }
        else { defaults.removeObject(forKey: "selectedMeetingContext") }
    }
    defaults.set("sentinel", forKey: "selectedMeetingContext")
    let provider = FakeCalendarProvider(source: .macOS, events: [candidate])
    let coordinator = CalendarCoordinator(
        providers: [provider],
        now: { fixedNow },
        calendar: Calendar(identifier: .gregorian)
    )

    coordinator.select(candidate)
    precondition(coordinator.selectedContext == MeetingContext(
        title: "Design Review",
        attendeeNames: ["Mika"],
        startDate: candidate.startDate,
        endDate: candidate.endDate,
        sources: [.macOS],
        selectedAt: fixedNow
    ))
    coordinator.clearSelection()
    precondition(coordinator.selectedContext == nil)
    precondition(defaults.string(forKey: "selectedMeetingContext") == "sentinel")
}

@MainActor
private func testProviderChangesDebounceToOneForcedRefresh() async {
    let provider = FakeCalendarProvider(source: .macOS, events: [candidate])
    let coordinator = CalendarCoordinator(
        providers: [provider],
        now: { fixedNow },
        calendar: Calendar(identifier: .gregorian),
        changeDebounceNanoseconds: 1_000_000
    )
    await coordinator.refresh(force: true)
    coordinator.providerDidChange()
    coordinator.providerDidChange()
    try? await Task.sleep(nanoseconds: 30_000_000)
    let fetchCount = await provider.numberOfFetches()
    precondition(fetchCount == 2, "A burst of provider changes must trigger one refresh")
}

@MainActor
private func testPresentationStates() async {
    let notDetermined = CalendarCoordinator(
        providers: [FakeCalendarProvider(source: .macOS, events: [], authorization: .notDetermined)],
        now: { fixedNow }
    )
    precondition(notDetermined.presentationState == .needsPermission)

    let loading = CalendarCoordinator(
        providers: [FakeCalendarProvider(
            source: .macOS,
            events: [],
            fetchDelayNanoseconds: 30_000_000
        )],
        now: { fixedNow }
    )
    let loadingTask = Task { await loading.refresh(force: true) }
    for _ in 0..<20 where !loading.isRefreshing {
        await Task.yield()
    }
    precondition(loading.presentationState == .loading)
    await loadingTask.value

    let denied = CalendarCoordinator(
        providers: [FakeCalendarProvider(source: .macOS, events: [], authorization: .denied)],
        now: { fixedNow }
    )
    await denied.refresh(force: true)
    precondition(denied.presentationState == .denied)

    let empty = CalendarCoordinator(
        providers: [FakeCalendarProvider(source: .macOS, events: [])],
        now: { fixedNow }
    )
    await empty.refresh(force: true)
    precondition(empty.presentationState == .empty)

    let available = CalendarCoordinator(
        providers: [FakeCalendarProvider(source: .macOS, events: [candidate])],
        now: { fixedNow }
    )
    await available.refresh(force: true)
    precondition(available.presentationState == .available)
    available.select(candidate)
    precondition(available.presentationState == .selected)
}

@MainActor
private func testUnresolvedAccessRequestBecomesRecoverableFailure() async {
    let provider = FakeCalendarProvider(
        source: .macOS,
        events: [],
        authorization: .notDetermined,
        requestedAuthorization: .notDetermined
    )
    let coordinator = CalendarCoordinator(providers: [provider], now: { fixedNow })

    let status = await coordinator.requestMacAccess()

    precondition(status == .needsReconnect, "An access request that finishes unresolved must not leave the UI unchanged")
    precondition(coordinator.authorization(for: .macOS) == .needsReconnect)
    precondition(coordinator.presentationState == .denied)
}

@MainActor
private func testRefreshDoesNotEraseRecoverableAccessFailure() async {
    let provider = FakeCalendarProvider(
        source: .macOS,
        events: [],
        authorization: .notDetermined,
        requestedAuthorization: .notDetermined
    )
    let coordinator = CalendarCoordinator(providers: [provider], now: { fixedNow })

    _ = await coordinator.requestMacAccess()
    await coordinator.refresh(force: true)

    precondition(
        coordinator.authorization(for: .macOS) == .needsReconnect,
        "A status refresh must not erase a recoverable access failure with notDetermined"
    )
}

@MainActor
private func testAccessRequestPublishesProgress() async {
    let provider = FakeCalendarProvider(
        source: .macOS,
        events: [],
        authorization: .notDetermined,
        requestedAuthorization: .authorized,
        requestDelayNanoseconds: 30_000_000
    )
    let coordinator = CalendarCoordinator(providers: [provider], now: { fixedNow })

    let request = Task { await coordinator.requestMacAccess() }
    for _ in 0..<20 where !coordinator.isRequestingMacAccess {
        await Task.yield()
    }
    precondition(coordinator.isRequestingMacAccess, "Clicking Calendar access must immediately publish visible progress")
    _ = await request.value
    precondition(!coordinator.isRequestingMacAccess)
}

@main
struct CalendarCoordinatorTests {
    @MainActor
    static func main() async {
        await testFiveMinuteCacheAndForcedRefresh()
        await testOneProviderFailureKeepsOtherProviderResults()
        await testSelectionIsAnEphemeralValueCopy()
        await testProviderChangesDebounceToOneForcedRefresh()
        await testPresentationStates()
        await testUnresolvedAccessRequestBecomesRecoverableFailure()
        await testRefreshDoesNotEraseRecoverableAccessFailure()
        await testAccessRequestPublishesProgress()
        print("PASS: calendar caching, failure isolation, and selection")
    }
}
