import Foundation
func trAny(_ text: String, _ args: CVarArg...) -> String { text }

private final class FixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = request.url!.pathComponents[1]
        if mode == "timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        let code = Int(mode) ?? 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
            headerFields: ["Content-Type": code == 200 ? "text/event-stream" : "application/json"])!, cacheStoragePolicy: .notAllowed)
        let body: String
        switch code {
        case 429: body = "{\"error\":\"quota_exceeded\"}"
        case 503: body = "{\"error\":\"free_pool_exhausted\"}"
        case 200: body = "data: {\"choices\":[{\"delta\":{\"content\":\"translated\"}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        default: body = "{}"
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct TransportCheck {
    static func main() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for mode in ["timeout", "500", "401", "402", "429", "503", "200"] {
            let translator = Translator(transport: session)
            translator.proxyURL = "https://kk033-fixture.invalid/" + mode
            translator.sessionToken = "fixture"
            let context = TranslationConnectivityRequest(chunk: UUID(), attempt: UUID())
            let callbacks = AsyncStream<TranslationCallbackEvent>.makeStream()
            let consumer = Task { () -> ([String], [String], [UUID]) in
                var buffers: [UUID: TranslationConnectivityStatusBuffer] = [:]
                var statuses: [String] = [], failures: [String] = [], ids: [UUID] = []
                for await event in callbacks.stream {
                    let request = event.request
                    switch event {
                    case .status(_, let text):
                        if let message = buffers[request.attempt, default: .init()].receiveStatus(text) { statuses.append(message) }
                    case .failure(_, let failure):
                        let transient: Bool
                        switch failure { case .network, .server, .cancelled: transient = true; default: transient = false }
                        if let text = buffers[request.attempt, default: .init()].classifyStatus(transient: transient) { statuses.append(text) }
                        failures.append(String(describing: failure)); ids.append(request.chunk)
                    case .completion: buffers[request.attempt] = nil
                    }
                }
                return (statuses, failures, ids)
            }
            translator.onStatus = { message in
                guard let request = TranslationConnectivityRequest.current else { preconditionFailure("missing request") }
                callbacks.continuation.yield(.status(request, message))
            }
            translator.onFailure = { failure in
                guard let request = TranslationConnectivityRequest.current else { preconditionFailure("missing request") }
                callbacks.continuation.yield(.failure(request, failure))
            }
            let final: String? = await TranslationConnectivityRequest.context.withValue(context) {
                await withCheckedContinuation { continuation in
                    translator.translate(id: context.chunk, chunk: "source", onDelta: { _ in }, onDone: { final in
                        callbacks.continuation.yield(.completion(context, {}))
                        callbacks.continuation.finish()
                        continuation.resume(returning: final)
                    })
                }
            }
            let values = await consumer.value
            if mode == "200" { precondition(final == "translated" && values.1.isEmpty) }
            else { precondition(final == nil && values.1.count == 1 && values.2 == [context.chunk]) }
            if mode == "timeout" || mode == "500" { precondition(values.0.isEmpty) }
            if mode == "401" { precondition(values.0 == ["登录已过期，请重新登录"]) }
            if mode == "402" { precondition(values.0 == ["需要订阅 Pro"]) }
            if mode == "503" { precondition(values.0.isEmpty && values.1 == ["freePoolExhausted"]) }
            if mode == "429" { precondition(values.1 == ["quotaExceeded"]) }
        }
        print("PASS real Translator callbacks: TaskLocal chunk association, timeout/5xx suppression, retained 401/402/429/503 paths and successful response")
    }
}
