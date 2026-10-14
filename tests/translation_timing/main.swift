import Foundation

let sample = TranslationTiming.sample(pending: 1, chunk: 2.3, request: 2.5, first: 3, end: 3.8, succeeded: true)
precondition(sample.pendingAgeMs == 1300)
precondition(sample.queueMs == 200)
precondition(sample.requestToFirstMs == 500)
precondition(sample.requestToEndMs == 1300)
precondition(sample.chunkToFirstMs == 700)
let failure = TranslationTiming.sample(pending: nil, chunk: 1, request: 4, first: nil, end: 19, succeeded: false)
precondition(failure.pendingAgeMs == nil && failure.requestToFirstMs == nil && !failure.succeeded)
precondition(failure.queueMs == 3000 && failure.requestToEndMs == 15000)
let retry = TranslationTiming.sample(pending: 1, chunk: 2.3, request: 6, first: 6.5, end: 7, succeeded: true)
precondition(retry.queueMs == 3700 && retry.requestToFirstMs == 500)
let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as! [String: Any]
precondition(Set(json.keys) == Set(["measurementVersion", "pendingAgeMs", "queueMs", "requestToFirstMs", "requestToEndMs", "chunkToFirstMs", "succeeded"]))
print("PASS: stage timing, failure, retry and diagnostic field allowlist")

// Exercise the actual opt-in recorder and its persisted report, not just arithmetic.
let output = FileManager.default.temporaryDirectory.appendingPathComponent("kikishima-timing-test-\(UUID()).json")
unsetenv("KIKISHIMA_TIMING_OUTPUT")
try MainActor.assumeIsolated {
    let disabled = TranslationTimingRecorder()
    let attempt = UUID()
    disabled.first(attempt, at: 3)
    precondition(disabled.firstByAttempt.isEmpty)
    setenv("KIKISHIMA_TIMING_OUTPUT", output.path, 1)
    let recorder = TranslationTimingRecorder()
    recorder.first(attempt, at: 3)
    recorder.first(attempt, at: 3.5) // Later deltas must not replace the first one.
    recorder.finish(attempt, pending: 1, chunk: 2.3, request: 2.5, end: 3.8, succeeded: true)
    recorder.finish(UUID(), pending: nil, chunk: 4, request: 4.5, end: 19.5, succeeded: false)
    recorder.first(UUID(), at: 20)
    recorder.clearAttempts()
    precondition(recorder.firstByAttempt.isEmpty)
    let rows = try JSONDecoder().decode([TranslationTiming].self, from: Data(contentsOf: output))
    precondition(rows.count == 2 && rows[0].requestToFirstMs == 500)
    precondition(!rows[1].succeeded && rows[1].requestToFirstMs == nil)
    print("PASS: opt-in, first delta, local write/read, failure and session cleanup")
    print("REPORT_FIXTURE=\(output.path)")
}
unsetenv("KIKISHIMA_TIMING_OUTPUT")
