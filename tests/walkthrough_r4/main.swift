import SwiftUI

@main struct Checks {
    static func main() {
        for translation in [false, true] {
            for source in [false, true] {
                precondition(CaptionHierarchy.showsSource(current: true, showTranslation: translation, showSource: source) == source)
                precondition(CaptionHierarchy.showsSource(current: false, showTranslation: translation, showSource: source) == (source && !translation))
                precondition(CaptionHierarchy.historyLineHeight(showTranslation: translation, showSource: source) == (translation || source ? 25 : 0))
            }
        }
        for size in [15.0, 18, 26] {
            for banner in [false, true] {
                for (translation, source) in [(true, true), (true, false), (false, true)] {
                    let limit = CaptionHierarchy.historyLimit(userSize: size, showTranslation: translation, showSource: source, banner: banner)
                    let scale = size / 18
                    let current = ((translation ? 48.0 : 0) + (source ? 22.0 : 0)) * scale
                    let history = CaptionHierarchy.historyLineHeight(showTranslation: translation, showSource: source) * scale + 4
                    precondition((0...3).contains(limit))
                    if limit > 0 { precondition(current + Double(limit) * history + 16 + (banner ? 40 : 0) <= 153) }
                }
            }
        }
        precondition(CaptionHierarchy.historyLimit(userSize: 18, showTranslation: true, showSource: true, banner: false) == 2)
        print("PASS r4 policy: current source retained, bilingual history source hidden, source-only history retained, all scales/banner budgets")
    }
}
