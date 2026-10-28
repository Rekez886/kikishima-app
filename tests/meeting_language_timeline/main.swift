import Foundation

private func testSwitchesStayInOneMeetingTimeline() {
    var timeline = MeetingLanguageTimeline(initialLocaleID: "en_US")

    let japanese = timeline.recordSwitch(to: "ja_JP")
    let duplicate = timeline.recordSwitch(to: "ja_JP")
    let chinese = timeline.recordSwitch(to: "zh_CN")

    precondition(japanese == MeetingLanguageSwitch(fromLocaleID: "en_US", toLocaleID: "ja_JP"))
    precondition(duplicate == nil, "Selecting the current language must not add another marker")
    precondition(chinese == MeetingLanguageSwitch(fromLocaleID: "ja_JP", toLocaleID: "zh_CN"))
    precondition(timeline.initialLocaleID == "en_US", "The transcript filename must keep the meeting's initial language")
    precondition(timeline.currentLocaleID == "zh_CN")
    precondition(timeline.localeIDs == ["en_US", "ja_JP", "zh_CN"], "One meeting must retain the ordered language history")
    precondition(timeline.transcriptValue == "en_US → ja_JP → zh_CN")
}

testSwitchesStayInOneMeetingTimeline()
print("PASS: meeting language switches remain in one timeline")
