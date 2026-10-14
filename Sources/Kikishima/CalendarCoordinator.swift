import Foundation
import Observation

enum CalendarPresentationState: Equatable, Sendable {
    case needsPermission
    case loading
    case denied
    case empty
    case available
    case selected
}

private struct CalendarRefreshResult: Sendable {
    var authorizations: [CalendarSource: CalendarProviderAuthorization]
    var events: [CalendarEventCandidate]
    var failedSources: Set<CalendarSource>
}

@MainActor
@Observable
final class CalendarCoordinator {
    private(set) var authorizations: [CalendarSource: CalendarProviderAuthorization] = [:]
    private(set) var candidates: [CalendarEventCandidate] = []
    private(set) var todayCandidates: [CalendarEventCandidate] = []
    private(set) var selectedContext: MeetingContext?
    private(set) var isRefreshing = false
    private(set) var isRequestingMacAccess = false
    private(set) var failedSources: Set<CalendarSource> = []
    private(set) var lastError: String?

    var presentationState: CalendarPresentationState {
        if selectedContext != nil { return .selected }
        if isRequestingMacAccess { return .loading }
        if isRefreshing, candidates.isEmpty { return .loading }
        switch authorization(for: .macOS) {
        case .notDetermined:
            return .needsPermission
        case .denied, .restricted, .needsReconnect:
            return .denied
        case .authorized:
            return candidates.isEmpty ? .empty : .available
        }
    }

    @ObservationIgnored private let providers: [any CalendarProviding]
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let cacheLifetime: TimeInterval = 300
    @ObservationIgnored private let changeDebounceNanoseconds: UInt64
    @ObservationIgnored private var lastRefreshAt: Date?
    @ObservationIgnored private var lastTodayRefreshAt: Date?
    @ObservationIgnored private var refreshTask: Task<CalendarRefreshResult, Never>?
    @ObservationIgnored private var todayRefreshTask: Task<CalendarRefreshResult, Never>?
    @ObservationIgnored private var changeDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var providerObservationTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var activeRefreshes = 0

    init(
        providers: [any CalendarProviding],
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current,
        changeDebounceNanoseconds: UInt64 = 500_000_000
    ) {
        self.providers = providers
        self.now = now
        self.calendar = calendar
        self.changeDebounceNanoseconds = changeDebounceNanoseconds
        startObservingProviderChanges()
    }

    deinit {
        changeDebounceTask?.cancel()
        refreshTask?.cancel()
        todayRefreshTask?.cancel()
        for task in providerObservationTasks {
            task.cancel()
        }
    }

    func authorization(for source: CalendarSource) -> CalendarProviderAuthorization {
        authorizations[source] ?? .notDetermined
    }

    func refresh(force: Bool = false) async {
        let requestedAt = now()
        if !force, isCacheFresh(lastRefreshAt, at: requestedAt) { return }

        let interval = DateInterval(
            start: requestedAt.addingTimeInterval(-30 * 60),
            end: requestedAt.addingTimeInterval(12 * 60 * 60)
        )
        let task = refreshTask ?? makeRefreshTask(interval: interval)
        refreshTask = task
        beginRefresh()
        let result = await task.value
        endRefresh()

        apply(result, to: &candidates, now: requestedAt)
        lastRefreshAt = requestedAt
        refreshTask = nil
    }

    func refreshToday(force: Bool = false) async {
        let requestedAt = now()
        if !force, isCacheFresh(lastTodayRefreshAt, at: requestedAt) { return }

        let start = calendar.startOfDay(for: requestedAt)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
        let task = todayRefreshTask ?? makeRefreshTask(interval: DateInterval(start: start, end: end))
        todayRefreshTask = task
        beginRefresh()
        let result = await task.value
        endRefresh()

        apply(result, to: &todayCandidates, now: requestedAt)
        lastTodayRefreshAt = requestedAt
        todayRefreshTask = nil
    }

    @discardableResult
    func requestMacAccess() async -> CalendarProviderAuthorization {
        if isRequestingMacAccess {
            return authorization(for: .macOS)
        }
        guard let provider = providers.first(where: { $0.source == .macOS }) else {
            authorizations[.macOS] = .restricted
            return .restricted
        }
        isRequestingMacAccess = true
        defer { isRequestingMacAccess = false }
        let requestedStatus = await provider.requestAccess()
        let status: CalendarProviderAuthorization = requestedStatus == .notDetermined
            ? .needsReconnect
            : requestedStatus
        authorizations[.macOS] = status
        if status == .authorized {
            await refresh(force: true)
            await refreshToday(force: true)
        }
        return status
    }

    func select(_ candidate: CalendarEventCandidate) {
        selectedContext = MeetingContext(
            title: candidate.title,
            attendeeNames: candidate.attendeeNames,
            startDate: candidate.startDate,
            endDate: candidate.endDate,
            sources: candidate.sources,
            selectedAt: now()
        )
    }

    func clearSelection() {
        selectedContext = nil
    }

    func providerDidChange() {
        lastRefreshAt = nil
        lastTodayRefreshAt = nil
        changeDebounceTask?.cancel()
        let delay = changeDebounceNanoseconds
        changeDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.refresh(force: true)
        }
    }

    private func startObservingProviderChanges() {
        for provider in providers {
            guard let changeProvider = provider as? any CalendarChangeProviding else { continue }
            providerObservationTasks.append(Task { [weak self] in
                let stream = await changeProvider.changeStream()
                for await _ in stream {
                    guard !Task.isCancelled else { return }
                    self?.providerDidChange()
                }
            })
        }
    }

    private func makeRefreshTask(interval: DateInterval) -> Task<CalendarRefreshResult, Never> {
        let providers = providers
        return Task {
            var authorizations: [CalendarSource: CalendarProviderAuthorization] = [:]
            var events: [CalendarEventCandidate] = []
            var failedSources: Set<CalendarSource> = []

            for provider in providers {
                let status = await provider.authorizationStatus()
                authorizations[provider.source] = status
                guard status == .authorized else { continue }
                do {
                    events.append(contentsOf: try await provider.fetchEvents(in: interval))
                } catch {
                    failedSources.insert(provider.source)
                }
            }
            return CalendarRefreshResult(
                authorizations: authorizations,
                events: events,
                failedSources: failedSources
            )
        }
    }

    private func apply(
        _ result: CalendarRefreshResult,
        to destination: inout [CalendarEventCandidate],
        now requestedAt: Date
    ) {
        authorizations.merge(result.authorizations) { current, latest in
            if current == .needsReconnect, latest == .notDetermined {
                return current
            }
            return latest
        }
        failedSources = result.failedSources
        lastError = result.failedSources.isEmpty ? nil : "calendar_refresh_failed"
        destination = CalendarCandidatePolicy.process(result.events, now: requestedAt, calendar: calendar)
    }

    private func isCacheFresh(_ date: Date?, at requestedAt: Date) -> Bool {
        guard let date else { return false }
        let age = requestedAt.timeIntervalSince(date)
        return age >= 0 && age < cacheLifetime
    }

    private func beginRefresh() {
        activeRefreshes += 1
        isRefreshing = true
    }

    private func endRefresh() {
        activeRefreshes = max(0, activeRefreshes - 1)
        isRefreshing = activeRefreshes > 0
    }
}
