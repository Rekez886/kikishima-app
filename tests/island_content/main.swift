import Foundation

@main struct IslandMeasurementTests {
    @MainActor static func main() async throws {
        checkDeviceTransition()
        let display = IslandDisplayContext()
        display.measure(110.1)
        display.measure(125.2)
        precondition(display.measuredHeight == 64, "do not mutate state during layout")
        try await Task.sleep(for: .milliseconds(20))
        precondition(display.measuredHeight == 126, "publish only the latest rounded measurement")
        display.measure(125.8)
        try await Task.sleep(for: .milliseconds(20))
        precondition(display.measuredHeight == 126, "sub-point changes do not resize")
        display.measure(64.01)
        try await Task.sleep(for: .milliseconds(20))
        precondition(display.measuredHeight == 65, "shrinking content rounds up")
        print("PASS segment A measurement coalescing")
    }
}

// Real geometry used by IslandCaptionColumn, with the measured r13 boundaries.
private func checkDeviceTransition() {
    let outerBefore = CaptionIslandLayout.islandContentHeight(measured: 46, visibleHeight: 949, heightLevel: .medium)
    let outerAfter = CaptionIslandLayout.islandContentHeight(measured: 32 + 24, visibleHeight: 949, heightLevel: .medium)
    precondition(outerBefore == 64 && outerAfter == 64, "r13 floor, not a missing frame animation")
    let bounds = CGRect(x: 0, y: 0, width: 520, height: outerBefore)
    for statusHeight: CGFloat in [32, 44] {
        var previousY: CGFloat = 0
        for step in 0...200 {
            let fraction = CGFloat(step) / 200
            let g = IslandCaptionColumnGeometry(bounds: bounds, statusHeight: statusHeight, fraction: fraction)
            precondition(g.captions.minY == g.status.maxY && g.captions.maxY == bounds.maxY)
            precondition(g.captions.minY >= previousY && g.captions.minY - previousY <= statusHeight / 200 + 0.001)
            precondition(g.captions.width == 520 && g.status.width == 520)
            previousY = g.captions.minY
        }
        // Removal reuses cached full status height and reverses the same path.
        let middle = IslandCaptionColumnGeometry(bounds: bounds, statusHeight: statusHeight, fraction: 0.5)
        precondition(middle.captions.minY == statusHeight / 2)
    }
    let before = CaptionHierarchy.row(source: "次の予定を一緒に確認しましょう。", translation: "Let's review the next steps together.",
        waiting: false, current: true, showTranslation: true, showSource: true)
    let after = CaptionHierarchy.row(source: "次の予定を一緒に確認しましょう。", translation: "",
        waiting: false, current: true, showTranslation: true, showSource: true)
    precondition(before.accessibilityText.contains("Let's review"))
    precondition(after.accessibilityText == "次の予定を一緒に確認しましょう。")
    precondition(!after.accessibilityText.contains("Let's review") && after.secondary == nil)
    let translatedAgain = CaptionHierarchy.row(source: "source", translation: "new translation", waiting: false,
        current: true, showTranslation: true, showSource: true)
    precondition(translatedAgain.accessibilityText == "new translation\nsource")
    print("PASS r14b: 64pt floor before/after, 402 intermediate viewport frames, forward/reverse boundary, only visible text in AX projection")
}
