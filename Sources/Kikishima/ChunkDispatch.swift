import Foundation

/// Shared by diagnostics and the stable-tail guard; punctuation is not a word.
func isShortTranslationFragment(_ text: String) -> Bool {
    if isSpacelessScript(text) {
        return text.filter { $0.isLetter || $0.isNumber }.count < 4
    }
    return text.split(whereSeparator: \.isWhitespace)
        .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count < 3
}

struct TranslationTailThresholds {
    let stableWait: TimeInterval
    let observation: TimeInterval
    let protectsShortFragments: Bool
}

func translationTailThresholds(_ tuning: ChunkTuning) -> TranslationTailThresholds {
    if tuning.timeout >= ChunkTuning.long.timeout {
        return .init(stableWait: max(2.0, tuning.timeout + 0.7),
                     observation: max(4, tuning.timeout * 2), protectsShortFragments: false)
    }
    return .init(stableWait: 1.0, observation: 2.5, protectsShortFragments: true)
}

private func canFlushStableTail(_ tail: String, tuning: ChunkTuning, age: TimeInterval,
                                stableFor: TimeInterval, finalized: Bool) -> Bool {
    let thresholds = translationTailThresholds(tuning)
    guard stableFor >= thresholds.stableWait,
          finalized || age >= thresholds.observation else { return false }
    return !(thresholds.protectsShortFragments && finalized &&
             age < thresholds.observation && isShortTranslationFragment(tail))
}

/// Prefer punctuation; flush an unchanged tail whole; bound uninterrupted speech
/// by the existing length limits. Text stability is not acoustic silence.
func translationCutoff(_ source: String, doneChars: Int, tuning t: ChunkTuning,
                       age: TimeInterval, stableFor: TimeInterval, finalized: Bool = false) -> Int {
    let chars = Array(source)
    let start = min(max(0, doneChars), chars.count)
    let tail = String(chars[start...])
    guard tail.contains(where: { $0.isLetter || $0.isNumber }) else { return start }
    let cjk = isSpacelessScript(tail)
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
    // Observation is a threshold, not a deadline: changing text still waits for
    // stability. Short finalized fragments can join the next words.
    if canFlushStableTail(tail, tuning: t, age: age, stableFor: stableFor, finalized: finalized) { return limit }
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

/// Numeric codes keep diagnostics free of source text.
enum TranslationCutReason: Int {
    case sentence = 1, clause = 2, shortTimeout = 3, stable = 4, length = 5, forced = 6
}

/// Mirrors the existing decision order without changing translationCutoff or callers.
func translationCutReason(_ source: String, doneChars: Int, tuning t: ChunkTuning,
                          age: TimeInterval, stableFor: TimeInterval, finalized: Bool = false,
                          forced: Bool = false) -> TranslationCutReason? {
    if forced { return .forced }
    let cutoff = translationCutoff(source, doneChars: doneChars, tuning: t, age: age,
                                   stableFor: stableFor, finalized: finalized)
    let chars = Array(source)
    let start = min(max(0, doneChars), chars.count)
    guard cutoff > start else { return nil }
    let safeEnd = TranslationText.prefixEnd(source, from: start)
    let limit = safeEnd > start ? safeEnd : min(start + 1, chars.count)
    let bounded = String(chars[..<limit])
    let punctuation = sentenceCutoff(bounded, doneChars: start, tuning: t)
    if punctuation > start {
        let minimum = isSpacelessScript(String(chars[start...])) ? t.minSentenceCJK : t.minSentenceLatin
        if punctuation - start < minimum && punctuation >= chars.count - 1 && age >= t.timeout { return .shortTimeout }
        // Disable clause cuts to distinguish sentence punctuation using the same scanner.
        var sentenceOnly = t
        sentenceOnly.clauseMinPendingLatin = Int.max
        sentenceOnly.clauseMinPendingCJK = Int.max
        return sentenceCutoff(bounded, doneChars: start, tuning: sentenceOnly) > start ? .sentence : .clause
    }
    if canFlushStableTail(String(chars[start...]), tuning: t, age: age, stableFor: stableFor, finalized: finalized) { return .stable }
    return .length
}
