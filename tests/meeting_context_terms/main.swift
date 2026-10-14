import Foundation

private let context = MeetingContext(
    title: "DeviantArt Japan / UX Review",
    attendeeNames: ["Mika", "Mika", "Jay", "  "],
    startDate: .distantPast,
    endDate: .distantFuture,
    sources: [.macOS],
    selectedAt: Date()
)

private func testTemporaryTermsDoNotChangePermanentGlossary() {
    let defaults = UserDefaults.standard
    let original = defaults.object(forKey: "glossary")
    defer {
        if let original { defaults.set(original, forKey: "glossary") }
        else { defaults.removeObject(forKey: "glossary") }
    }
    defaults.set("Kikishima\nAPI → API", forKey: "glossary")

    let merged = MeetingContextTerms.mergedGlossary(
        permanent: defaults.string(forKey: "glossary")!,
        context: context
    )

    precondition(
        merged.split(separator: "\n").map(String.init)
            == ["Kikishima", "API → API", "DeviantArt Japan / UX Review", "Mika", "Jay"]
    )
    precondition(defaults.string(forKey: "glossary") == "Kikishima\nAPI → API")
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
    precondition(!lineLimited.contains("Mika"))

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
    precondition(MeetingContextTerms.recordTitle(from: context.title) == "DeviantArt Japan UX Review")
    precondition(MeetingContextTerms.recordTitle(from: "  A:\\B\nC?*  ") == "A B C")
    precondition(MeetingContextTerms.recordTitle(from: String(repeating: "界", count: 90)).count == 80)
}

testTemporaryTermsDoNotChangePermanentGlossary()
testPermanentTermsWinLineAndCharacterLimits()
testRecordTitleRemovesUnsafeFilenameCharacters()
print("PASS: meeting context remains session-only")
