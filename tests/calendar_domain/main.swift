import Foundation

private let now = ISO8601DateFormatter().date(from: "2026-09-01T01:00:00Z")!

private func event(
    id: String,
    source: CalendarSource,
    title: String = "Design Review",
    start: TimeInterval,
    end: TimeInterval,
    allDay: Bool = false,
    cancelled: Bool = false,
    participation: CalendarParticipationStatus = .accepted,
    attendees: [String] = []
) -> CalendarEventCandidate {
    CalendarEventCandidate(
        providerEventIDs: [source: id],
        sourceCalendarIDs: [source: "calendar-1"],
        sourceNames: [source: source == .macOS ? "Work" : "Google Work"],
        title: title,
        startDate: now.addingTimeInterval(start),
        endDate: now.addingTimeInterval(end),
        attendeeNames: attendees,
        participationStatus: participation,
        isAllDay: allDay,
        isCancelled: cancelled,
        sources: [source]
    )
}

private func testInvalidCandidatesAreFiltered() {
    let input = [
        event(id: "valid", source: .macOS, start: -600, end: 1_800),
        event(id: "all-day", source: .macOS, start: -3_600, end: 3_600, allDay: true),
        event(id: "declined", source: .google, start: 7_200, end: 9_000, participation: .declined),
        event(id: "cancelled", source: .google, start: 10_800, end: 12_600, cancelled: true),
        event(id: "blank", source: .macOS, title: "  \n ", start: 14_400, end: 16_200),
    ]

    let result = CalendarCandidatePolicy.process(input, now: now, calendar: Calendar(identifier: .gregorian))
    precondition(result.map(\.title) == ["Design Review"], "Invalid calendar entries must not reach the meeting picker")
}

private func testExactCrossProviderDuplicatesAreMerged() {
    let input = [
        event(id: "mac", source: .macOS, start: -600, end: 1_800, attendees: ["Alice"]),
        event(id: "google", source: .google, title: "  DESIGN   REVIEW ", start: -600, end: 1_800, attendees: ["Bob", "alice"]),
    ]

    let result = CalendarCandidatePolicy.process(input, now: now, calendar: Calendar(identifier: .gregorian))
    precondition(result.count == 1, "The same meeting from macOS and Google must appear once")
    precondition(result[0].title == "Design Review")
    precondition(result[0].sources == [.macOS, .google])
    precondition(result[0].providerEventIDs == [.macOS: "mac", .google: "google"])
    precondition(result[0].attendeeNames == ["Alice", "Bob"], "Attendee names must be unioned without case-only duplicates")
}

private func testMergedParticipationUsesStrongestStatus() {
    let input = [
        event(id: "mac", source: .macOS, start: -600, end: 1_800, participation: .needsAction),
        event(id: "google", source: .google, start: -600, end: 1_800, participation: .accepted),
    ]

    let result = CalendarCandidatePolicy.process(input, now: now, calendar: Calendar(identifier: .gregorian))
    precondition(result.count == 1)
    precondition(result[0].participationStatus == .accepted,
                 "A merged meeting must keep the strongest participation signal")
}

private func testOngoingMeetingsRankBeforeFutureAndPastMeetings() {
    let input = [
        event(id: "past", source: .macOS, title: "Past", start: -7_200, end: -3_600),
        event(id: "future", source: .macOS, title: "Future", start: 3_600, end: 5_400),
        event(id: "ongoing", source: .macOS, title: "Ongoing", start: -600, end: 1_800),
    ]

    let result = CalendarCandidatePolicy.process(input, now: now, calendar: Calendar(identifier: .gregorian))
    precondition(result.map(\.title) == ["Ongoing", "Future", "Past"])
}

testInvalidCandidatesAreFiltered()
testExactCrossProviderDuplicatesAreMerged()
testMergedParticipationUsesStrongestStatus()
testOngoingMeetingsRankBeforeFutureAndPastMeetings()
print("PASS: calendar filtering, ranking, and deduplication")
