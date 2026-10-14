import Foundation

let defaults = UserDefaults.standard
let oldGlossary = defaults.object(forKey: "glossary")
defer {
    if let oldGlossary { defaults.set(oldGlossary, forKey: "glossary") }
    else { defaults.removeObject(forKey: "glossary") }
}
defaults.set("Kikishima", forKey: "glossary")

let session = MeetingSessionContext()
let context = MeetingContext(
    title: "Design Review",
    attendeeNames: ["Mika"],
    startDate: .distantPast,
    endDate: .distantFuture,
    sources: [.macOS],
    selectedAt: Date()
)

session.begin(selected: context, permanentGlossary: "Kikishima")
precondition(session.effectiveGlossary == "Kikishima\nDesign Review\nMika")
precondition(session.recordTitle == "Design Review")

session.updatePermanentGlossary("Kikishima\nAPI → API")
precondition(session.effectiveGlossary == "Kikishima\nAPI → API\nDesign Review\nMika")

session.end(permanentGlossary: "Kikishima")
precondition(session.effectiveGlossary == "Kikishima")
precondition(session.recordTitle == nil)
session.begin(selected: nil, permanentGlossary: "Kikishima")
precondition(session.effectiveGlossary == "Kikishima", "A new meeting must not inherit old meeting terms")
precondition(defaults.string(forKey: "glossary") == "Kikishima")
print("PASS: meeting context session lifecycle")
