import Foundation

private let context = MeetingContext(
    title: "Example Project / UX Review",
    attendeeNames: ["Alice", "Alice", "Bob", "  "],
    startDate: .distantPast,
    endDate: .distantFuture,
    sources: [.macOS],
    selectedAt: Date()
)

private func testTemporaryTermsDoNotChangePermanentGlossary() {
    let permanentGlossary = "Kikishima\nAPI → API"

    let merged = MeetingContextTerms.mergedGlossary(
        permanent: permanentGlossary,
        context: context
    )

    precondition(
        merged.split(separator: "\n").map(String.init)
            == ["Kikishima", "API → API", "Example Project / UX Review", "Alice", "Bob"]
    )
    precondition(permanentGlossary == "Kikishima\nAPI → API")
}

private func testPermanentTermsWinLineAndCharacterLimits() {
    let permanentLines = (0..<79).map { "Permanent\($0)" }.joined(separator: "\n")
    let lineLimited = MeetingContextTerms.mergedGlossary(
        permanent: permanentLines,
        context: context,
        maxLines: 80,
        maxCharacters: 10_000
    )
    let lines = lineLimited.split(separator: "\n").map(String.init)
    precondition(lines.count == 80)
    precondition(lines.last == context.title)
    precondition(!lineLimited.contains("Alice"))

    let characterLimited = MeetingContextTerms.mergedGlossary(
        permanent: String(repeating: "a", count: 3_999),
        context: context,
        maxLines: 80,
        maxCharacters: 4_000
    )
    precondition(characterLimited.count == 3_999)
    precondition(!characterLimited.contains(context.title))
}

private func testRecordTitleRemovesUnsafeFilenameCharacters() {
    precondition(MeetingContextTerms.recordTitle(from: context.title) == "Example Project UX Review")
    precondition(MeetingContextTerms.recordTitle(from: "  A:\\B\nC?*  ") == "A B C")
    precondition(MeetingContextTerms.recordTitle(from: String(repeating: "界", count: 90)).count == 80)
}

testTemporaryTermsDoNotChangePermanentGlossary()
testPermanentTermsWinLineAndCharacterLimits()
testRecordTitleRemovesUnsafeFilenameCharacters()
print("PASS: meeting context remains session-only")
