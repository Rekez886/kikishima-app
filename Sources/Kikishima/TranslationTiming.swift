import Foundation

/// Diagnostic data only: no transcript, account, URL, token or wall-clock timestamps.
struct TranslationTiming: Codable, Sendable {
    var measurementVersion: Int = 6
    var pendingAgeMs: Int?
    var queueMs: Int
    var requestToFirstMs: Int?
    var requestToEndMs: Int
    var chunkToFirstMs: Int?
    var succeeded: Bool

    // kind: 0 = finished attempt, 1 = ASR, 2 = network, 3 = lifecycle, 4 = overflow.
    var sampleKind: Int = 0
    var sessionID: Int?
    var chunkID: Int?
    var requestID: Int?
    var event: Int?
    var elapsedMs: Int?
    var shortFragment: Bool?
    var droppedSamples: Int?
    var cutReason: Int?
    var characterCount: Int?
    var utf16Count: Int?
    var subrequestCount: Int?
    var sourceFinal: Bool?
    var inflightAtCut: Int?
    var attemptNumber: Int?
    var asrKind: Int? // v6: 0 = every volatile revision, 1 = final (v3-v5: first volatile only)
    var analyzerID: Int?
    var asrRevisionID: Int?
    var audioStartMs: Int?
    var audioEndMs: Int?
    var asrSources: [ASRSourceSpan]?
    var asrSourceRangeExact: Bool?
    var asrUnattributedCharacters: Int?
    var asrLagMs: Int?
    var audioDroppedCount: Int?
    var subrequestIndex: Int?
    var networkRetry: Int?
    var connectionReused: Bool?
    var transactionCount: Int?
    var requestToHeadersMs: Int?
    var headersToFirstMs: Int?
    var headersToEndMs: Int?
    var networkRequestToEndMs: Int?
    var worker: WorkerPreflightTiming?

    static func milliseconds(_ delta: TimeInterval) -> Int { Int((max(0, delta) * 1000).rounded()) }

    static func sample(pending: TimeInterval?, chunk: TimeInterval, request: TimeInterval,
                       first: TimeInterval?, end: TimeInterval, succeeded: Bool) -> Self {
        func ms(_ delta: TimeInterval) -> Int { Int((max(0, delta) * 1000).rounded()) }
        return Self(pendingAgeMs: pending.map { ms(chunk - $0) },
                    queueMs: ms(request - chunk),
                    requestToFirstMs: first.map { ms($0 - request) },
                    requestToEndMs: ms(end - request),
                    chunkToFirstMs: first.map { ms($0 - chunk) }, succeeded: succeeded)
    }
}

enum TranslationTimingEvent: Int {
    case created = 1, requested = 2, cancelled = 3, retracted = 4, reused = 5
    case sessionStarted = 6, sessionEnded = 7
}

/// The serial writer owns the sample buffer. Encoding and file I/O never run on
/// MainActor; a burst of events produces one atomic snapshot every half second.
final class TranslationTimingWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.kikishima.translation-timing", qos: .utility)
    private let output: URL
    private let limit: Int
    private var rows: [TranslationTiming] = []
    private var scheduled = false
    private var dirty = false
    private var dropped = 0

    init(output: URL, limit: Int = 30_000) { self.output = output; self.limit = limit }

    func append(_ row: TranslationTiming) {
        queue.async {
            if self.rows.count < self.limit { self.rows.append(row) } else { self.dropped += 1 }
            self.dirty = true
            guard !self.scheduled else { return }
            self.scheduled = true
            self.queue.asyncAfter(deadline: .now() + 0.5) {
                self.scheduled = false
                self.write()
            }
        }
    }

    private func write() {
        guard dirty else { return }
        var snapshot = rows
        if dropped > 0 {
            var overflow = TranslationTiming.sample(pending: nil, chunk: 0, request: 0, first: nil, end: 0, succeeded: false)
            overflow.sampleKind = 4; overflow.droppedSamples = dropped
            snapshot.append(overflow)
        }
        if let data = try? JSONEncoder().encode(snapshot),
           (try? data.write(to: output, options: .atomic)) != nil { dirty = false }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { self.write(); continuation.resume() }
        }
    }

    // Only used at process termination and in deterministic tests.
    func flushBeforeExit() { queue.sync { write() } }
}

/// A nil reference keeps disabled chunks from carrying an inline diagnostic row.
@MainActor
final class TranslationTimingMetadata {
    var row: TranslationTiming
    init(_ row: TranslationTiming) { self.row = row }
}

@MainActor
final class TranslationTimingRecorder {
    static let shared = TranslationTimingRecorder()
    // Opt-in per process, enabled only by the local diagnostic launcher.
    private let writer = ProcessInfo.processInfo.environment["KIKISHIMA_TIMING_OUTPUT"].map {
        TranslationTimingWriter(output: URL(fileURLWithPath: $0))
    }
    var enabled: Bool { writer != nil }
    private let origin = ProcessInfo.processInfo.systemUptime
    private var sequence = 0
    private(set) var sessionID: Int?
    private var attempts: [UUID: TranslationTiming] = [:]
    private(set) var firstByAttempt: [UUID: TimeInterval] = [:]

    func nextID() -> Int { sequence += 1; return sequence }

    func beginSession() {
        guard enabled else { return }
        sessionID = nextID()
        event(.sessionStarted)
    }

    func endSession() {
        guard enabled, sessionID != nil else { return }
        event(.sessionEnded)
        sessionID = nil
        Task { await writer?.flush() }
    }

    func event(_ event: TranslationTimingEvent, metadata: TranslationTiming? = nil) {
        guard enabled else { return }
        var row = metadata ?? .sample(pending: nil, chunk: 0, request: 0, first: nil, end: 0, succeeded: true)
        row.sampleKind = 3; row.event = event.rawValue
        row.sessionID = row.sessionID ?? sessionID
        row.elapsedMs = TranslationTiming.milliseconds(ProcessInfo.processInfo.systemUptime - origin)
        record(row)
    }

    func beginAttempt(_ attempt: UUID, metadata: TranslationTiming) {
        guard enabled else { return }
        attempts[attempt] = metadata
        event(.requested, metadata: metadata)
    }

    func first(_ attempt: UUID, at time: TimeInterval) {
        guard enabled, firstByAttempt[attempt] == nil else { return }
        firstByAttempt[attempt] = time
    }

    func finish(_ attempt: UUID, pending: TimeInterval?, chunk: TimeInterval,
                request: TimeInterval, end: TimeInterval, succeeded: Bool, metadata: TranslationTiming? = nil) {
        guard enabled else { return }
        attempts.removeValue(forKey: attempt)
        let first = firstByAttempt.removeValue(forKey: attempt)
        var row = metadata ?? .sample(pending: nil, chunk: chunk, request: request, first: nil, end: end, succeeded: succeeded)
        let measured = TranslationTiming.sample(pending: pending, chunk: chunk, request: request, first: first, end: end, succeeded: succeeded)
        row.pendingAgeMs = measured.pendingAgeMs ?? metadata?.pendingAgeMs; row.queueMs = measured.queueMs
        row.requestToFirstMs = measured.requestToFirstMs; row.requestToEndMs = measured.requestToEndMs
        row.chunkToFirstMs = measured.chunkToFirstMs; row.succeeded = succeeded
        record(row)
    }

    func record(_ row: TranslationTiming) {
        writer?.append(row)
    }

    func recordASR(_ row: TranslationTiming) {
        guard enabled else { return }
        var row = row
        row.elapsedMs = TranslationTiming.milliseconds(ProcessInfo.processInfo.systemUptime - origin)
        record(row)
    }

    func discard(_ attempt: UUID) {
        if let row = attempts.removeValue(forKey: attempt) { event(.cancelled, metadata: row) }
        firstByAttempt.removeValue(forKey: attempt)
    }

    func clearAttempts() {
        for attempt in Array(attempts.keys) { discard(attempt) }
        firstByAttempt.removeAll()
    }

    func flushBeforeExit() { writer?.flushBeforeExit() }
}

/// One instance per analyzer session. No text and no wall-clock timestamps.
/// macOS 26.5 SDK AnalyzerInput docs: implicit first time-code is zero;
/// each subsequent buffer immediately follows the previous buffer.
final class ASRTimingTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var audioEnd: Double = 0
    private var feeds: [(start: Double, end: Double, at: TimeInterval)] = []
    private var dropped = 0
    private let sessionID: Int?
    private let analyzerID: Int?
    private var revision = 0

    init(sessionID: Int? = nil, analyzerID: Int? = nil) {
        self.sessionID = sessionID
        self.analyzerID = analyzerID
    }

    // Called only on the opt-in audio path. Yield under this lock so a result
    // cannot observe its endpoint before the dropped-buffer flag is updated.
    func feed(duration: Double, at: TimeInterval, yield: () -> Bool) {
        lock.lock(); defer { lock.unlock() }
        let start = audioEnd
        audioEnd += duration
        feeds.append((start, audioEnd, at))
        // Compact in batches instead of shifting thousands of entries per buffer.
        if feeds.count > 4096 { feeds.removeFirst(2048) }
        if yield() { dropped += 1 }
    }

    func result(start: Double, end: Double, final: Bool, at: TimeInterval) -> TranslationTiming {
        lock.lock(); defer { lock.unlock() }
        revision += 1
        var row = TranslationTiming.sample(pending: nil, chunk: at, request: at, first: nil, end: at, succeeded: true)
        row.sampleKind = 1; row.asrKind = final ? 1 : 0
        row.sessionID = sessionID; row.analyzerID = analyzerID; row.asrRevisionID = revision
        row.audioDroppedCount = dropped
        // Invalid SDK ranges still receive a revision ID, without fabricated timing.
        guard start.isFinite, end.isFinite, start >= 0, end >= start, end <= 31 * 86_400 else { return row }
        row.audioStartMs = TranslationTiming.milliseconds(start)
        row.audioEndMs = TranslationTiming.milliseconds(end)
        // Once any input is dropped the implicit analyzer timeline is ambiguous.
        // Keep the flag, omit lag and exclude this session's later results.
        if dropped == 0, let oldest = feeds.first, end > oldest.start {
            // Results now include every revision; avoid a linear scan while
            // holding the same lock used by the audio feed.
            var low = 0, high = feeds.count
            while low < high {
                let mid = (low + high) / 2
                if feeds[mid].end + 0.000001 < end { low = mid + 1 } else { high = mid }
            }
            if low < feeds.count, feeds[low].at <= at {
                row.asrLagMs = TranslationTiming.milliseconds(at - feeds[low].at)
            }
        }
        return row
    }
}
