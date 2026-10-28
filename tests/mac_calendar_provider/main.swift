import Foundation
import EventKit

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
        attendeeDisplayNames: ["Alice", "", "  Bob  "]
    )

    let candidate = MacCalendarEventMapper.map(raw)
    precondition(candidate.title == "Design Review")
    precondition(candidate.attendeeNames == ["Alice", "Bob"])
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

private func testBirthdayAndHolidayCalendarsAreExcluded() {
    precondition(!MacCalendarProvider.isMeetingCalendar(
        type: .birthday, title: "Work", allowsContentModifications: false))
    precondition(!MacCalendarProvider.isMeetingCalendar(
        type: .subscription, title: "US Holidays", allowsContentModifications: false))
    precondition(!MacCalendarProvider.isMeetingCalendar(
        type: .local, title: "中国节假日", allowsContentModifications: false))
    precondition(!MacCalendarProvider.isMeetingCalendar(
        type: .local, title: "祝日", allowsContentModifications: false))
    precondition(MacCalendarProvider.isMeetingCalendar(
        type: .calDAV, title: "Work", allowsContentModifications: true))
    precondition(MacCalendarProvider.isMeetingCalendar(
        type: .local, title: "Holiday Party Planning", allowsContentModifications: true))
    precondition(MacCalendarProvider.isMeetingCalendar(
        type: .subscription, title: "Team calendar", allowsContentModifications: false))
}

testMapperKeepsOnlyApprovedMeetingFields()
testCancelledStatusMapsToCandidateFilterFlag()
testBirthdayAndHolidayCalendarsAreExcluded()
print("PASS: macOS calendar mapping keeps only approved fields")
