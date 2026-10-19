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
    case requestInProgress
    case requestAlreadyCompleted
    case requestBodyMismatch
    case invalidResponse
    case server(Int)
    case network
    case cancelled
}

final class MeetingSummaryClient: MeetingSummaryServicing, @unchecked Sendable {
    static let requestTimeout: TimeInterval = 60
    static let maximumRequestBytes = 60 * 1_024
    static let maximumResponseBytes = 32 * 1_024

    private let session: URLSession
    private let sessionToken: @Sendable () -> String
    private let baseURL: @Sendable () -> URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        session: URLSession = MeetingSummaryClient.makeSession(),
        sessionToken: @escaping @Sendable () -> String,
        baseURL: @escaping @Sendable () -> URL
    ) {
        self.session = session
        self.sessionToken = sessionToken
        self.baseURL = baseURL
    }

    func summarize(_ request: SummarizeRequest) async throws -> SummarizeResponse {
        if Task.isCancelled { throw MeetingSummaryClientError.cancelled }
        let token = sessionToken().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw MeetingSummaryClientError.unauthorized }

        let body: Data
        do {
            body = try encoder.encode(request)
        } catch {
            throw MeetingSummaryClientError.invalidRequest
        }
        guard body.count <= Self.maximumRequestBytes else {
            throw MeetingSummaryClientError.requestTooLarge
        }

        let url = baseURL().appendingPathComponent("summarize", isDirectory: false)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = Self.requestTimeout
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(request.requestID, forHTTPHeaderField: "x-request-id")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw MeetingSummaryClientError.cancelled
            }
            throw MeetingSummaryClientError.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw MeetingSummaryClientError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw mapHTTPError(status: http.statusCode, data: data)
        }
        guard data.count <= Self.maximumResponseBytes,
              let decoded = try? decoder.decode(SummarizeResponse.self, from: data) else {
            throw MeetingSummaryClientError.invalidResponse
        }
        do {
            try MeetingSummaryValidation.validate(response: decoded, request: request)
        } catch {
            throw MeetingSummaryClientError.invalidResponse
        }
        return decoded
    }

    private func mapHTTPError(status: Int, data: Data) -> MeetingSummaryClientError {
        let code: String
        if data.count <= 8 * 1_024,
           let payload = try? decoder.decode(ErrorPayload.self, from: data) {
            code = payload.error
        } else {
            code = ""
        }

        if status == 429 {
            switch HTTPFailurePolicy.classify(status: status, errorCode: code) {
            case .quotaExceeded: return .quotaExceeded
            case .rateLimited: return .rateLimited
            case .temporary: return .server(status)
            }
        }
        switch (status, code) {
        case (401, _): return .unauthorized
        case (402, _): return .subscriptionRequired
        case (503, "free_pool_exhausted"): return .freePoolExhausted
        case (409, "request_in_progress"): return .requestInProgress
        case (409, "request_already_completed"): return .requestAlreadyCompleted
        case (409, "request_body_mismatch"): return .requestBodyMismatch
        default: return .server(status)
        }
    }

    private struct ErrorPayload: Decodable {
        let error: String
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}
