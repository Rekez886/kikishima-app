"""Execute the production ASR acceptance, provenance, trim and forced-tail path."""
from pathlib import Path
import sys

source = Path("Sources/Kikishima/CaptionState.swift").read_text()
engine = Path("Sources/Kikishima/Transcribe.swift").read_text()

def declaration(text, marker):
    start = text.index(marker)
    opening = text.index("{", start)
    end, depth = opening + 1, 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]

handle = declaration(source, "private func handle(")
# Reconnect UI is unrelated to provenance; keep the real result acceptance guards
# and both real text-event branches, including final's immediate tick/trim order.
handle = handle[:handle.index("        case .error")] + "        case .error: return\n        }\n        refreshPending()\n    }"
methods = "\n".join([handle] + [
    declaration(source, marker) for marker in (
        "private func observeASR(", "private func flushPendingTail(", "private var fullText:",
        "private func trimCommitted(", "private func chunkTiming(")
])
# Every source coordinate reset must also reset the diagnostic ledger.
for line_no, line in enumerate(source.splitlines()):
    if "sourceLedger = TranslationSourceLedger()" in line and "private var" not in line:
        assert "asrSourceLedger = nil" in source.splitlines()[line_no + 1]
assert "asrSourceLedger" not in declaration(source, "private func refreshPending(")
assert "observeASR" not in declaration(source, "private func tickChunks(")
assert "case volatile(String, timing: ASRResultTiming? = nil)" in engine
assert "onEvent(.volatile(text, timing: timing))" in engine
assert "onEvent(.finalized(text, timing: timing))" in engine
assert "ASRTimingTimeline(sessionID: recorder.sessionID, analyzerID: recorder.nextID())" in engine

harness = r'''
import Foundation
func trAny(_ text: String, _ args: CVarArg...) -> String { text }
func isShortTranslationFragment(_ text: String) -> Bool { false }
enum TranslationCutReason: Int { case forced = 6 }
// EVENT
struct CaptionChunk {
    let id = UUID()
    let en: String
    var sourceFinal = false
    let timingCreatedAt = ProcessInfo.processInfo.systemUptime
    var timingMetadata: TranslationTimingMetadata?
}
@MainActor final class Host {
    let timingRecorder = TranslationTimingRecorder()
    var asrSourceLedger: ASRSourceLedger?
    var committedEn = "", volatileEn = "", pendingEn = ""
    var sessionGen = 1
    var running = true, starting = false, drainingTranscription = false
    var paused = false, switchingMeetingLanguage = false
    var doneChars = 0, inflight = 0, ticks = 0
    var sourceLedger = TranslationSourceLedger()
    var pendingClock = PendingTextClock()
    var chunks: [CaptionChunk] = []
    func tickChunks() { ticks += 1 }
    func refreshPending() {}
    func requestTranslation(for id: UUID, text: String) {}
    // METHODS
    func receive(_ event: TranscriptEvent, generation: Int = 1) { handle(event, resultGeneration: generation) }
    func flush() { flushPendingTail(translate: false) }
    func trim() { trimCommitted() }
    var text: String { fullText }
}
@main struct Check {
    @MainActor static func main() throws {
        unsetenv("KIKISHIMA_TIMING_OUTPUT")
        let disabled = Host()
        disabled.receive(.volatile("Same text"))
        disabled.flush()
        precondition(disabled.asrSourceLedger == nil && disabled.chunks[0].timingMetadata == nil)
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KK_TEST_TMP_ROOT"]!)
            .appendingPathComponent("asr-flow.json")
        setenv("KIKISHIMA_TIMING_OUTPUT", output.path, 1)
        let host = Host()
        host.timingRecorder.beginSession()
        let timeline = ASRTimingTimeline(sessionID: host.timingRecorder.sessionID, analyzerID: host.timingRecorder.nextID())
        timeline.feed(duration: 1, at: 10) { false }
        func result(_ final: Bool = false) -> ASRResultTiming {
            ASRResultTiming(timeline.result(start: 0, end: 1, final: final, at: 11))
        }
        let first = result()
        host.receive(.volatile("Same text", timing: first))
        host.receive(.volatile("stale must not land", timing: result()), generation: 0)
        host.paused = true
        host.receive(.volatile("paused must not land", timing: result()))
        host.paused = false
        host.switchingMeetingLanguage = true
        host.receive(.finalized("switching must not land", timing: result(true)))
        host.switchingMeetingLanguage = false
        let final = result(true)
        host.receive(.finalized("Same text", timing: final))
        host.flush()
        precondition(host.text == disabled.text && host.chunks.map(\.en) == disabled.chunks.map(\.en))
        let span = host.chunks[0].timingMetadata!.row.asrSources!.first!
        precondition(span.first?.revisionID == first.row.asrRevisionID && span.latest?.revisionID == final.row.asrRevisionID)
        precondition(host.ticks == 1)
        host.running = false
        host.receive(.volatile("stopped must not land", timing: result()))
        host.drainingTranscription = true
        host.receive(.finalized("Final tail", timing: result(true)))
        precondition(host.ticks == 1 && host.text == "Same text Final tail")
        host.flush()
        precondition(host.chunks.last?.en == "Final tail")
        precondition(host.chunks.last?.timingMetadata?.row.asrSourceRangeExact == true)
        // Real trim method preserves shifted provenance and earlier chunk snapshots.
        host.running = true
        host.drainingTranscription = false
        host.committedEn = ""
        host.volatileEn = ""
        host.doneChars = 0
        host.asrSourceLedger = nil
        let longPrefix = String(repeating: "a", count: 2001)
        host.receive(.finalized(longPrefix + " Remaining", timing: result(true)))
        host.doneChars = 2001
        host.trim()
        precondition(host.text == "Remaining" && host.doneChars == 0)
        host.flush()
        precondition(host.chunks.last?.timingMetadata?.row.asrUnattributedCharacters == 0)
        precondition(host.chunks[0].timingMetadata!.row.asrSources!.first! == span)
        // Original splitter output is unchanged when a single grapheme exceeds its limit.
        host.committedEn = ""
        host.volatileEn = ""
        host.doneChars = 0
        host.asrSourceLedger = nil
        let giant = "a" + String(repeating: "\u{301}", count: 320)
        host.receive(.volatile("  " + giant + " Next Next", timing: result()))
        let expected = TranslationText.parts(giant + " Next Next")
        let count = host.chunks.count
        host.flush()
        precondition(host.chunks.dropFirst(count).map(\.en) == expected)
        precondition(host.chunks[count].timingMetadata!.row.asrSourceRangeExact == false)
        host.timingRecorder.flushBeforeExit()
        let rows = try JSONDecoder().decode([TranslationTiming].self, from: Data(contentsOf: output))
        let asr = rows.filter { $0.sampleKind == 1 }
        precondition(asr.count == 5) // rejected old/paused/switching/stopped results never recorded
        precondition(asr.allSatisfy { $0.elapsedMs != nil && $0.sessionID == host.timingRecorder.sessionID })
        let raw = String(data: try Data(contentsOf: output), encoding: .utf8)!
        precondition(!raw.contains("Same") && !raw.contains("Final tail") && !raw.contains("Remaining"))
        print("PASS: production ASR acceptance, identical final, forced tail, trim, disabled parity and numeric persistence")
    }
}
'''
event = declaration(engine, "enum TranscriptEvent")
Path(sys.argv[1]).write_text(harness.replace("// EVENT", event).replace("// METHODS", methods))
