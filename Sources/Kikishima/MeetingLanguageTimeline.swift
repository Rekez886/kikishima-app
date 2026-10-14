import Foundation

struct MeetingLanguageSwitch: Equatable {
    let fromLocaleID: String
    let toLocaleID: String
}

struct MeetingLanguageTimeline: Equatable {
    private(set) var localeIDs: [String]

    init(initialLocaleID: String) {
        localeIDs = [initialLocaleID]
    }

    var initialLocaleID: String { localeIDs[0] }
    var currentLocaleID: String { localeIDs[localeIDs.count - 1] }
    var transcriptValue: String { localeIDs.joined(separator: " → ") }

    mutating func recordSwitch(to localeID: String) -> MeetingLanguageSwitch? {
        guard localeID != currentLocaleID else { return nil }
        let change = MeetingLanguageSwitch(fromLocaleID: currentLocaleID, toLocaleID: localeID)
        localeIDs.append(localeID)
        return change
    }
}
