import Foundation

private func testMapperKeepsOnlyApprovedMeetingFields() {
    let raw = MacCalendarRawEvent(
        eventID: "event-1",
        calendarID: "cal-1",
        calendarTitle: "Work",
        title: "Design Review",
        startDate: Date(timeIntervalSince1970: 100),
        endDate: Date(timeIntervalSince1970: 200),
        isAllDay: false,
        status: .confirmed,
        currentUserStatus: .accepted,
        attendeeDisplayNames: ["Mika", "", "  Ken  "]
    )

    let candidate = MacCalendarEventMapper.map(raw)
    precondition(candidate.title == "Design Review")
    precondition(candidate.attendeeNames == ["Mika", "Ken"])
    precondition(candidate.sources == [.macOS])
    precondition(candidate.providerEventIDs[.macOS] == "event-1")
    precondition(candidate.sourceCalendarIDs[.macOS] == "cal-1")
    precondition(candidate.sourceNames[.macOS] == "Work")
    precondition(!candidate.isCancelled)
}

private func testCancelledStatusMapsToCandidateFilterFlag() {
    let raw = MacCalendarRawEvent(
        eventID: "event-2",
        calendarID: "cal-1",
        calendarTitle: "Work",
        title: "Cancelled Review",
        startDate: Date(timeIntervalSince1970: 100),
        endDate: Date(timeIntervalSince1970: 200),
        isAllDay: false,
        status: .cancelled,
        currentUserStatus: .unknown,
        attendeeDisplayNames: []
    )

    precondition(MacCalendarEventMapper.map(raw).isCancelled)
}

testMapperKeepsOnlyApprovedMeetingFields()
testCancelledStatusMapsToCandidateFilterFlag()
print("PASS: macOS calendar mapping keeps only approved fields")
