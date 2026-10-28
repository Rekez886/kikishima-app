import Foundation

private enum FakeCalendarError: Error { case unavailable }

private actor FakeCalendarGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor FakeCalendarProvider: CalendarProviding {
    nonisolated let source: CalendarSource
    private var events: [CalendarEventCandidate]
    private let shouldFail: Bool
    private let failWhenIntervalLongerThan: TimeInterval?
    private let authorization: CalendarProviderAuthorization
    private let requestedAuthorization: CalendarProviderAuthorization
    private let requestGate: FakeCalendarGate?
    private let fetchGate: FakeCalendarGate?
    private var fetchCount = 0

    init(
        source: CalendarSource,
        events: [CalendarEventCandidate],
        shouldFail: Bool = false,
        failWhenIntervalLongerThan: TimeInterval? = nil,
        authorization: CalendarProviderAuthorization = .authorized,
        requestedAuthorization: CalendarProviderAuthorization? = nil,
        requestGate: FakeCalendarGate? = nil,
        fetchGate: FakeCalendarGate? = nil
    ) {
        self.source = source
        self.events = events
        self.shouldFail = shouldFail
        self.failWhenIntervalLongerThan = failWhenIntervalLongerThan
        self.authorization = authorization
        self.requestedAuthorization = requestedAuthorization ?? authorization
        self.requestGate = requestGate
        self.fetchGate = fetchGate
    }

    func setEvents(_ events: [CalendarEventCandidate]) { self.events = events }
    func authorizationStatus() async -> CalendarProviderAuthorization { authorization }
    func requestAccess() async -> CalendarProviderAuthorization {
        await requestGate?.wait()
        return requestedAuthorization
    }
    func fetchEvents(in interval: DateInterval) async throws -> [CalendarEventCandidate] {
        fetchCount += 1
        await fetchGate?.wait()
        if shouldFail { throw FakeCalendarError.unavailable }
        if let failWhenIntervalLongerThan,
           interval.duration > failWhenIntervalLongerThan {
            throw FakeCalendarError.unavailable
        }
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
    attendeeNames: ["Alice"],
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
    let provider = FakeCalendarProvider(source: .macOS, events: [candidate])
    let coordinator = CalendarCoordinator(
        providers: [provider],
        now: { fixedNow },
        calendar: Calendar(identifier: .gregorian)
    )

    var selectionInput = candidate
    coordinator.select(selectionInput)
    selectionInput.title = "Changed after selection"
    selectionInput.attendeeNames = []
    precondition(coordinator.selectedContext == MeetingContext(
        title: "Design Review",
        attendeeNames: ["Alice"],
        startDate: candidate.startDate,
        endDate: candidate.endDate,
        sources: [.macOS],
        selectedAt: fixedNow
    ))
    let selectedCopy = coordinator.selectedContext
    coordinator.clearSelection()
    precondition(coordinator.selectedContext == nil)
    precondition(selectedCopy?.title == "Design Review", "Clearing selection must not mutate an existing value copy")
    let freshCoordinator = CalendarCoordinator(providers: [provider], now: { fixedNow })
    precondition(freshCoordinator.selectedContext == nil, "A new coordinator must not inherit an earlier selection")
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
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    var fetchCount = await provider.numberOfFetches()
    while fetchCount < 2 && ContinuousClock.now < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
        fetchCount = await provider.numberOfFetches()
    }
    precondition(fetchCount >= 2,
                 "Timed out after 5 seconds waiting for the debounced refresh; fetch count: \(fetchCount)")

    // Give a duplicate refresh time to surface after the expected refresh starts.
    try? await Task.sleep(nanoseconds: 200_000_000)
    fetchCount = await provider.numberOfFetches()
    precondition(fetchCount == 2, "A burst of provider changes must trigger one refresh")
}

@MainActor
private func testPresentationStates() async {
    let notDetermined = CalendarCoordinator(
        providers: [FakeCalendarProvider(source: .macOS, events: [], authorization: .notDetermined)],
        now: { fixedNow }
    )
    precondition(notDetermined.presentationState == .needsPermission)

    let fetchGate = FakeCalendarGate()
    let loading = CalendarCoordinator(
        providers: [FakeCalendarProvider(
            source: .macOS,
            events: [],
            fetchGate: fetchGate
        )],
        now: { fixedNow }
    )
    let loadingTask = Task { await loading.refresh(force: true) }
    let loadingDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !loading.isRefreshing && ContinuousClock.now < loadingDeadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    precondition(loading.presentationState == .loading,
                 "Timed out after 5 seconds waiting for the refresh to publish loading")
    await fetchGate.open()
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
    let requestGate = FakeCalendarGate()
    let provider = FakeCalendarProvider(
        source: .macOS,
        events: [],
        authorization: .notDetermined,
        requestedAuthorization: .authorized,
        requestGate: requestGate
    )
    let coordinator = CalendarCoordinator(providers: [provider], now: { fixedNow })

    let request = Task { await coordinator.requestMacAccess() }
    let requestDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !coordinator.isRequestingMacAccess && ContinuousClock.now < requestDeadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    precondition(coordinator.isRequestingMacAccess, "Clicking Calendar access must immediately publish visible progress")
    await requestGate.open()
    _ = await request.value
    precondition(!coordinator.isRequestingMacAccess)
}

@MainActor
private func testFailureFromTodayRefreshSurvivesMainRefresh() async {
    let provider = FakeCalendarProvider(
        source: .macOS,
        events: [candidate],
        failWhenIntervalLongerThan: 13 * 60 * 60
    )
    let coordinator = CalendarCoordinator(
        providers: [provider],
        now: { fixedNow },
        calendar: Calendar(identifier: .gregorian)
    )

    await coordinator.refreshToday(force: true)
    precondition(coordinator.failedSources == [.macOS])
    await coordinator.refresh(force: true)
    precondition(coordinator.candidates.map(\.title) == ["Design Review"])
    precondition(coordinator.failedSources == [.macOS],
                 "A failed today refresh must stay visible after a successful main refresh")
    precondition(coordinator.lastError != nil)
}

@MainActor
private func testSelectionClearsWhenEventDisappears() async {
    let provider = FakeCalendarProvider(source: .macOS, events: [candidate])
    let coordinator = CalendarCoordinator(
        providers: [provider],
        now: { fixedNow },
        calendar: Calendar(identifier: .gregorian)
    )

    await coordinator.refresh(force: true)
    coordinator.select(candidate)
    precondition(coordinator.selectedContext != nil)
    await provider.setEvents([])
    await coordinator.refresh(force: true)
    precondition(coordinator.selectedContext == nil,
                 "A selection whose event disappeared must not stay stale")
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
        await testFailureFromTodayRefreshSurvivesMainRefresh()
        await testSelectionClearsWhenEventDisappears()
        print("PASS: calendar caching, failure isolation, and selection")
    }
}
