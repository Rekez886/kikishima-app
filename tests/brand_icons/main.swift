import AppKit

@main struct BrandIconChecks {
    @MainActor static func main() {
        func status(running: Bool = true, starting: Bool = false, paused: Bool = false,
                    translationPaused: Bool = false, resuming: Bool = false,
                    switchingLanguage: Bool = false) -> CaptionMenuStatus {
            .resolve(running: running, starting: starting, paused: paused,
                translationPaused: translationPaused, resuming: resuming, switchingLanguage: switchingLanguage)
        }
        precondition(status(running: false, paused: true, translationPaused: true) == .idle,
                     "stale pause flags must not turn a stopped session into a warning")
        precondition(status(running: false, starting: true) == .starting)
        precondition(status() == .running)
        precondition(status(paused: true, translationPaused: true) == .paused,
                     "capture pause takes precedence over translation pause")
        precondition(status(translationPaused: true) == .translationPaused)
        precondition(status(paused: true, resuming: true) == .starting,
                     "resume in flight should not look ready or remain paused")
        precondition(status(switchingLanguage: true) == .starting)
        for state in CaptionMenuStatus.allCases {
            let image = BrandIcons.menuImage(state)
            precondition(image.isTemplate && image.size == NSSize(width: 18, height: 18))
            precondition(image.tiffRepresentation != nil, "all states render through AppKit")
        }
        print("PASS: 7 status scenarios and all 5 native template images")
    }
}
