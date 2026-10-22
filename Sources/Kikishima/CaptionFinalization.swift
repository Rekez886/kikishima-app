import Foundation

/// A deadline must not wait for a cancelled operation to cooperate. The one-shot
/// gate ignores late completions; callers revoke ownership before saving.
@MainActor
private final class DeadlineGate<Value: Sendable> {
    var continuation: CheckedContinuation<Value?, Never>?
    var timer: Task<Void, Never>?
    private var resolved = false

    func resolve(_ value: Value?) {
        guard !resolved else { return }
        resolved = true
        timer?.cancel()
        timer = nil
        continuation?.resume(returning: value)
        continuation = nil
    }
}

@MainActor
enum CaptionDeadline {
    static func value<Value: Sendable>(
        until deadline: ContinuousClock.Instant,
        start: (@escaping @MainActor (Value?) -> Void) -> Void
    ) async -> Value? {
        guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
        let gate = DeadlineGate<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.continuation = continuation
                gate.timer = Task {
                    do { try await Task.sleep(until: deadline, clock: .continuous) }
                    catch { return }
                    gate.resolve(nil)
                }
                start { gate.resolve($0) }
            }
        } onCancel: {
            Task { @MainActor in gate.resolve(nil) }
        }
    }

    static func run(until deadline: ContinuousClock.Instant,
                    operation: @escaping @MainActor () async -> Void) async {
        var work: Task<Void, Never>?
        let _: Bool? = await value(until: deadline) { done in
            work = Task { await operation(); done(true) }
        }
        work?.cancel()
    }
}

@MainActor
enum CaptionFinalization {
    /// The ASR slice and queued translations share this single monotonic budget.
    /// Capture is stopped synchronously by the caller, before entering this task.
    static func drain(
        deadline: ContinuousClock.Instant, asrBudget: Duration = .seconds(2),
        finishASR: @escaping @MainActor () async -> Void,
        freezeASR: () -> Void,
        flushTail: (Bool) -> Void,
        pumpTranslations: () -> Bool
    ) async {
        await CaptionDeadline.run(until: min(deadline, .now.advanced(by: asrBudget)), operation: finishASR)
        freezeASR()
        flushTail(!Task.isCancelled && ContinuousClock.now < deadline)
        while !Task.isCancelled, ContinuousClock.now < deadline, pumpTranslations() {
            do { try await Task.sleep(for: .milliseconds(40)) }
            catch { break }
        }
    }
}
