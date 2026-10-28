import Foundation
import AVFoundation
import AudioToolbox
import Dispatch

let meter = AudioMeter()
// Contract: snapshot() returns one coherent value containing level, lastLoudAt,
// and lastIOAt, synchronized with BOTH ingest() and reset(). No test-side lock or
// extension may supply this API. Its absence is a deterministic compile failure
// on the current implementation, independent of whether TSan catches a race.
// API existence alone does not prove locking; the runtime checks below and TSan
// must also pass once the production implementation supplies the API.
func checkSnapshot() {
    let sample = meter.snapshot()
    precondition(sample.level.isFinite && (0...1).contains(sample.level),
                 "audit15: snapshot level must be finite and normalized")
    precondition(sample.lastLoudAt.isFinite && sample.lastLoudAt > 0,
                 "audit15: reset/ingest must initialize lastLoudAt")
    precondition(sample.lastIOAt.isFinite && sample.lastIOAt >= 0,
                 "audit15: snapshot IO timestamp must be finite and nonnegative")
    if sample.lastIOAt == 0 {
        precondition(sample.level == 0, "audit15: reset snapshot must be coherent")
    }
}

func makeBuffer() -> (AVAudioFormat, AVAudioPCMBuffer) {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
    buffer.frameLength = 1024
    for i in 0..<1024 { buffer.floatChannelData![0][i] = 0.1 }
    return (format, buffer)
}

meter.reset()
let initial = meter.snapshot()
precondition(initial.level == 0 && initial.lastIOAt == 0 && initial.lastLoudAt > 0,
             "audit15: reset must clear level and IO timestamp")
let (format, buffer) = makeBuffer()
meter.ingest(buffer.audioBufferList, format: format)
let ingested = meter.snapshot()
precondition(abs(ingested.level - 0.6) < 0.001 && ingested.lastIOAt > 0,
             "audit15: snapshot must expose the ingested samples")
precondition(ingested.lastLoudAt == ingested.lastIOAt,
             "audit15: loud ingest must publish matching timestamps")

let start = DispatchSemaphore(value: 0)
let ready = DispatchSemaphore(value: 0)
let group = DispatchGroup()
let iterations = 100_000
// All three workers reach the gate before release. There is no test-side lock
// around meter access. The audio buffer is private to the ingest worker.
group.enter()
let writer = Thread {
    let (format, buffer) = makeBuffer()
    ready.signal()
    start.wait()
    for _ in 0..<iterations { meter.ingest(buffer.audioBufferList, format: format) }
    group.leave()
}
group.enter()
let resetter = Thread {
    ready.signal()
    start.wait()
    for _ in 0..<iterations { meter.reset() }
    group.leave()
}
group.enter()
let reader = Thread {
    ready.signal()
    start.wait()
    for _ in 0..<iterations { checkSnapshot() }
    group.leave()
}
writer.start()
resetter.start()
reader.start()
for _ in 0..<3 {
    precondition(ready.wait(timeout: .now() + 30) == .success,
                 "audit15: all workers must reach the start gate")
}
for _ in 0..<3 { start.signal() }
precondition(group.wait(timeout: .now() + 30) == .success, "audit15: concurrent meter access must not deadlock")
meter.reset()
let final = meter.snapshot()
precondition(final.level == 0 && final.lastIOAt == 0,
             "audit15: reset after concurrent access must clear the snapshot")
checkSnapshot()
print("PASS audit15 snapshot contract and concurrent ingest/reset/read (no TSan reports)")
