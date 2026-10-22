import Foundation

/// Content projection for the bounded home preview. Keep completed text while the
/// next segment is waiting, and append live ASR/draft text independently.
struct CaptionPreviewText {
    let source: String
    let translation: String

    init(segments: [(source: String, translation: String)], pendingSource: String,
         pendingTranslation: String, translationPaused: Bool) {
        source = (segments.map(\.source) + [pendingSource]).filter { !$0.isEmpty }.joined(separator: "\n")
        var translated = segments.map { segment in
            segment.translation.isEmpty ? (translationPaused ? segment.source : "…") : segment.translation
        }
        if !pendingTranslation.isEmpty { translated.append(pendingTranslation) }
        else if translationPaused && !pendingSource.isEmpty { translated.append(pendingSource) }
        translation = translated.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
