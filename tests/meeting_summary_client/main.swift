import Foundation

private final class StubURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var requestCount = 0

    static func configure(_ newHandler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        handler = newHandler
        lock.unlock()
    }

    static func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }

    private static func nextHandler() -> ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        lock.lock()
        defer { lock.unlock() }
        requestCount += 1
        return handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = Self.nextHandler()
            guard let handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func content(sourceID: String = "segment-1") -> MeetingSummaryContent {
    MeetingSummaryContent(
        overview: [SummaryBlock(
            id: "overview-1",
            text: "Launch planning.",
            sourceRefs: [SummarySourceRef(segmentID: sourceID, startSeconds: 0)]
        )],
        currentState: [],
        decisions: [],
        actionItems: [],
        personalItems: [],
        openQuestions: []
    )
}

private func request(text: String = "Jay will send the slides.") -> SummarizeRequest {
    SummarizeRequest(
        requestID: "request-1",
        previous: nil,
        previousSourceIDs: [],
        segments: [SummarySourceSegment(id: "segment-1", startSeconds: 0, text: text)],
        targetLanguage: "English",
        aliases: ["Jay"],
        final: false,
        schemaVersion: 1,
        promptVersion: "2026-08-31-v1"
    )
}

private func response(sourceID: String = "segment-1") throws -> Data {
    try JSONEncoder().encode(SummarizeResponse(
        content: content(sourceID: sourceID),
        processedThrough: "segment-1",
        schemaVersion: 1,
        promptVersion: "2026-08-31-v1"
    ))
}

private func install(status: Int, body: Data) {
    StubURLProtocol.configure { request in
        precondition(request.url?.absoluteString == "https://unit.test/summarize")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
        precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        precondition(request.value(forHTTPHeaderField: "x-request-id") == "request-1")
        return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
    }
}

private func expect(
    _ expected: MeetingSummaryClientError,
    client: MeetingSummaryClient,
    request: SummarizeRequest = request()
) async {
    do {
        _ = try await client.summarize(request)
        preconditionFailure("Expected \(expected)")
    } catch let error as MeetingSummaryClientError {
        precondition(error == expected, "Expected \(expected), got \(error)")
    } catch {
        preconditionFailure("Unexpected error: \(error)")
    }
}

@main
struct MeetingSummaryClientTest {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = MeetingSummaryClient(
            session: session,
            sessionToken: { "session-token" },
            baseURL: { URL(string: "https://unit.test")! }
        )

        install(status: 200, body: try response())
        let valid = try await client.summarize(request())
        precondition(valid.content.overview.first?.text == "Launch planning.")

        let beforeOversized = StubURLProtocol.count()
        await expect(.requestTooLarge, client: client, request: request(text: String(repeating: "a", count: 61 * 1024)))
        let afterOversized = StubURLProtocol.count()
        precondition(beforeOversized == afterOversized, "Oversized request must fail before network")

        install(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))
        await expect(.unauthorized, client: client)
        install(status: 402, body: Data(#"{"error":"subscription_required"}"#.utf8))
        await expect(.subscriptionRequired, client: client)
        install(status: 429, body: Data(#"{"error":"quota_exceeded"}"#.utf8))
        await expect(.quotaExceeded, client: client)
        install(status: 429, body: Data(#"{"error":"rate_limited"}"#.utf8))
        await expect(.rateLimited, client: client)
        install(status: 503, body: Data(#"{"error":"free_pool_exhausted"}"#.utf8))
        await expect(.freePoolExhausted, client: client)
        install(status: 409, body: Data(#"{"error":"request_in_progress"}"#.utf8))
        await expect(.requestInProgress, client: client)
        install(status: 409, body: Data(#"{"error":"request_already_completed"}"#.utf8))
        await expect(.requestAlreadyCompleted, client: client)
        install(status: 409, body: Data(#"{"error":"request_body_mismatch"}"#.utf8))
        await expect(.requestBodyMismatch, client: client)

        install(status: 200, body: Data("not json".utf8))
        await expect(.invalidResponse, client: client)
        install(status: 200, body: try response(sourceID: "unknown"))
        await expect(.invalidResponse, client: client)

        StubURLProtocol.configure { _ in throw URLError(.cancelled) }
        await expect(.cancelled, client: client)

        print("PASS: meeting summary HTTP client")
    }
}
