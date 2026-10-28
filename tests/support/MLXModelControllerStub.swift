// Test-only replacement for the MLX model controller.
import Foundation

@MainActor final class MLXModelController {
    static let shared = MLXModelController()
    private(set) var loadCount = 0
    private(set) var translateCount = 0
    private(set) var events: [String] = []

    func note(_ event: String) { events.append(event) }
    func reset() { loadCount = 0; translateCount = 0; events = [] }

    func load() async throws {
        loadCount += 1
        events.append("load")
    }

    func translate(_ chunk: String, source: String, target: String, timeout: TimeInterval) async throws -> String {
        translateCount += 1
        events.append("translate")
        throw CancellationError()
    }
}
