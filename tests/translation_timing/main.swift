import Foundation

// Networking is linked only for pure diagnostic arithmetic, never called.
func trAny(_ text: String, _ args: CVarArg...) -> String { text }

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
precondition(Set(json.keys) == Set(["measurementVersion", "pendingAgeMs", "queueMs", "requestToFirstMs", "requestToEndMs", "chunkToFirstMs", "succeeded", "sampleKind"]))
print("PASS: stage timing, failure, retry and diagnostic field allowlist")

// Range endpoints are on the analyzer's zero-based, contiguous input timeline.
let timeline = ASRTimingTimeline(sessionID: 100, analyzerID: 101)
timeline.feed(duration: 0.1, at: 10) { false }
timeline.feed(duration: 0.1, at: 10.1) { false }
let volatile = timeline.result(start: 0, end: 0.15, final: false, at: 10.4)
precondition(volatile.asrLagMs == 300 && volatile.asrKind == 0 && volatile.audioDroppedCount == 0)
let revised = timeline.result(start: 0, end: 0.2, final: false, at: 10.5)
precondition(revised.asrRevisionID == 2 && revised.asrLagMs == 400)
precondition(revised.sessionID == 100 && revised.analyzerID == 101)
precondition(revised.audioStartMs == 0 && revised.audioEndMs == 200)
let finalASR = timeline.result(start: 0, end: 0.2, final: true, at: 10.8)
precondition(finalASR.asrLagMs == 700 && finalASR.asrKind == 1)
precondition(timeline.result(start: 0.2, end: 0.3, final: true, at: 11).asrLagMs == nil)
timeline.feed(duration: 0.1, at: 11) { true }
let dropped = timeline.result(start: 0.2, end: 0.3, final: false, at: 12)
precondition(dropped.audioDroppedCount == 1 && dropped.asrLagMs == nil)
let restarted = ASRTimingTimeline()
restarted.feed(duration: 0.1, at: 20) { false }
precondition(restarted.result(start: 0, end: 0.1, final: false, at: 20.2).asrLagMs == 200)
let bounded = ASRTimingTimeline()
for i in 0..<4100 { bounded.feed(duration: 0.1, at: Double(i)) { false } }
precondition(bounded.result(start: 0, end: 0.1, final: true, at: 5000).asrLagMs == nil)
precondition(bounded.result(start: 409, end: 410, final: true, at: 4100).asrLagMs == 1000)
for (start, end) in [(Double.nan, 1.0), (0, .infinity), (-1, 1), (2, 1), (0, 32 * 86_400)] {
    let invalid = timeline.result(start: start, end: end, final: false, at: 12)
    precondition(invalid.asrRevisionID != nil && invalid.audioStartMs == nil && invalid.asrLagMs == nil)
}
precondition(restarted.result(start: 0, end: 0.1, final: false, at: 19).asrLagMs == nil)

// Keep the first surviving observation and the current revision separately.
let origin1 = ASRSourceID(analyzerID: 1, revisionID: 1)
let origin2 = ASRSourceID(analyzerID: 1, revisionID: 2)
let origin3 = ASRSourceID(analyzerID: 1, revisionID: 3)
func snapshot(_ ledger: ASRSourceLedger, _ range: Range<Int>?) -> TranslationTiming {
    var row = sample
    ledger.attach(to: &row, range: range)
    return row
}
var sources = ASRSourceLedger()
sources.update("We can approve", committedPrefix: "", result: origin1)
sources.update("We cannot approve", committedPrefix: "", result: origin2)
let corrected = snapshot(sources, 0..<17)
precondition(corrected.asrSourceRangeExact == true && corrected.asrUnattributedCharacters == 0)
precondition(corrected.asrSources!.first!.first == origin1 && corrected.asrSources!.first!.latest == origin2)
precondition(corrected.asrSources!.last!.first == origin2)
sources.update("We cannot approve", committedPrefix: "", result: origin3) // identical final
precondition(snapshot(sources, 0..<17).asrSources!.allSatisfy { $0.latest == origin3 })
sources.update("We cannot approve. Next", committedPrefix: "We cannot approve.", result: origin2)
let across = snapshot(sources, 0..<22)
precondition(across.asrUnattributedCharacters == 1) // mismatching committed "." is unknown, not guessed
precondition(across.asrSources!.first!.latest == origin3 && across.asrSources!.last!.latest == origin2)
sources.trim(18, source: "Next")
precondition(snapshot(sources, 0..<4).asrUnattributedCharacters == 4) // mismatched trim fails closed
sources = ASRSourceLedger()
sources.update("你好 👩🏽‍💻 e\u{301}", committedPrefix: "", result: origin1)
sources.update("你好 👩🏽‍💻 e\u{301}", committedPrefix: "", result: origin2)
precondition(snapshot(sources, 0..<6).asrSources!.last!.end == 6)
sources.trim(3, source: "👩🏽‍💻 e\u{301}")
precondition(snapshot(sources, 0..<3).asrSources!.first!.first == origin1)
let restartedOrigin = ASRSourceID(analyzerID: 2, revisionID: 1)
sources.update("👩🏽‍💻 e\u{301}", committedPrefix: "", result: restartedOrigin)
precondition(snapshot(sources, 0..<3).asrSources!.allSatisfy { $0.first == restartedOrigin && $0.latest == restartedOrigin })
sources.update("👩🏽‍💻 e\u{301}", committedPrefix: "", result: nil)
precondition(snapshot(sources, 0..<3).asrUnattributedCharacters == 2)
precondition(snapshot(sources, nil).asrSourceRangeExact == false)
precondition(snapshot(sources, 0..<99).asrSourceRangeExact == false)

var finalizedSources = ASRSourceLedger()
finalizedSources.update("First.", committedPrefix: "", result: origin1)
finalizedSources.update("First. Second.", committedPrefix: "First.", result: origin2)
finalizedSources.update("First. Second.", committedPrefix: "First.", result: origin3)
let finalSpans = snapshot(finalizedSources, 0..<14).asrSources!
precondition(finalSpans.count == 2 && finalSpans[0].latest == origin1)
precondition(finalSpans[1].first == origin2 && finalSpans[1].latest == origin3)
finalizedSources.trim(7, source: "Second.")
precondition(snapshot(finalizedSources, 0..<7).asrSources!.first!.first == origin2)

// Exact UTF-16 matching never confuses repeated text, whitespace or grapheme splits.
var cursor = ASRSourceCursor(source: "  Same Same 👩🏽‍💻", range: 0..<14)
precondition(cursor.consume("Same ") == 2..<7)
precondition(cursor.consume("Same ") == 7..<12)
precondition(cursor.consume("👩🏽‍💻") == 12..<13)
var invalidCursor = ASRSourceCursor(source: "A lost B", range: 0..<8)
precondition(invalidCursor.consume("B") == nil) // non-whitespace may not be skipped
var literalCursor = ASRSourceCursor(source: "e\u{301}", range: 0..<1)
precondition(literalCursor.consume("\u{e9}") == nil) // no canonical-equivalence guessing
let largeGrapheme = "a" + String(repeating: "\u{301}", count: 320)
let forcedSource = "Old.  " + largeGrapheme + " " + String(repeating: " ", count: 170) + "Same Same"
let forcedParts = TranslationText.parts(String(forcedSource.dropFirst(5)).trimmingCharacters(in: .whitespaces))
var forcedCursor = ASRSourceCursor(source: forcedSource, range: 5..<forcedSource.count)
let mapped = forcedParts.map { forcedCursor.consume($0) }
precondition(mapped.prefix(3).allSatisfy { $0 == nil })
precondition(mapped.last! != nil) // exact mapping recovers after the giant cluster / dropped whitespace
let forcedChars = Array(forcedSource)
for (part, range) in zip(forcedParts, mapped) {
    if let range { precondition(String(forcedChars[range]) == part) }
}
let numericSourceJSON = String(data: try JSONEncoder().encode(across), encoding: .utf8)!
precondition(!numericSourceJSON.contains("approve") && !numericSourceJSON.contains("Next"))
print("PASS: ASR origins/latest revisions, corrections, finalization, Unicode, trim/reset/restart and forced-part mapping")
let network = TranslationNetworkTiming.sample(index: 2, count: 3, retry: 1, started: 10,
    headers: 10.2, first: 10.7, ended: 11, reused: true, transactions: 1)
precondition(network.requestToHeadersMs == 200 && network.headersToFirstMs == 500)
precondition(network.headersToEndMs == 800 && network.requestToEndMs == 1000)
precondition(network.connectionReused == true && network.retry == 1 && network.subrequestIndex == 2)
let failedNetwork = TranslationNetworkTiming.sample(index: 1, count: 1, retry: 0, started: 10,
    headers: nil, first: nil, ended: 11, reused: nil, transactions: nil)
precondition(failedNetwork.requestToHeadersMs == nil && failedNetwork.headersToFirstMs == nil && failedNetwork.requestToEndMs == 1000)
var networkRow = sample
networkRow.sampleKind = 2; networkRow.attemptNumber = 2
networkRow.subrequestIndex = network.subrequestIndex; networkRow.subrequestCount = network.subrequestCount
networkRow.networkRetry = network.retry; networkRow.connectionReused = network.connectionReused
networkRow.transactionCount = network.transactionCount; networkRow.requestToHeadersMs = network.requestToHeadersMs
networkRow.headersToFirstMs = network.headersToFirstMs; networkRow.headersToEndMs = network.headersToEndMs
networkRow.networkRequestToEndMs = network.requestToEndMs
let workerJSON = #"{"v":1,"id":42,"route":0,"elapsedMs":90,"d1Calls":3,"cache":0,"attempts":1,"fallback":0,"stages":{"auth":1,"plan":4,"planVersion":4,"quota":5,"d1":9,"upstreamHeaders":80,"private":"must not persist"},"private":"must not persist"}"#
let workerTiming = WorkerPreflightTiming.parse(workerJSON)!
precondition(workerTiming.id == 42 && workerTiming.stages.plan == 4)
networkRow.worker = workerTiming
let encodedWorker = try JSONEncoder().encode(workerTiming)
precondition(!String(data: encodedWorker, encoding: .utf8)!.contains("private"))
for invalid in ["", "null", "{}", String(repeating: " ", count: 2049),
                workerJSON.replacingOccurrences(of: #""v":1"#, with: #""v":2"#),
                workerJSON.replacingOccurrences(of: #""id":42"#, with: #""id":281474976710656"#),
                workerJSON.replacingOccurrences(of: #""attempts":1"#, with: #""attempts":-1"#),
                workerJSON.replacingOccurrences(of: #""fallback":0"#, with: #""fallback":2"#),
                workerJSON.replacingOccurrences(of: #""d1":9"#, with: #""d1":86400001"#)] {
    precondition(WorkerPreflightTiming.parse(invalid) == nil)
}
precondition(WorkerPreflightTiming.parse(nil) == nil)
print("PASS: bounded Worker header schema, invalid ranges and private-field exclusion")
print("PASS: every ASR revision/final, range endpoint mapping, drop exclusion, session reset and network split")

// Exercise the actual opt-in recorder and its persisted report, not just arithmetic.
let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KK_TEST_TMP_ROOT"]!).appendingPathComponent("timing-v6.json")
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
    var metadata = sample
    metadata.cutReason = 1; metadata.characterCount = 24; metadata.utf16Count = 25
    metadata.subrequestCount = 2; metadata.sourceFinal = false; metadata.inflightAtCut = 2; metadata.attemptNumber = 1
    recorder.finish(attempt, pending: 1, chunk: 2.3, request: 2.5, end: 3.8, succeeded: true, metadata: metadata)
    recorder.finish(UUID(), pending: nil, chunk: 4, request: 4.5, end: 19.5, succeeded: false)
    recorder.first(UUID(), at: 20)
    recorder.clearAttempts()
    precondition(recorder.firstByAttempt.isEmpty)
    recorder.flushBeforeExit()
    let rows = try JSONDecoder().decode([TranslationTiming].self, from: Data(contentsOf: output))
    precondition(rows.count == 2 && rows[0].requestToFirstMs == 500)
    precondition(!rows[1].succeeded && rows[1].requestToFirstMs == nil)
    precondition(rows[0].cutReason == 1 && rows[0].characterCount == 24 && rows[0].attemptNumber == 1)
    var forced = metadata
    forced.cutReason = 6; forced.pendingAgeMs = 900
    recorder.finish(UUID(), pending: nil, chunk: 5, request: 6, end: 7, succeeded: true, metadata: forced)
    recorder.flushBeforeExit()
    let forcedRows = try JSONDecoder().decode([TranslationTiming].self, from: Data(contentsOf: output))
    precondition(forcedRows.last?.pendingAgeMs == 900 && forcedRows.last?.cutReason == 6)
    recorder.record(volatile); recorder.record(finalASR); recorder.record(dropped); recorder.record(networkRow)
    recorder.beginSession()
    metadata.sessionID = recorder.sessionID
    metadata.chunkID = recorder.nextID(); metadata.requestID = recorder.nextID()
    metadata.shortFragment = false
    metadata.asrSources = finalSpans
    metadata.asrSourceRangeExact = true
    metadata.asrUnattributedCharacters = 0
    recorder.event(.created, metadata: metadata)
    recorder.beginAttempt(attempt, metadata: metadata)
    recorder.first(attempt, at: 30)
    recorder.discard(attempt)
    recorder.discard(attempt) // Cancelling twice must not duplicate the event.
    let retriedAttempt = UUID()
    metadata.attemptNumber = 2; metadata.requestID = recorder.nextID()
    recorder.beginAttempt(retriedAttempt, metadata: metadata)
    recorder.finish(retriedAttempt, pending: nil, chunk: 30, request: 31, end: 32,
                    succeeded: false, metadata: metadata)
    recorder.event(.retracted, metadata: metadata)
    recorder.endSession()
    recorder.flushBeforeExit()
    let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as! [[String: Any]]
    let allowed = Set(["measurementVersion", "pendingAgeMs", "queueMs", "requestToFirstMs", "requestToEndMs", "chunkToFirstMs", "succeeded", "sampleKind", "cutReason", "characterCount", "utf16Count", "subrequestCount", "sourceFinal", "inflightAtCut", "attemptNumber", "asrKind", "asrLagMs", "audioDroppedCount", "subrequestIndex", "networkRetry", "connectionReused", "transactionCount", "requestToHeadersMs", "headersToFirstMs", "headersToEndMs", "networkRequestToEndMs", "sessionID", "chunkID", "requestID", "event", "elapsedMs", "shortFragment", "worker", "analyzerID", "asrRevisionID", "audioStartMs", "audioEndMs", "asrSources", "asrSourceRangeExact", "asrUnattributedCharacters"])
    precondition(Set(persisted.flatMap { $0.keys }) == allowed)
    for row in persisted {
        precondition(Set(row.keys).isSubset(of: allowed))
        precondition(row.filter { $0.key != "worker" && $0.key != "asrSources" }.values.allSatisfy { $0 is NSNumber })
        if let sources = row["asrSources"] as? [[String: Any]] {
            for span in sources {
                precondition(Set(span.keys) == Set(["start", "end", "first", "latest"]))
                precondition(span["start"] is NSNumber && span["end"] is NSNumber)
                for key in ["first", "latest"] {
                    let reference = span[key] as! [String: Any]
                    precondition(Set(reference.keys) == Set(["analyzerID", "revisionID"]))
                    precondition(reference.values.allSatisfy { $0 is NSNumber })
                }
            }
        }
        if let worker = row["worker"] as? [String: Any] {
            precondition(Set(worker.keys) == Set(["v", "id", "route", "elapsedMs", "d1Calls", "cache", "attempts", "fallback", "stages"]))
            precondition(worker.filter { $0.key != "stages" }.values.allSatisfy { $0 is NSNumber })
            precondition((worker["stages"] as! [String: Any]).values.allSatisfy { $0 is NSNumber })
        }
        precondition(row["measurementVersion"] as? Int == 6)
    }
    let events = persisted.filter { $0["sampleKind"] as? Int == 3 }
    precondition(events.compactMap { $0["event"] as? Int } == [6, 1, 2, 3, 2, 4, 7])
    precondition(events.allSatisfy { $0["sessionID"] as? Int == metadata.sessionID })
    precondition(recorder.firstByAttempt.isEmpty)
    print("PASS: opt-in, first delta, local write/read, failure and session cleanup")
    print("REPORT_FIXTURE=\(output.path)")
}
unsetenv("KIKISHIMA_TIMING_OUTPUT")

let boundedOutput = output.deletingLastPathComponent().appendingPathComponent("timing-overflow.json")
let writer = TranslationTimingWriter(output: boundedOutput, limit: 2)
for _ in 0..<5 { writer.append(sample) }
writer.flushBeforeExit()
let boundedRows = try JSONDecoder().decode([TranslationTiming].self, from: Data(contentsOf: boundedOutput))
precondition(boundedRows.count == 3 && boundedRows.last?.sampleKind == 4 && boundedRows.last?.droppedSamples == 3)
print("PASS: correlated lifecycle, idempotent cancellation, background flush and explicit overflow")
