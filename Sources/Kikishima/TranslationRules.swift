import Foundation

/// Source-coordinate ledger: revised speech replaces affected chunks, never appends
/// a guessed suffix to a previously translated word. Coordinates use Characters.
struct TranslationSourceLedger {
    struct Span { let id: UUID; let range: Range<Int> }
    private(set) var source = ""
    private(set) var spans: [Span] = []
    private var finalizedThrough = 0
    mutating func reconcile(_ next: String) -> (rewind: Int?, removed: Set<UUID>) {
        let old = Array(source), new = Array(next)
        var common = 0
        while common < min(old.count, new.count), old[common] == new[common] { common += 1 }
        source = next
        guard let index = spans.firstIndex(where: { span in
            if span.range.upperBound > common { return true }
            // A provisional tail can grow into a different word or acquire a
            // negation. Only a finalized/punctuated boundary can be retained.
            return span.range.upperBound == common && common > finalizedThrough && common > 0 && new.count > common &&
                !old[common-1].isPunctuation &&
                (new[common].isLetter || new[common].isNumber || new[common].isWhitespace)
        }) else { return (nil, []) }
        let removed = Set(spans[index...].map(\.id))
        let rewind = spans[index].range.lowerBound
        spans.removeSubrange(index...)
        return (rewind, removed)
    }
    mutating func register(_ id: UUID, range: Range<Int>) { spans.append(Span(id: id, range: range)) }
    mutating func finalizedIDs(through end: Int) -> Set<UUID> {
        finalizedThrough = end
        return Set(spans.filter { $0.range.upperBound <= end }.map(\.id))
    }
    mutating func trim(_ count: Int, source next: String) {
        spans = spans.compactMap { span in
            guard span.range.upperBound > count else { return nil }
            return Span(id: span.id, range: max(0, span.range.lowerBound-count)..<(span.range.upperBound-count))
        }
        finalizedThrough = max(0, finalizedThrough-count)
        source = next
    }
}

/// The server measures JavaScript string length (UTF-16), not Swift Characters.
/// A conservative 160-unit request also leaves output room for language expansion.
enum TranslationText {
    static let requestLimit = 160
    static func prefixEnd(_ text: String, from start: Int, limit: Int = requestLimit) -> Int {
        let chars = Array(text)
        var end = start, units = 0, boundary: Int?
        while end < chars.count {
            let size = String(chars[end]).utf16.count
            guard units + size <= limit else { break }
            units += size; end += 1
            if chars[end-1].isWhitespace { boundary = end }
        }
        if end < chars.count, let boundary, boundary > start { return boundary }
        return end
    }
    static func parts(_ text: String) -> [String] {
        // Scalar splitting bounds even a maliciously large combining-character cluster.
        var result: [String] = [], rest = text
        while !rest.isEmpty {
            let end = prefixEnd(rest, from: 0)
            if end > 0 {
                let chars = Array(rest)
                result.append(String(chars[..<end])); rest = String(chars[end...])
            } else {
                var part = "", units = 0
                for scalar in rest.unicodeScalars {
                    let size = scalar.utf16.count
                    if units + size > requestLimit { break }
                    part.unicodeScalars.append(scalar); units += size
                }
                result.append(part)
                rest = String(rest.unicodeScalars.dropFirst(part.unicodeScalars.count))
            }
        }
        return result.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    static func context(_ text: String) -> String { parts(text).last ?? "" }

    /// Pause/language markers must not leak the previous utterance as GPT context.
    static func frozenPreviousSource(immediatePredecessorIsMarker: Bool, lastNonMarker: String?) -> String {
        immediatePredecessorIsMarker ? "" : (lastNonMarker ?? "")
    }

    /// Only the committed prefix of a flushed tail is source-final for live summary.
    static func tailPartIsSourceFinal(partEnd: Int, committedCount: Int) -> Bool {
        partEnd <= committedCount
    }
    static func repeatedAcknowledgement(_ text: String, after previous: String, interval: TimeInterval) -> Bool {
        guard interval >= 0, interval <= 4, let key = acknowledgement(text) else { return false }
        return key == acknowledgement(previous)
    }
    static func acknowledgement(_ text: String) -> String? {
        let tokens = text.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init)
        guard let first = tokens.first, ["yes", "yeah", "yep", "ok", "okay", "はい", "うん", "好", "好的", "嗯", "네", "예"].contains(first), tokens.allSatisfy({$0 == first}) else { return nil }
        // Questions and mixed/negative answers must remain intact.
        guard !text.contains("?"), !text.contains("？") else { return nil }
        return first
    }
}

/// Nonempty output is not proof of completion. Both the stop reason and terminal
/// event are required; truncation, malformed events and premature EOF fail closed.
struct TranslationStream {
    private(set) var text = ""
    private(set) var done = false
    private var stopped = false
    private var invalid = false
    mutating func accept(_ line: String) {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { done = true; return }
        guard !payload.isEmpty else { return }
        guard let data = payload.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { invalid = true; return }
        if event["error"] != nil { invalid = true }
        guard let choices = event["choices"] as? [[String: Any]], let choice = choices.first else { return }
        if let delta = choice["delta"] as? [String: Any], let content = delta["content"] as? String { text += content }
        if let reason = choice["finish_reason"] as? String { stopped = reason == "stop"; if !stopped { invalid = true } }
    }
    var completed: String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return done && stopped && !invalid && !clean.isEmpty ? clean : nil
    }
}
