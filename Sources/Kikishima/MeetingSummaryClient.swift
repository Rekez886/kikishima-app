import Foundation

protocol MeetingSummaryServicing: Sendable {
    func summarize(_ request: SummarizeRequest) async throws -> SummarizeResponse
}

enum MeetingSummaryClientError: Error, Equatable, Sendable {
    case invalidRequest
    case requestTooLarge
    case unauthorized
    case subscriptionRequired
    case quotaExceeded
    case rateLimited
    case freePoolExhausted
    case localUnavailable
    case requestInProgress
    case requestAlreadyCompleted
    case requestBodyMismatch
    case invalidResponse
    case server(Int)
    case network
    case cancelled
}
