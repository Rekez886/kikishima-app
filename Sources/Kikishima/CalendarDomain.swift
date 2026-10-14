import Foundation

enum CalendarSource: String, Codable, Hashable, Sendable, CaseIterable {
    case macOS
    case google
}

enum CalendarParticipationStatus: String, Codable, Sendable {
    case accepted
    case tentative
    case needsAction
    case declined
    case unknown
}

enum CalendarProviderAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case needsReconnect
}

struct CalendarEventCandidate: Identifiable, Equatable, Sendable {
    var providerEventIDs: [CalendarSource: String]
    var sourceCalendarIDs: [CalendarSource: String]
    var sourceNames: [CalendarSource: String]
    var title: String
    var startDate: Date
    var endDate: Date
    var attendeeNames: [String]
    var participationStatus: CalendarParticipationStatus
    var isAllDay: Bool
    var isCancelled: Bool
    var sources: Set<CalendarSource>

    var id: String { CalendarCandidatePolicy.fingerprint(self) }
}

struct MeetingContext: Equatable, Sendable {
    var title: String
    var attendeeNames: [String]
    var startDate: Date
    var endDate: Date
    var sources: Set<CalendarSource>
    var selectedAt: Date
}

protocol CalendarProviding: Sendable {
    var source: CalendarSource { get }
    func authorizationStatus() async -> CalendarProviderAuthorization
    func requestAccess() async -> CalendarProviderAuthorization
    func fetchEvents(in interval: DateInterval) async throws -> [CalendarEventCandidate]
    func disconnect() async
}

protocol CalendarChangeProviding: Sendable {
    func changeStream() async -> AsyncStream<Void>
}

enum CalendarCandidatePolicy {
    static func normalizedTitle(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func fingerprint(_ event: CalendarEventCandidate) -> String {
        let startMinute = Int(event.startDate.timeIntervalSince1970 / 60)
        let endMinute = Int(event.endDate.timeIntervalSince1970 / 60)
        return "\(normalizedTitle(event.title))|\(startMinute)|\(endMinute)"
    }

    static func process(
        _ events: [CalendarEventCandidate],
        now: Date,
        calendar: Calendar
    ) -> [CalendarEventCandidate] {
        var merged: [String: CalendarEventCandidate] = [:]
        var order: [String] = []

        for event in events {
            let normalized = normalizedTitle(event.title)
            guard !normalized.isEmpty,
                  !event.isAllDay,
                  !event.isCancelled,
                  event.participationStatus != .declined else { continue }

            let key = fingerprint(event)
            guard var existing = merged[key] else {
                var clean = event
                clean.attendeeNames = uniqueNames(event.attendeeNames)
                merged[key] = clean
                order.append(key)
                continue
            }

            existing.providerEventIDs.merge(event.providerEventIDs) { current, _ in current }
            existing.sourceCalendarIDs.merge(event.sourceCalendarIDs) { current, _ in current }
            existing.sourceNames.merge(event.sourceNames) { current, _ in current }
            existing.sources.formUnion(event.sources)
            existing.attendeeNames = uniqueNames(existing.attendeeNames + event.attendeeNames)
            merged[key] = existing
        }

        let startOfToday = calendar.startOfDay(for: now)
        return order.compactMap { merged[$0] }.sorted { left, right in
            let leftBucket = rankBucket(left, now: now, startOfToday: startOfToday)
            let rightBucket = rankBucket(right, now: now, startOfToday: startOfToday)
            if leftBucket != rightBucket { return leftBucket < rightBucket }
            if left.startDate != right.startDate { return left.startDate < right.startDate }
            return left.id < right.id
        }
    }

    private static func uniqueNames(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizedTitle(trimmed)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private static func rankBucket(
        _ event: CalendarEventCandidate,
        now: Date,
        startOfToday: Date
    ) -> Int {
        if event.startDate <= now, event.endDate > now { return 0 }
        if event.startDate > now { return 1 }
        if event.endDate >= startOfToday { return 2 }
        return 3
    }
}
