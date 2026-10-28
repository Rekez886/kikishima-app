import Foundation
import EventKit
import OSLog

enum MacCalendarRawStatus: Sendable {
    case confirmed
    case tentative
    case cancelled
    case none
}

struct MacCalendarRawEvent: Sendable {
    var eventID: String
    var calendarID: String
    var calendarTitle: String
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var status: MacCalendarRawStatus
    var currentUserStatus: CalendarParticipationStatus
    var attendeeDisplayNames: [String]
}

enum MacCalendarEventMapper {
    static func map(_ raw: MacCalendarRawEvent) -> CalendarEventCandidate {
        CalendarEventCandidate(
            providerEventIDs: [.macOS: raw.eventID],
            sourceCalendarIDs: [.macOS: raw.calendarID],
            sourceNames: [.macOS: raw.calendarTitle],
            title: raw.title,
            startDate: raw.startDate,
            endDate: raw.endDate,
            attendeeNames: raw.attendeeDisplayNames
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            participationStatus: raw.currentUserStatus,
            isAllDay: raw.isAllDay,
            isCancelled: raw.status == .cancelled,
            sources: [.macOS]
        )
    }
}

enum MacCalendarProviderError: Error {
    case unauthorized
}

@MainActor
final class MacCalendarProvider: CalendarProviding, CalendarChangeProviding {
    nonisolated let source: CalendarSource = .macOS
    private static let logger = Logger(subsystem: "com.kikishima.mac", category: "calendar")

    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    func authorizationStatus() async -> CalendarProviderAuthorization {
        Self.authorization(from: EKEventStore.authorizationStatus(for: .event))
    }

    func requestAccess() async -> CalendarProviderAuthorization {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            let rawStatus = EKEventStore.authorizationStatus(for: .event).rawValue
            Self.logger.info("Calendar access request completed: granted=\(granted, privacy: .public) status=\(rawStatus, privacy: .public)")
            return granted ? .authorized : await authorizationStatus()
        } catch {
            let nsError = error as NSError
            Self.logger.error("Calendar access request failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
            return await authorizationStatus()
        }
    }

    func fetchEvents(in interval: DateInterval) async throws -> [CalendarEventCandidate] {
        guard await authorizationStatus() == .authorized else {
            throw MacCalendarProviderError.unauthorized
        }
        // EventKit reads can take hundreds of milliseconds on large stores.
        // Use a fresh store on a background executor instead of the main actor.
        let start = interval.start
        let end = interval.end
        return await Task.detached(priority: .userInitiated) {
            let store = EKEventStore()
            // Birthday and holiday feeds are auto-generated and never meetings.
            let calendars = store.calendars(for: .event).filter {
                Self.isMeetingCalendar(
                    type: $0.type,
                    title: $0.title,
                    allowsContentModifications: $0.allowsContentModifications
                )
            }
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
            return store.events(matching: predicate).map { event in
                let attendees = event.attendees ?? []
                let currentStatus = attendees
                    .first(where: \.isCurrentUser)
                    .map { Self.participation(from: $0.participantStatus) }
                    ?? .unknown
                let raw = MacCalendarRawEvent(
                    eventID: event.eventIdentifier ?? event.calendarItemIdentifier,
                    calendarID: event.calendar.calendarIdentifier,
                    calendarTitle: event.calendar.title,
                    title: event.title ?? "",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    isAllDay: event.isAllDay,
                    status: Self.eventStatus(from: event.status),
                    currentUserStatus: currentStatus,
                    attendeeDisplayNames: attendees.compactMap(\.name)
                )
                return MacCalendarEventMapper.map(raw)
            }
        }.value
    }

    func disconnect() async {
        // EventKit access is controlled by System Settings; the app has no revoke API.
    }

    func changeStream() async -> AsyncStream<Void> {
        AsyncStream { continuation in
            let observer = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: eventStore,
                queue: .main
            ) { _ in
                continuation.yield(())
            }
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    private nonisolated static func authorization(
        from status: EKAuthorizationStatus
    ) -> CalendarProviderAuthorization {
        switch status {
        case .fullAccess, .authorized: return .authorized
        case .notDetermined, .writeOnly: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
    }

    nonisolated static func isMeetingCalendar(
        type: EKCalendarType,
        title: String,
        allowsContentModifications: Bool
    ) -> Bool {
        guard type != .birthday else { return false }
        // Editable calendars are user-managed; only auto/read-only feeds are
        // checked for holiday-style names, so "Holiday Party Planning" stays.
        guard !allowsContentModifications else { return true }
        let name = title.lowercased()
        let excluded = [
            "birthday", "birthdays", "holiday", "holidays", "vacation", "vacations",
            "生日", "假日", "节假日", "节日", "假期", "祝日", "誕生日", "休日",
            "휴일", "생일", "공휴일", "feriado", "feriados", "feiertag", "feiertage",
            "férias", "ferie", "festivi", "congés", "vacances"
        ]
        return !excluded.contains { name.contains($0) }
    }

    private nonisolated static func eventStatus(from status: EKEventStatus) -> MacCalendarRawStatus {
        switch status {
        case .confirmed: return .confirmed
        case .tentative: return .tentative
        case .canceled: return .cancelled
        case .none: return .none
        @unknown default: return .none
        }
    }

    private nonisolated static func participation(
        from status: EKParticipantStatus
    ) -> CalendarParticipationStatus {
        switch status {
        case .accepted: return .accepted
        case .tentative: return .tentative
        case .pending: return .needsAction
        case .declined: return .declined
        case .unknown, .delegated, .completed, .inProcess: return .unknown
        @unknown default: return .unknown
        }
    }
}
