import Foundation
func trAny(_ text: String, _ args: CVarArg...) -> String { text }

private final class DeadlineProtocol: URLProtocol {
    static let lock = NSLock()
    static var mode = "normal"
    static var requests: [URLRequest] = []
    static var stopped = 0
    static var runID = UUID()
    private var runID = UUID()
    private let stateLock = NSLock()
    private var closed = false
    private var beat: DispatchSourceTimer?
    static func reset(_ mode: String) { lock.withLock { Self.mode = mode; requests = []; stopped = 0; runID = UUID() } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private func emit(_ body: String) {
        guard !stateLock.withLock({ closed }) else { return }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
    }
    override func startLoading() {
        let mode = Self.lock.withLock { Self.requests.append(request); runID = Self.runID; return Self.mode }
        if mode == "headers" { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        let text = "data: {\"choices\":[{\"delta\":{\"content\":\"translated\"}}]}\n\n"
        if mode == "idle" || mode == "cancel" { emit(text) }
        if mode == "heartbeat" || mode == "idle" {
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now(), repeating: 0.02)
            timer.setEventHandler { [weak self] in self?.emit(": ping\n\ndata: {\"choices\":[{\"delta\":{\"content\":\" \"}}]}\n\n") }
            beat = timer; timer.resume()
        }
        if mode == "normal" || mode == "split" {
            DispatchQueue.global().asyncAfter(deadline: .now() + (mode == "split" ? 0.16 : 0.01)) { [weak self] in
                guard let self, !self.stateLock.withLock({ self.closed }) else { return }
                self.emit(text + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
    override func stopLoading() {
        let first = stateLock.withLock { let first = !closed; closed = true; return first }
        beat?.cancel()
        if first { Self.lock.withLock { if runID == Self.runID { Self.stopped += 1 } } }
    }
}
private final class Failures: @unchecked Sendable {
    let lock = NSLock()
    var values: [TranslateFailure] = []
    func add(_ value: TranslateFailure) { lock.withLock { values.append(value) } }
    var timeout: Bool { lock.withLock { values.contains { if case .network(let text) = $0 { return text == "翻译请求超时" }; return false } } }
}
@main struct DeadlineTests {
    static func main() async {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [DeadlineProtocol.self]
        let transport = URLSession(configuration: cfg)
        defer { transport.invalidateAndCancel() }
        func client(_ limits: TranslationTimeouts = .init(total: 0.6, headers: 0.12, firstText: 0.12, idle: 0.12)) -> Translator {
            let result = Translator(transport: transport, timeouts: limits)
            result.proxyURL = "https://deadline-fixture.invalid"; result.sessionToken = "fixture"
            return result
        }
        func run(_ translator: Translator, text: String = "hello", cancelOnDelta: Bool = false) async -> String? {
            let id = UUID()
            return await withCheckedContinuation { continuation in
                translator.translate(id: id, chunk: text, onDelta: { _ in if cancelOnDelta { translator.cancel(id) } },
                    onDone: { continuation.resume(returning: $0) })
            }
        }
        func waitForNetworkStop() async {
            for _ in 0..<50 {
                if DeadlineProtocol.lock.withLock({ DeadlineProtocol.stopped == 1 }) { return }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        for mode in ["headers", "heartbeat", "idle"] {
            DeadlineProtocol.reset(mode)
            let translator = client(), failures = Failures()
            translator.onFailure = { failures.add($0) }
            let start = ProcessInfo.processInfo.systemUptime
            let result = await run(translator)
            precondition(result == nil && failures.timeout, "\(mode) must be timeout, not user cancel")
            precondition(ProcessInfo.processInfo.systemUptime - start < 1)
            await waitForNetworkStop()
            precondition(DeadlineProtocol.lock.withLock { DeadlineProtocol.stopped == 1 }, "network task must stop")
        }
        DeadlineProtocol.reset("split")
        let split = client(.init(total: 0.26, headers: 0.5, firstText: 0.5, idle: 0.5))
        let failures = Failures(); split.onFailure = { failures.add($0) }
        let result = await run(split, text: String(repeating: "example ", count: 100))
        precondition(result == nil && failures.timeout)
        let requests = DeadlineProtocol.lock.withLock { DeadlineProtocol.requests }
        precondition(requests.count == 2, "total deadline must prevent later parts")
        let remaining = requests.map { Int($0.value(forHTTPHeaderField: "X-Kikishima-Timeout-Ms")!)! }
        precondition(remaining[0] <= 260 && remaining[1] < remaining[0] - 100, "part two must inherit remaining budget")
        DeadlineProtocol.reset("cancel")
        let cancelled = client(); let cancelledResult = await run(cancelled, cancelOnDelta: true)
        precondition(cancelledResult == nil)
        await waitForNetworkStop()
        precondition(DeadlineProtocol.lock.withLock { DeadlineProtocol.stopped == 1 })
        DeadlineProtocol.reset("normal")
        let next = await run(cancelled)
        precondition(next == "translated", "new request must have its own budget after cancellation")
        print("PASS: real URLSession headers/first-text/idle watchdogs, heartbeat resistance, split total budget, network cancellation and recovery")
    }
}
