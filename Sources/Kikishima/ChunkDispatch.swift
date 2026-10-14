import Foundation

/// Prefer punctuation; flush an unchanged tail whole; bound uninterrupted speech
/// by the existing length limits. Text stability is not acoustic silence.
func translationCutoff(_ source: String, doneChars: Int, tuning t: ChunkTuning,
                       age: TimeInterval, stableFor: TimeInterval, finalized: Bool = false) -> Int {
    let chars = Array(source)
    let start = min(max(0, doneChars), chars.count)
    let tail = String(chars[start...])
    guard tail.contains(where: { $0.isLetter || $0.isNumber }) else { return start }
    let cjk = isSpacelessScript(tail)
    let stable = stableFor >= max(2.0, t.timeout + 0.7)
    let safeEnd = TranslationText.prefixEnd(source, from: start)
    // A single oversized grapheme is handled by the transport's scalar splitter.
    let limit = safeEnd > start ? safeEnd : min(start + 1, chars.count)
    let boundedSource = String(chars[..<limit])
    let punctuation = sentenceCutoff(boundedSource, doneChars: start, tuning: t)
    if punctuation > start {
        let minimum = cjk ? t.minSentenceCJK : t.minSentenceLatin
        if punctuation - start < minimum, punctuation >= chars.count - 1, age < t.timeout {
            return start
        }
        return punctuation
    }
    // Do not leave a final word behind when the whole phrase has stopped changing.
    // Stability alone is not a sentence boundary. Give volatile unpunctuated
    // speech a bounded four-second observation window; finals can flush sooner.
    if stable && (finalized || age >= max(4, t.timeout * 2)) { return limit }
    let length = chars.count - start
    if cjk {
        return length > t.hardCutCJK ? start + t.hardCutCJK : start
    }
    // Growing unpunctuated speech is bounded by length, not a timer that may fire
    // after just three words. Never split an unfinished Latin word.
    guard length > t.hardCutLatin else { return start }
    let wordLimit = min(start + t.hardCutLatin + 16, limit)
    var boundary = start
    for index in start..<wordLimit where chars[index].isWhitespace { boundary = index + 1 }
    return boundary > start ? boundary : (chars.count > limit ? limit : start)
}
