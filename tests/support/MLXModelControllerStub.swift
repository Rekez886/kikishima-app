// Test-only replacement for the MLX model controller.
import Foundation
@MainActor final class MLXModelController {
    static let shared = MLXModelController()
    func translate(_ chunk: String, source: String, target: String, timeout: TimeInterval) async throws -> String { throw CancellationError() }
}
