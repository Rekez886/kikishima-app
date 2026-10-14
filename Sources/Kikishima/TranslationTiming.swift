import Foundation

/// Diagnostic data only: no transcript, account, URL, token or wall-clock timestamps.
struct TranslationTiming: Codable {
    var measurementVersion: Int = 2
    var pendingAgeMs: Int?
    var queueMs: Int
    var requestToFirstMs: Int?
    var requestToEndMs: Int
    var chunkToFirstMs: Int?
    var succeeded: Bool

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

@MainActor
final class TranslationTimingRecorder {
    // Opt-in per process, enabled only by the local diagnostic launcher.
    private let output = ProcessInfo.processInfo.environment["KIKISHIMA_TIMING_OUTPUT"].map { URL(fileURLWithPath: $0) }
    private var samples: [TranslationTiming] = []
    private(set) var firstByAttempt: [UUID: TimeInterval] = [:]

    func first(_ attempt: UUID, at time: TimeInterval) {
        guard output != nil, firstByAttempt[attempt] == nil else { return }
        firstByAttempt[attempt] = time
    }

    func finish(_ attempt: UUID, pending: TimeInterval?, chunk: TimeInterval,
                request: TimeInterval, end: TimeInterval, succeeded: Bool) {
        guard let output else { return }
        let first = firstByAttempt.removeValue(forKey: attempt)
        guard samples.count < 1000 else { return }
        samples.append(.sample(pending: pending, chunk: chunk, request: request,
                               first: first, end: end, succeeded: succeeded))
        // Bounded, local report. Rewrite atomically so interruption cannot corrupt it.
        if let data = try? JSONEncoder().encode(samples) {
            try? data.write(to: output, options: .atomic)
        }
    }

    func discard(_ attempt: UUID) { firstByAttempt.removeValue(forKey: attempt) }

    func clearAttempts() { firstByAttempt.removeAll() }
}
