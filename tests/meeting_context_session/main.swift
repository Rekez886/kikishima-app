import Foundation

let permanentGlossary = "Kikishima"

let session = MeetingSessionContext()
let context = MeetingContext(
    title: "Design Review",
    attendeeNames: ["Alice"],
    startDate: .distantPast,
    endDate: .distantFuture,
    sources: [.macOS],
    selectedAt: Date()
)

session.begin(selected: context, permanentGlossary: permanentGlossary)
precondition(session.effectiveGlossary == "Kikishima\nDesign Review\nAlice")
precondition(session.recordTitle == "Design Review")
precondition(session.selected == context)

let updatedGlossary = permanentGlossary + "\nAPI → API"
session.updatePermanentGlossary(updatedGlossary)
precondition(session.effectiveGlossary == "Kikishima\nAPI → API\nDesign Review\nAlice")

session.end(permanentGlossary: permanentGlossary)
precondition(session.effectiveGlossary == "Kikishima")
precondition(session.recordTitle == nil)
precondition(session.selected == nil)
session.begin(selected: nil, permanentGlossary: permanentGlossary)
precondition(session.effectiveGlossary == "Kikishima", "A new meeting must not inherit old meeting terms")
precondition(permanentGlossary == "Kikishima")
print("PASS: meeting context session lifecycle")
