import Foundation

/// Keep the disabled TranscriptEvent payload small; allocate only when opted in.
final class ASRResultTiming: Sendable {
    let row: TranslationTiming
    init(_ row: TranslationTiming) { self.row = row }
}

/// Numeric links only. A revision's audio range encloses the entire ASR result;
/// it must never be divided proportionally to invent word-level audio times.
struct ASRSourceID: Codable, Equatable, Sendable {
    let analyzerID: Int
    let revisionID: Int
}

struct ASRSourceSpan: Codable, Equatable, Sendable {
    // Character offsets relative to the chunk, including its whitespace.
    let start: Int
    var end: Int
    let first: ASRSourceID?
    let latest: ASRSourceID?
}

/// Opt-in, in-memory provenance for the same Character coordinates as fullText.
/// Whitespace is not attributed: joining finalized results inserts synthetic spaces.
struct ASRSourceLedger {
    private struct Origin {
        var first: ASRSourceID?
        var latest: ASRSourceID?
    }
    private var characters: [Character] = []
    private var origins: [Origin] = []

    mutating func update(_ next: String, committedPrefix: String, result: ASRSourceID?) {
        let new = Array(next)
        let prefix = Array(committedPrefix.trimmingCharacters(in: .whitespaces))
        var start = 0
        while start < min(prefix.count, new.count), prefix[start] == new[start] { start += 1 }
        var common = 0
        while common < min(characters.count, new.count), characters[common] == new[common] { common += 1 }
        origins = Array(origins.prefix(common)) + Array(repeating: Origin(), count: new.count - common)
        characters = new
        for index in min(max(0, start), new.count)..<new.count {
            guard !new[index].isWhitespace else { origins[index] = Origin(); continue }
            // A restarted analyzer's zero-based audio is a different source,
            // even if it happens to produce identical text.
            if origins[index].latest?.analyzerID != result?.analyzerID {
                origins[index].first = nil
            }
            if origins[index].first == nil { origins[index].first = result }
            origins[index].latest = result
        }
    }

    mutating func trim(_ count: Int, source next: String) {
        let count = min(max(0, count), characters.count)
        let kept = Array(characters.dropFirst(count))
        if kept == Array(next) {
            characters = kept
            origins = Array(origins.dropFirst(count))
        } else {
            // Unexpected normalization is missing evidence, never a guessed join.
            characters = Array(next)
            origins = Array(repeating: Origin(), count: characters.count)
        }
    }

    func attach(to row: inout TranslationTiming, range: Range<Int>?) {
        guard let range, range.lowerBound >= 0, range.upperBound <= characters.count else {
            row.asrSourceRangeExact = false
            return
        }
        row.asrSourceRangeExact = true
        var spans: [ASRSourceSpan] = []
        var missing = 0
        for index in range where !characters[index].isWhitespace {
            let origin = origins[index]
            if origin.first == nil || origin.latest == nil { missing += 1 }
            let offset = index - range.lowerBound
            if let last = spans.last, last.end == offset,
               last.first == origin.first, last.latest == origin.latest {
                spans[spans.count - 1].end = offset + 1
            } else {
                spans.append(ASRSourceSpan(start: offset, end: offset + 1,
                                           first: origin.first, latest: origin.latest))
            }
        }
        row.asrSources = spans
        row.asrUnattributedCharacters = missing
    }
}

/// Match the existing splitter's output monotonically in the unmodified source.
/// Only discarded whitespace may be skipped. UTF-16 boundaries inside a grapheme
/// are deliberately unavailable, but later whole-character parts can map again.
struct ASRSourceCursor {
    private let source: NSString
    private let boundaries: [Int: Int]
    private var offset: Int
    private let end: Int
    private var failed = false

    init(source text: String, range: Range<Int>) {
        let chars = Array(text)
        var boundaries = [0: 0], units = 0
        for (index, char) in chars.enumerated() {
            units += String(char).utf16.count
            boundaries[units] = index + 1
        }
        self.source = text as NSString
        self.boundaries = boundaries
        let lower = min(max(0, range.lowerBound), chars.count)
        let upper = min(max(lower, range.upperBound), chars.count)
        self.offset = String(chars[..<lower]).utf16.count
        self.end = String(chars[..<upper]).utf16.count
    }

    mutating func consume(_ part: String) -> Range<Int>? {
        guard !failed, !part.isEmpty else { return nil }
        let match = source.range(of: part, options: .literal, range: NSRange(location: offset, length: end - offset))
        guard match.location != NSNotFound,
              source.substring(with: NSRange(location: offset, length: match.location - offset))
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            failed = true
            return nil
        }
        offset = NSMaxRange(match)
        guard let lower = boundaries[match.location], let upper = boundaries[offset] else { return nil }
        return lower..<upper
    }
}
