import Foundation

final class MeetingSessionContext {
    private(set) var selected: MeetingContext?
    private(set) var effectiveGlossary = ""

    var recordTitle: String? {
        guard let selected else { return nil }
        let title = MeetingContextTerms.recordTitle(from: selected.title)
        return title.isEmpty ? nil : title
    }

    func begin(selected: MeetingContext?, permanentGlossary: String) {
        self.selected = selected
        updatePermanentGlossary(permanentGlossary)
    }

    func updatePermanentGlossary(_ permanentGlossary: String) {
        effectiveGlossary = MeetingContextTerms.mergedGlossary(
            permanent: permanentGlossary,
            context: selected
        )
    }

    func end(permanentGlossary: String) {
        selected = nil
        effectiveGlossary = permanentGlossary
    }
}
