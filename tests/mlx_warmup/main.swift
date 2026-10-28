import Foundation

private enum TestFailure: Error {
    case warmth

    var message: String { "warm-up failed" }
}

/// Thread-safe recorder shared with the injected, `@Sendable` warm-up closures.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Int] = [:]

    func bump(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key, default: 0] += 1
    }

    func count(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return storage[key] ?? 0
    }
}

/// Synchronous helper: calling Thread.isMainThread directly inside an async closure
/// is unavailable from asynchronous contexts.
private func runningOnMainThread() -> Bool {
    Thread.isMainThread
}

@main
struct MLXWarmupTest {
    @MainActor
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, name)
            checks += 1
        }

        // 1. No metallib: never create a task and never run the closure.
        let missing = Recorder()
        let skipped = MLXWarmup(metallibExists: { false }, perform: { missing.bump("run") })
        check(skipped.scheduleAfterReady() == .skippedNoMetallib, "metallib_missing_skips")
        check(skipped.runCount == 0, "metallib_missing_skips: no run recorded")
        check(!skipped.hasScheduled, "metallib_missing_skips: not marked scheduled")
        check(missing.count("run") == 0, "metallib_missing_skips: closure never called")

        // 2. Runs exactly once per process.
        let once = Recorder()
        let single = MLXWarmup(metallibExists: { true }, perform: { once.bump("run") })
        check(single.scheduleAfterReady() == .started, "runs_exactly_once: first schedule starts")
        await single.waitUntilFinished()
        check(single.lastOutcome == .finished, "runs_exactly_once: finished cleanly")
        check(single.scheduleAfterReady() == .alreadyScheduled, "runs_exactly_once: second schedule refused")
        check(single.runCount == 1, "runs_exactly_once: one run")
        check(once.count("run") == 1, "runs_exactly_once: closure ran once")

        // 3. The warm-up closure never runs on the main thread.
        let threads = Recorder()
        let offMain = MLXWarmup(metallibExists: { true }, perform: {
            if runningOnMainThread() { threads.bump("main") } else { threads.bump("offMain") }
        })
        check(offMain.scheduleAfterReady() == .started, "runs_off_main_thread: started")
        await offMain.waitUntilFinished()
        check(threads.count("main") == 0, "runs_off_main_thread: never on main thread")
        check(threads.count("offMain") == 1, "runs_off_main_thread: ran off the main thread")

        // 4. Scheduling never blocks the caller (600 ms work, 150 ms budget).
        let slow = MLXWarmup(metallibExists: { true }, perform: {
            try await Task.sleep(for: .milliseconds(600))
        })
        let startedAt = Date()
        check(slow.scheduleAfterReady() == .started, "does_not_block_caller: started")
        let elapsed = Date().timeIntervalSince(startedAt)
        check(elapsed < 0.150, "does_not_block_caller: returned within 150 ms")
        check(slow.isRunning, "does_not_block_caller: still running in the background")
        await slow.waitUntilFinished()
        check(slow.lastOutcome == .finished, "does_not_block_caller: finished after the wait")

        // 5. Failures are silent, never retried, and never surface.
        let failing = MLXWarmup(metallibExists: { true }, perform: {
            throw TestFailure.warmth
        })
        check(failing.scheduleAfterReady() == .started, "failure_is_silent_and_no_retry: started")
        await failing.waitUntilFinished()
        check(failing.lastOutcome == .failed, "failure_is_silent_and_no_retry: recorded as failed")
        check(failing.runCount == 1, "failure_is_silent_and_no_retry: no retry")
        check(failing.scheduleAfterReady() == .alreadyScheduled, "failure_is_silent_and_no_retry: stays one-shot")

        // 6. A real translation completes while the warm-up is still in flight.
        let inFlight = MLXWarmup(metallibExists: { true }, perform: {
            try await Task.sleep(for: .milliseconds(600))
        })
        check(inFlight.scheduleAfterReady() == .started, "translate_not_blocked_by_warmup: started")
        var translationFinished = false
        do {
            _ = try await MLXModelController.shared.translate(
                "Good morning.", source: "en", target: "zh-Hant", timeout: 5)
        } catch is CancellationError {
            translationFinished = true
        } catch {
            translationFinished = false
        }
        check(translationFinished, "translate_not_blocked_by_warmup: translate returned normally")
        check(inFlight.isRunning, "translate_not_blocked_by_warmup: did not wait for the warm-up")
        await inFlight.waitUntilFinished()

        // 7. The warm-up only starts after load completed, and never reloads.
        MLXModelController.shared.reset()
        try await MLXModelController.shared.load()
        check(MLXModelController.shared.events == ["load"], "load_before_warmup: load recorded first")
        check(MLXModelController.shared.loadCount == 1, "load_before_warmup: one load")
        let ordered = MLXWarmup(metallibExists: { true }, perform: {
            await MainActor.run { MLXModelController.shared.note("warmup") }
        })
        check(ordered.scheduleAfterReady() == .started, "load_before_warmup: warm-up started")
        await ordered.waitUntilFinished()
        check(MLXModelController.shared.events == ["load", "warmup"], "load_before_warmup: load precedes warm-up")
        check(ordered.runCount == 1, "load_before_warmup: one warm-up")
        check(MLXModelController.shared.loadCount == 1, "load_before_warmup: warm-up never reloads the model")

        // 8. The stub translation contract is unchanged after a failed warm-up.
        let translationsBefore = MLXModelController.shared.translateCount
        var stillCancels = false
        do {
            _ = try await MLXModelController.shared.translate(
                "Hello.", source: "en", target: "zh-Hant", timeout: 1)
        } catch is CancellationError {
            stillCancels = true
        }
        check(stillCancels, "stub_translate_unaffected: still throws CancellationError")
        check(MLXModelController.shared.translateCount == translationsBefore + 1,
              "stub_translate_unaffected: translate still runs")

        print("PASS mlx warmup: \(checks) checks")
    }
}
