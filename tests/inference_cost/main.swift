import Foundation
func trAny(_ text: String, _ args: CVarArg...) -> String { text }

private final class CostProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [URLRequest] = []
    static func snapshot() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); Self.lock.unlock()
        let body = #"data: {"choices":[{"delta":{"content":"translated"},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct CostCorrelationTests {
    static func main() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CostProtocol.self]
        let session = URLSession(configuration: config)
        let meeting = UUID(), chunk = UUID()
        let translator = Translator(costSessionID: meeting, transport: session)
        translator.proxyURL = "https://cost-fixture.invalid"
        translator.sessionToken = "synthetic-only"
        let text = String(repeating: "example ", count: 90)
        func translate(_ client: Translator, id: UUID, text: String) async -> String? {
            await withCheckedContinuation { continuation in
                client.translate(id: id, chunk: text, onDelta: { _ in },
                    onDone: { continuation.resume(returning: $0) })
            }
        }
        let first = await translate(translator, id: chunk, text: text)
        precondition(first != nil)
        let initial = CostProtocol.snapshot()
        precondition(initial.count > 1)
        for (index, request) in initial.enumerated() {
            precondition(request.value(forHTTPHeaderField: "x-kikishima-cost-session") == meeting.uuidString.lowercased())
            precondition(request.value(forHTTPHeaderField: "x-kikishima-cost-operation") == "\(chunk.uuidString.lowercased()):\(index + 1)")
            precondition(request.value(forHTTPHeaderField: "x-kikishima-timing") == nil)
        }
        let retry = await translate(translator, id: chunk, text: text)
        precondition(retry != nil)
        let all = CostProtocol.snapshot()
        precondition(all.count == initial.count * 2)
        for index in initial.indices {
            precondition(initial[index].value(forHTTPHeaderField: "x-kikishima-cost-operation")
                == all[index + initial.count].value(forHTTPHeaderField: "x-kikishima-cost-operation"))
        }
        let next = Translator(transport: session)
        next.proxyURL = translator.proxyURL
        next.sessionToken = "synthetic-only"
        let nextResult = await translate(next, id: UUID(), text: "next")
        precondition(nextResult != nil)
        precondition(CostProtocol.snapshot().last!.value(forHTTPHeaderField: "x-kikishima-cost-session") != meeting.uuidString.lowercased())
        print("PASS: real Translator URLSession/SSE with intercepted transport, session ownership, split parts without diagnostics and retry correlation")
    }
}
