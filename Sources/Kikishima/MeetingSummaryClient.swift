import Foundation

protocol MeetingSummaryServicing: Sendable {
    func summarize(_ request: SummarizeRequest) async throws -> SummarizeResponse
}

enum MeetingSummaryClientError: Error, Equatable, Sendable {
    case invalidRequest
    case requestTooLarge
    case unauthorized
    case rateLimited
    case localUnavailable
    case invalidResponse
    case server(Int)
    case network
    case cancelled
}
