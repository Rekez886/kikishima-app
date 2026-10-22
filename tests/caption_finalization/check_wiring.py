"""Run the production stop/queue methods with controlled engines and network."""
from pathlib import Path
import sys

source = Path("Sources/Kikishima/CaptionState.swift").read_text()

def method(signature):
    start = source.index(signature)
    opening = source.index("{", start)
    end, depth = opening + 1, 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]

stop = method("func stop(reason:")
complete = method("private func completeStop(")
start = method("func start() -> Bool")
save = method("private func saveTranscript(")
retry = method("func retryTranscript(at url:")
assert stop.index("tap.stop()") < stop.index("stopTask = Task")
assert "translator.cancelAll()" not in stop
assert complete.index("activeTranslationAttempts.removeAll()") < complete.index("translator.cancelAll()")
assert "recoverySettings: recoverySettings" in complete
assert "final || worthSaving" in save
assert 'targetLanguage: recoverySettings?.targetLanguage' in save
assert "if finishingCaptions" in start
assert start.index("translator = Translator(costSessionID:") < start.index("translator.onFailure =")
assert "guard s.sessionGen == gen else { return }" in start
assert "engine.start" not in retry and "sessionGen =" not in retry and "chunks =" not in retry
assert "CaptionDeadline.value(until: deadline)" in retry
assert "meetingSummaryStore.replaceTranscript" in retry
assert "transcriptRetryTask?.cancel()" in source

harness = r'''
import Foundation
func trAny(_ text: String) -> String { text }
func tr(_ text: String) -> String { text }
struct CaptionBanner {
    enum Severity { case info }
    enum Action { case retry }
    let text: String
    let severity: Severity
    let action: Action
}
@MainActor final class Tap {
    var stopped = false
    func stop() { stopped = true }
}
@MainActor final class Engine {
    var resume: CheckedContinuation<Void, Never>?
    var stopped = false
    func finish() async { await withCheckedContinuation { resume = $0 } }
    func stop() { stopped = true }
}
struct MeetingContext {}
struct Context { var selected: MeetingContext? }
struct Start { func end() {} }
struct Chunk {
    let id = UUID()
    let en = "source"
    var isMarker = false
    var translationComplete = false
    var translationAttempts = 0
    var retryAfter = Date.distantPast
}
@MainActor final class Host {
    var running = true, starting = false, finishingCaptions = false, drainingTranscription = false
    var audioLevel = 1.0, silentTooLong = true, audioStalled = true
    var translationPaused = false, resuming = false
    var status = "", sessionGen = 1, engineEpoch = 0
    var meetingSessionContext = Context()
    var startTask: Task<Void, Never>?, restartTask: Task<Void, Never>?
    var resumeTask: Task<Void, Never>?, languageSwitchTask: Task<Void, Never>?
    var stopTask: Task<Void, Never>?
    var chunkTimer: Timer?, deviceChangeWork: DispatchWorkItem?
    let tap = Tap(), engine = Engine()
    var resumeStart = Start()
    var chunks: [Chunk] = []
    var translationRetryQueue = TranslationRetryQueue()
    var activeTranslationAttempts: [UUID: UUID] = [:]
    var inflight = 0, saves = 0, requests = 0
    var errorBanner: CaptionBanner?, rateLimitedUntil: Date?
    var peakInflight = 0
    func stopMicPolling() {}
    func flushPendingTail(translate: Bool) {
        precondition(tap.stopped && engine.stopped && !drainingTranscription)
        for _ in 0..<7 {
            let row = Chunk()
            chunks.append(row)
            if translate { translationRetryQueue.enqueue(row.id) }
        }
    }
    func completeStop(generation: Int, meetingContextSnapshot: MeetingContext?, wasRunning: Bool, reason: String?) {
        saves += 1
        activeTranslationAttempts.removeAll()
        sessionGen += 1
        finishingCaptions = false
    }
    func requestTranslation(for id: UUID, text: String) {
        requests += 1
        inflight += 1
        peakInflight = max(peakInflight, inflight)
        activeTranslationAttempts[id] = UUID()
        let i = chunks.firstIndex(where: { $0.id == id })!
        chunks[i].translationAttempts += 1
        Task {
            try? await Task.sleep(for: .milliseconds(10))
            chunks[i].translationComplete = true
            inflight -= 1
            activeTranslationAttempts[id] = nil
        }
    }
    // METHODS
}
@main struct Check {
    @MainActor static func main() async {
        let host = Host()
        host.stop()
        precondition(host.tap.stopped && !host.running && !host.starting && host.audioLevel == 0)
        precondition(host.finishingCaptions && host.saves == 0)
        host.stop() // Repeated clicks cannot schedule another final write.
        while host.engine.resume == nil { await Task.yield() }
        host.engine.resume?.resume()
        await host.stopTask?.value
        precondition(host.saves == 1 && host.requests == 7 && host.peakInflight == 3)
        precondition(host.chunks.allSatisfy(\.translationComplete))
        host.stop()
        precondition(host.saves == 1)

        let paused = Host()
        paused.translationPaused = true
        paused.stop()
        while paused.engine.resume == nil { await Task.yield() }
        paused.engine.resume?.resume()
        await paused.stopTask?.value
        precondition(paused.requests == 0 && paused.chunks.count == 7 && paused.saves == 1)

        let stubborn = Host()
        let began = ContinuousClock.now
        stubborn.stop()
        await stubborn.stopTask?.value
        precondition(began.duration(to: .now) < .seconds(4))
        precondition(stubborn.engine.stopped && stubborn.saves == 1)
        stubborn.engine.resume?.resume() // Late ASR completion is harmless to the gate.
        print("PASS: production stop/queue methods stop capture immediately, drain 7 tails with 3 slots, save once, respect paused translation and bound non-cooperative ASR")
    }
}
'''
methods = stop + "\n" + method("private func retryFailedChunks(")
Path(sys.argv[1]).write_text(harness.replace("// METHODS", methods))
