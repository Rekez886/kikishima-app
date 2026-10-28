import Foundation
import Observation
import MLXLLM
import MLXLMCommon
import MLXLMHFAPI
import MLXLMTokenizers

/// Optional high-quality local translation model. The model is downloaded on
/// demand from Hugging Face, cached by the MLX Swift downloader, and never
/// bundled with the app.
@MainActor
@Observable
final class MLXModelController {
    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    static let shared = MLXModelController()

    private(set) var state: State = .notDownloaded
    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?

    static var physicalMemoryGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }

    /// 24GB machines can hold the 12B 4-bit model; smaller Macs use the 4B.
    static var configuration: ModelConfiguration {
        physicalMemoryGB >= 24
            ? LLMRegistry.translategemma_12b_it_4bit
            : LLMRegistry.translategemma_4b_it_4bit
    }

    static var modelName: String {
        physicalMemoryGB >= 24 ? "TranslateGemma 12B" : "TranslateGemma 4B"
    }

    static var downloadSizeLabel: String {
        physicalMemoryGB >= 24 ? "约 6.6 GB" : "约 2.3 GB"
    }

    var isReady: Bool { state == .ready }

    func load() async throws {
        if let container {
            state = .ready
            _ = container
            return
        }
        if let loadTask {
            _ = try await loadTask.value
            return
        }
        state = .downloading(0)
        let configuration = Self.configuration
        let cacheDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kikishima/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let hub = HubClient(cache: HubCache(cacheDirectory: cacheDirectory))
        let task = Task {
            try await LLMModelFactory.shared.loadContainer(
                from: hub,
                using: TokenizersLoader(),
                configuration: configuration,
                progressHandler: { progress in
                    Task { @MainActor in
                        let value = progress.fractionCompleted
                        if case .downloading = MLXModelController.shared.state {
                            MLXModelController.shared.state = .downloading(value)
                        }
                    }
                }
            )
        }
        loadTask = task
        do {
            let loaded = try await task.value
            container = loaded
            loadTask = nil
            state = .ready
            UserDefaults.standard.set(true, forKey: "mlxModelReady")
            // Warm up once, only after the model is ready and only when the packaged
            // app carries mlx.metallib next to the executable. Silent and background.
            MLXWarmup.shared.perform = {
                _ = try await MLXModelController.generate(
                    container: loaded,
                    text: MLXWarmup.prompt,
                    source: MLXWarmup.sourceLanguage,
                    target: MLXWarmup.targetLanguage,
                    timeout: MLXWarmup.timeout
                )
            }
            MLXWarmup.shared.scheduleAfterReady()
        } catch {
            loadTask = nil
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func translate(_ text: String, source: String, target: String, timeout: TimeInterval) async throws -> String {
        try await load()
        guard let container else { throw TranslateFailure.localUnavailable("本机高质量模型没有加载成功") }
        return try await Self.generate(
            container: container, text: text, source: source, target: target, timeout: timeout)
    }

    /// One generation, shared by `translate()` and the one-shot warm-up.
    ///
    /// Deliberately `nonisolated`: prompt building, tokenization and decoding must
    /// not run on the main actor, so the warm-up never touches the main thread.
    nonisolated static func generate(container: ModelContainer, text: String, source: String,
                                     target: String, timeout: TimeInterval) async throws -> String {
        let sourceCode = TranslationEnginePolicy.mlxLanguageCode(source)
        let targetCode = TranslationEnginePolicy.mlxLanguageCode(target)
        let session = ChatSession(
            container,
            additionalContext: ["source_lang_code": sourceCode, "target_lang_code": targetCode]
        )
        do {
            let response = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await session.respond(to: text)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw TranslateFailure.localUnavailable("本机高质量模型超时")
                }
                defer { group.cancelAll() }
                return try await group.next() ?? ""
            }
            return response.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let failure as TranslateFailure {
            throw failure
        } catch is CancellationError {
            throw TranslateFailure.cancelled
        } catch {
            throw TranslateFailure.localUnavailable("本机高质量模型暂时不可用")
        }
    }
}
