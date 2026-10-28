import Foundation

/// One-shot background warm-up for the optional local MLX model.
///
/// The first generation after a model load pays a lazy-init/JIT cost, so the model
/// is warmed once with a fixed short sentence after it becomes ready. The warm-up
/// is silent: no UI, no progress, no logging, no files, no history, no statistics,
/// and it never touches user text.
///
/// Deliberately free of MLX imports and of `ChatSession`: the real inference closure
/// is injected by `MLXModelController`, so this type compiles on its own for tests.
@MainActor
final class MLXWarmup {
    enum Outcome: Equatable {
        case idle
        case started
        case alreadyScheduled
        case skippedNoMetallib
        case finished
        case failed
    }

    static let shared = MLXWarmup()

    /// Fixed sentence: the warm-up must never see user content.
    static let prompt = "Good morning."
    static let sourceLanguage = "en"
    static let targetLanguage = "zh-Hant"
    /// A warm-up that cannot finish inside this window is abandoned, never retried.
    static let timeout: TimeInterval = 20

    /// Injected so the gate can be tested without MLX and without a bundle.
    var metallibExists: () -> Bool
    /// Injected by `MLXModelController`; runs the actual generation off the main actor.
    var perform: (@Sendable () async throws -> Void)?

    private(set) var hasScheduled = false
    private(set) var runCount = 0
    private(set) var isRunning = false
    private(set) var lastOutcome: Outcome = .idle
    private var task: Task<Void, Never>?

    init(metallibExists: @escaping () -> Bool = MLXWarmup.metallibPresent,
         perform: (@Sendable () async throws -> Void)? = nil) {
        self.metallibExists = metallibExists
        self.perform = perform
    }

    /// Schedules the warm-up at most once per process. Never blocks the caller.
    ///
    /// The metallib check happens before any task is created: without it the MLX
    /// runtime exits the whole process, so a missing metallib must never be probed.
    @discardableResult
    func scheduleAfterReady() -> Outcome {
        if hasScheduled {
            lastOutcome = .alreadyScheduled
            return .alreadyScheduled
        }
        guard metallibExists() else {
            lastOutcome = .skippedNoMetallib
            return .skippedNoMetallib
        }
        guard let perform else { return .idle }

        hasScheduled = true
        runCount += 1
        isRunning = true
        lastOutcome = .started
        task = Task.detached(priority: .utility) { [weak self] in
            do {
                try await perform()
                await self?.finish(.finished)
            } catch {
                await self?.finish(.failed)
            }
        }
        return .started
    }

    /// Test/observability hook; the app never waits for the warm-up.
    func waitUntilFinished() async {
        await task?.value
    }

    private func finish(_ outcome: Outcome) {
        isRunning = false
        lastOutcome = outcome
    }

    /// `mlx.metallib` sits next to the executable (Contents/MacOS in the packaged
    /// app). Development builds have no metallib there, so they never warm up.
    nonisolated static func metallibPresent() -> Bool {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return false }
        let url = executable.deletingLastPathComponent().appendingPathComponent("mlx.metallib")
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0 else { return false }
        return true
    }
}
