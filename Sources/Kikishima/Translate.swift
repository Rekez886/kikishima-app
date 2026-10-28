// 翻译层：OpenAI chat completions 流式，逻辑移植自验证过的网页版
import Foundation
import Security

/// Only the bounded numeric preflight snapshot is retained. Unknown response
/// fields are never copied into diagnostics. Worker terminal logs use the same ID.
struct WorkerPreflightTiming: Codable, Sendable {
    struct Stages: Codable, Sendable {
        var auth: Int?
        var plan: Int?
        var planVersion: Int?
        var planLoad: Int?
        var quota: Int?
        var rate: Int?
        var claim: Int?
        var reserve: Int?
        var upstreamHeaders: Int?
        var settle: Int?
        var d1: Int?
        var values: [Int] { [auth, plan, planVersion, planLoad, quota, rate, claim, reserve, upstreamHeaders, settle, d1].compactMap { $0 } }
    }
    var v: Int
    var id: Int
    var route: Int
    var elapsedMs: Int
    var d1Calls: Int
    var cache: Int?
    var attempts: Int
    var fallback: Int
    var stages: Stages

    static func parse(_ header: String?) -> Self? {
        guard let header, header.utf8.count <= 2048,
              let row = try? JSONDecoder().decode(Self.self, from: Data(header.utf8)),
              row.v == 1, (0..<281_474_976_710_656).contains(row.id),
              (0...1).contains(row.route), (0...10_000).contains(row.d1Calls),
              (0...8).contains(row.attempts), (0...row.attempts).contains(row.fallback),
              row.cache.map({ (0...2).contains($0) }) ?? true,
              ([row.elapsedMs] + row.stages.values).allSatisfy({ (0...86_400_000).contains($0) }) else { return nil }
        return row
    }
}

/// Numeric-only optional task diagnostics. Dates in URLSessionTaskMetrics are
/// deliberately ignored; all durations use monotonic process uptime.
struct TranslationNetworkTiming: Sendable {
    var subrequestIndex: Int
    var subrequestCount: Int
    var retry: Int
    var connectionReused: Bool?
    var transactionCount: Int?
    var requestToHeadersMs: Int?
    var headersToFirstMs: Int?
    var headersToEndMs: Int?
    var requestToEndMs: Int?
    var worker: WorkerPreflightTiming?

    static func sample(index: Int, count: Int, retry: Int, started: TimeInterval,
                       headers: TimeInterval?, first: TimeInterval?, ended: TimeInterval,
                       reused: Bool?, transactions: Int?) -> Self {
        func ms(_ delta: TimeInterval) -> Int { Int((max(0, delta) * 1000).rounded()) }
        return Self(subrequestIndex: index, subrequestCount: count, retry: retry,
                    connectionReused: reused, transactionCount: transactions,
                    requestToHeadersMs: headers.map { ms($0 - started) },
                    headersToFirstMs: headers.flatMap { h in first.map { ms($0 - h) } },
                    headersToEndMs: headers.map { ms(ended - $0) }, requestToEndMs: ms(ended - started))
    }
}

private final class TranslationNetworkProbe: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let started = ProcessInfo.processInfo.systemUptime
    private var headers: TimeInterval?
    private var first: TimeInterval?
    private var ended: TimeInterval?
    private var metricsArrived = false
    private var emitted = false
    private var row: TranslationNetworkTiming
    private let report: @Sendable (TranslationNetworkTiming) -> Void

    init(index: Int, count: Int, retry: Int, report: @escaping @Sendable (TranslationNetworkTiming) -> Void) {
        row = TranslationNetworkTiming(subrequestIndex: index, subrequestCount: count, retry: retry)
        self.report = report
    }
    func receivedHeaders(_ response: URLResponse? = nil) {
        lock.withLock {
            headers = ProcessInfo.processInfo.systemUptime
            row.worker = WorkerPreflightTiming.parse((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-kikishima-timing"))
        }
    }
    func receivedDelta(_ text: String) {
        lock.withLock {
            if first == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                first = ProcessInfo.processInfo.systemUptime
            }
        }
    }
    func finish() {
        lock.withLock { ended = ProcessInfo.processInfo.systemUptime }
        emitIfReady()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.withLock {
            row.connectionReused = metrics.transactionMetrics.last?.isReusedConnection
            row.transactionCount = metrics.transactionMetrics.count
            metricsArrived = true
        }
        emitIfReady()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Failed tasks may have no transaction metrics. Retain an unknown reuse
        // value rather than dropping the subrequest's monotonic measurements.
        lock.withLock { metricsArrived = true }
        emitIfReady()
    }
    private func emitIfReady() {
        let sample: TranslationNetworkTiming? = lock.withLock {
            guard !emitted, metricsArrived, let ended else { return nil }
            emitted = true
            let worker = row.worker
            row = .sample(index: row.subrequestIndex, count: row.subrequestCount, retry: row.retry,
                          started: started, headers: headers, first: first, ended: ended,
                          reused: row.connectionReused, transactions: row.transactionCount)
            row.worker = worker
            return row
        }
        if let sample { report(sample) }
    }
}

// API key 存储 uses the same build isolation as account sessions. Only the installed
// release bundle may migrate or clean up its legacy plaintext key.
enum Keychain {
    struct LegacyFile {
        var read: () -> String
        var remove: () -> Void
        static let production = LegacyFile(
            read: { (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "" },
            remove: { try? FileManager.default.removeItem(at: fileURL) }
        )
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Kikishima", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("openai.key")
        // 改名迁移：老目录 MeetingCaptions 里的 key 搬过来一次
        let old = base.appendingPathComponent("MeetingCaptions/openai.key")
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.copyItem(at: old, to: url)
        }
        return url
    }

    static func loadKey(scope: CredentialScope = .current, keychain: CredentialKeychain = .system,
                        legacy: LegacyFile = .production) -> String {
        guard scope != .disabled else { return "" }
        let stored = KeychainStore.loadKey(scope: scope, keychain: keychain)
        guard scope == .production else { return stored }
        if !stored.isEmpty {
            legacy.remove()
            return stored
        }
        let file = legacy.read().trimmingCharacters(in: .whitespacesAndNewlines)
        if !file.isEmpty, KeychainStore.saveKey(file, scope: scope, keychain: keychain) {
            legacy.remove()
        }
        return file
    }

    static func saveKey(_ key: String, scope: CredentialScope = .current, keychain: CredentialKeychain = .system,
                        legacy: LegacyFile = .production) {
        guard scope != .disabled else { return }
        if KeychainStore.saveKey(key, scope: scope, keychain: keychain), scope == .production {
            legacy.remove()
        }
    }

    static func deleteKey(scope: CredentialScope = .current, keychain: CredentialKeychain = .system,
                          legacy: LegacyFile = .production) {
        guard scope != .disabled else { return }
        _ = KeychainStore.deleteKey(scope: scope, keychain: keychain)
        if scope == .production { legacy.remove() }
    }
}

enum KeychainStore {
    private static let account = "openai-key"

    @discardableResult
    static func saveKey(_ key: String, scope: CredentialScope = .current,
                        keychain: CredentialKeychain = .system) -> Bool {
        guard scope != .disabled else { return false }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return keychain.write(scope.keychainService, account, trimmed)
    }

    static func loadKey(scope: CredentialScope = .current, keychain: CredentialKeychain = .system) -> String {
        guard scope != .disabled else { return "" }
        return keychain.read(scope.keychainService, account)
    }

    @discardableResult
    static func deleteKey(scope: CredentialScope = .current, keychain: CredentialKeychain = .system) -> Bool {
        guard scope != .disabled else { return false }
        return keychain.write(scope.keychainService, account, "")
    }
}

/// 翻译失败的分类：状态机据此决定「停翻并提示」还是「退避重试」
enum TranslateFailure: Error, Sendable {
    case unauthorized          // 401：Key 无效
    case rateLimited           // 429：请求太频繁
    case localUnavailable(String) // 本机翻译不可用（语言包未装 / 模型未下载）
    case network(String)       // 断网/超时：可重试
    case server(Int)           // 5xx / 其他
    case cancelled
}

struct TranslationTimeouts: Sendable {
    var total: TimeInterval = 30
    var headers: TimeInterval = 8
    var firstText: TimeInterval = 12
    var idle: TimeInterval = 8
}

/// Each network attempt shares its group's monotonic deadline. Cancelling the
/// Swift task alone after AsyncBytes headers is insufficient: cancel its data task too.
private final class TranslationAttemptDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private let deadline: TimeInterval
    private var timer: DispatchWorkItem?
    private var alarmID = UUID()
    private var ended = false
    private var expired = false
    private var cancelled = false
    private var network: URLSessionTask?
    private var cancelTask: (() -> Void)?
    init(deadline: TimeInterval) { self.deadline = deadline }
    var timedOut: Bool { lock.withLock { expired } }
    func attach(_ task: Task<Void, Never>) {
        let stop = lock.withLock { cancelTask = { task.cancel() }; return cancelled }
        if stop { task.cancel() }
    }
    func attachNetwork(_ task: URLSessionTask) {
        let stop = lock.withLock { network = task; return cancelled || ended }
        if stop { task.cancel() }
    }
    func arm(_ duration: TimeInterval) {
        lock.lock()
        guard !ended, !cancelled else { lock.unlock(); return }
        alarmID = UUID()
        let ticket = alarmID
        timer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.expire(ticket) }
        timer = work
        let delay = max(0, min(duration, deadline - ProcessInfo.processInfo.systemUptime))
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }
    private func expire(_ ticket: UUID) {
        lock.lock()
        guard !ended, !cancelled, alarmID == ticket else { lock.unlock(); return }
        expired = true; cancelled = true
        let stop = cancelTask, task = network
        lock.unlock()
        task?.cancel(); stop?()
    }
    func cancel() {
        let pair = lock.withLock { cancelled = true; timer?.cancel(); return (network, cancelTask) }
        pair.0?.cancel(); pair.1?()
    }
    func close() {
        let task = lock.withLock { ended = true; timer?.cancel(); cancelTask = nil; return network }
        task?.cancel()
    }
}

final class Translator {
    private let transport: URLSession
    private let timeouts: TranslationTimeouts
    init(transport: URLSession = Translator.session, timeouts: TranslationTimeouts = .init()) {
        self.transport = transport
        self.timeouts = timeouts
    }
    var model: String = "gpt-5.6-luna"
    var glossary: String = ""           // 术语表原文（每行一条，「→」指定译法）
    var targetLanguage: String = "Simplified Chinese"   // 目标语言（英文名，进 prompt）
    var sourceLanguage: String = "en"   // 会议原声语言（locale 或语言码）
    var onStatus: (@Sendable (String) -> Void)?          // 人话提示回调（菜单状态行）
    var onFailure: (@Sendable (TranslateFailure) -> Void)?
    // 引擎模式：apple = Apple 本机翻译（默认）；mlx = 可选高质量本机模型；openAI = 用户自备 Key。
    var engine: TranslationEnginePolicy.Engine = .apple
    private var useReasoningEffort = true
    private var usePriority = true      // OpenAI priority 通道（不支持时自动降级）
    private var useTemperature = true   // 低温度压创造性（不支持时自动降级）

    /// URLSession inactivity safety net; the monotonic group/phase watchdog is the hard limit.
    static let requestTimeout: TimeInterval = 15
    /// 专用会话：连接复用 + 超时；不用 shared 以免被别处请求拖慢
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = requestTimeout
        cfg.timeoutIntervalForResource = requestTimeout * 2
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    private let tasksLock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var groups: [UUID: Task<Void, Never>] = [:]
    private var deadlines: [UUID: TranslationAttemptDeadline] = [:]
    private final class TaskBox { var task: Task<Void, Never>? }
    private func track(_ id: UUID, _ t: Task<Void, Never>, _ deadline: TranslationAttemptDeadline) { tasksLock.lock(); tasks[id] = t; deadlines[id] = deadline; tasksLock.unlock() }
    /// 只在登记的还是「自己」时才注销：BYO 400 降级会用同一 id 重发，外层结束不能把内层的登记抹掉
    private func untrack(_ id: UUID, _ me: Task<Void, Never>?) {
        tasksLock.lock(); if let me, tasks[id] == me { tasks[id] = nil; deadlines[id] = nil }; tasksLock.unlock()
    }
    /// 停止字幕时取消所有在途请求（否则 onDone 迟到会把 inflight 计数和 UI 弄乱）
    func cancel(_ id: UUID) {
        tasksLock.lock(); let task = tasks.removeValue(forKey: id); let group = groups.removeValue(forKey: id); let deadline = deadlines.removeValue(forKey: id)
        // Mark the group before another part can register under this lock.
        group?.cancel()
        tasksLock.unlock()
        deadline?.cancel(); task?.cancel()
    }
    func cancelAll() {
        tasksLock.lock(); let all = tasks; let allGroups = groups; let allDeadlines = deadlines; tasks = [:]; groups = [:]; deadlines = [:]
        allGroups.values.forEach { $0.cancel() }
        tasksLock.unlock()
        allDeadlines.values.forEach { $0.cancel() }; all.values.forEach { $0.cancel() }
    }
    private func trackGroup(_ id: UUID, _ task: Task<Void, Never>) { tasksLock.lock(); groups[id] = task; tasksLock.unlock() }
    private func finishGroup(_ id: UUID, _ me: Task<Void, Never>?) { tasksLock.lock(); if let me, groups[id] == me { groups[id] = nil }; tasksLock.unlock() }

    private func report(_ code: Int?, _ error: Error?) {
        if let error, error is CancellationError || (error as? URLError)?.code == .cancelled { onFailure?(.cancelled); return }
        let msg: String
        if let code {
            switch code {
            case 401: msg = trAny("API key 无效或已吊销 · 打开设置检查"); onFailure?(.unauthorized)
            case 429: msg = trAny("请求太频繁，稍等片刻"); onFailure?(.rateLimited)
            case 500...599: msg = trAny("翻译服务暂时故障（%@），稍后自动恢复", code); onFailure?(.server(code))
            default: msg = trAny("翻译API错误 %@", code); onFailure?(.server(code))
            }
        } else if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost: msg = trAny("无网络 · 字幕仅转写，恢复联网后自动继续翻译")
            case .timedOut: msg = trAny("翻译请求超时")
            default: msg = trAny("网络错误：%@", e.localizedDescription)
            }
            onFailure?(.network(msg))
        } else {
            msg = trAny("翻译失败：%@", error?.localizedDescription ?? trAny("未知错误"))
            onFailure?(.network(msg))
        }
        onStatus?(msg)
    }

    // prompt 模板改英文：目标语言任意时最中立稳定
    private func systemPrompt(previous: String) -> String {
        var p = """
        You are a real-time meeting caption translation engine. Translate the given speech fragment into \(targetLanguage). Natural, conversational, concise. Output ONLY the translation.
        Hard rules:
        - Translate exactly what is in the fragment. NEVER add, complete, guess or embellish. If the fragment is cut off mid-sentence, the translation must be cut off at the same point.
        - Do not carry over content from the previous segment; it is context for word sense only.
        - Never output brackets, quotes or placeholder symbols that are not in the source.
        - Keep proper nouns (company, product and personal names) in their original form.
        - The source comes from speech recognition and may contain mis-heard words; translate the most plausible intended meaning, but do not invent new topics.
        """
        let lines = glossary.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !lines.isEmpty {
            var keep: [String] = [], map: [String] = []
            for l in lines.prefix(80) {
                if l.contains("→") || l.contains("->") {
                    map.append(l.replacingOccurrences(of: "->", with: "→"))
                } else { keep.append(l) }
            }
            p += "\nGlossary (speech recognition often misspells these; if a word in the source sounds like one of them, use the correct term):"
            if !keep.isEmpty { p += "\nKeep exactly as written, never translate: " + keep.joined(separator: ", ") }
            if !map.isEmpty { p += "\nTranslate exactly as specified: " + map.joined(separator: "; ") }
        }
        if !previous.isEmpty {
            p += "\nPrevious fragment (context only, already translated, do NOT translate or repeat it): " + TranslationText.context(previous)
        }
        return p
    }

    func reset() {}

    /// 预热连接（TLS+HTTP/2 握手提前做掉，首句翻译省 300-500ms）。
    /// Apple / MLX 本机引擎没有网络握手；OpenAI 打一次 1 token 的 completions。
    func warmup() {
        guard engine == .openAI else { return }
        let key = Keychain.loadKey()
        guard !key.isEmpty else { return }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["model": model, "messages": [["role": "user", "content": "hi"]], "max_completion_tokens": 1]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        transport.dataTask(with: req).resume()
    }

    /// Freeze source-order context at the caller. Every retry and bounded subrequest
    /// uses that context, never the last network request to happen to execute.
    func translate(id: UUID = UUID(), chunk: String, previous: String = "",
                   timing: (@Sendable (TranslationNetworkTiming) -> Void)? = nil,
                   onDelta: @escaping @Sendable (String) -> Void,
                   onDone: @escaping @Sendable (String?) -> Void) {
        let parts = TranslationText.parts(TranslationText.acknowledgement(chunk) ?? chunk)
        guard !parts.isEmpty else { onDone(nil); return }
        let deadline = ProcessInfo.processInfo.systemUptime + timeouts.total
        let groupBox = TaskBox()
        let group = Task {
            defer { self.finishGroup(id, groupBox.task) }
            var finished = "", context = previous
            var timingIndex = 0
            for part in parts {
                guard !Task.isCancelled else { onDone(nil); return }
                timingIndex += 1
                let prefix = finished
                let result: String? = await withCheckedContinuation { continuation in
                    self.translatePart(deadline: deadline, id: id, chunk: part, previous: context, timing: timing, timingIndex: timingIndex, timingCount: parts.count, cancelled: { groupBox.task?.isCancelled ?? false }, onDelta: { live in
                        onDelta(prefix.isEmpty ? live : prefix + " " + live)
                    }, onDone: { continuation.resume(returning: $0) })
                }
                guard !Task.isCancelled, let result else { onDone(nil); return }
                finished += (finished.isEmpty ? "" : " ") + result
                context = part
            }
            onDone(finished)
        }
        groupBox.task = group
        trackGroup(id, group)
    }

    private func translatePart(deadline: TimeInterval, id: UUID, chunk: String, previous: String,
                   timing: (@Sendable (TranslationNetworkTiming) -> Void)? = nil,
                   timingIndex: Int = 1, timingCount: Int = 1, timingRetry: Int = 0, cancelled: @escaping @Sendable () -> Bool,
                   onDelta: @escaping @Sendable (String) -> Void,
                   onDone: @escaping @Sendable (String?) -> Void) {
        guard !cancelled() else { onDone(nil); return }
        guard deadline > ProcessInfo.processInfo.systemUptime else { report(nil, URLError(.timedOut)); onDone(nil); return }
        switch engine {
        case .apple:
            translateViaApple(deadline: deadline, id: id, chunk: chunk, onDelta: onDelta, onDone: onDone)
            return
        case .mlx:
            translateViaMLX(deadline: deadline, id: id, chunk: chunk, previous: previous, onDelta: onDelta, onDone: onDone)
            return
        case .openAI:
            break
        }
        let key = Keychain.loadKey()
        guard !key.isEmpty else { onDone(nil); return }
        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt(previous: previous)]
        ]
        messages.append(["role": "user", "content": chunk])
        var body: [String: Any] = ["model": model, "stream": true, "messages": messages,
                                   "max_completion_tokens": 400]   // 防退化输入引发复读刷屏
        if useReasoningEffort { body["reasoning_effort"] = "none" }
        if usePriority { body["service_tier"] = "priority" }
        if useTemperature { body["temperature"] = 0.2 }

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = min(Self.requestTimeout, max(0.001, deadline - ProcessInfo.processInfo.systemUptime))

        let box = TaskBox()
        let watchdog = TranslationAttemptDeadline(deadline: deadline)
        watchdog.arm(timeouts.headers)
        let t = Task {
            defer { watchdog.close(); self.untrack(id, box.task) }
            let probe: TranslationNetworkProbe?
            if let timing {
                probe = TranslationNetworkProbe(index: timingIndex, count: timingCount, retry: timingRetry, report: timing)
            } else { probe = nil }
            defer { probe?.finish() }
            do {
                let (bytes, resp): (URLSession.AsyncBytes, URLResponse)
                if let probe {
                    (bytes, resp) = try await self.transport.bytes(for: req, delegate: probe)
                    probe.receivedHeaders()
                } else {
                    (bytes, resp) = try await self.transport.bytes(for: req)
                }
                watchdog.attachNetwork(bytes.task)
                watchdog.arm(self.timeouts.firstText)
                if Task.isCancelled { if watchdog.timedOut { self.report(nil, URLError(.timedOut)) }; onDone(nil); return }
                if let http = resp as? HTTPURLResponse, http.statusCode == 400 {
                    bytes.task.cancel()
                    // 参数不被接受时逐个降级重试：先 priority 再 reasoning_effort
                    if self.usePriority { self.usePriority = false; self.translatePart(deadline: deadline, id: id, chunk: chunk, previous: previous, timing: timing, timingIndex: timingIndex, timingCount: timingCount, timingRetry: timingRetry + 1, cancelled: cancelled, onDelta: onDelta, onDone: onDone); return }
                    if self.useTemperature { self.useTemperature = false; self.translatePart(deadline: deadline, id: id, chunk: chunk, previous: previous, timing: timing, timingIndex: timingIndex, timingCount: timingCount, timingRetry: timingRetry + 1, cancelled: cancelled, onDelta: onDelta, onDone: onDone); return }
                    if self.useReasoningEffort { self.useReasoningEffort = false; self.translatePart(deadline: deadline, id: id, chunk: chunk, previous: previous, timing: timing, timingIndex: timingIndex, timingCount: timingCount, timingRetry: timingRetry + 1, cancelled: cancelled, onDelta: onDelta, onDone: onDone); return }
                }
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    self.report((resp as? HTTPURLResponse)?.statusCode, nil)
                    onDone(nil); return
                }
                var stream = TranslationStream()
                for try await line in bytes.lines {
                    if Task.isCancelled { if watchdog.timedOut { self.report(nil, URLError(.timedOut)) }; onDone(nil); return }
                    let before = stream.text
                    stream.accept(line)
                    if stream.text != before {
                        if !stream.text.dropFirst(before.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { watchdog.arm(self.timeouts.idle) }
                        probe?.receivedDelta(stream.text); onDelta(stream.text)
                    }
                    if stream.done { break }
                }
                if Task.isCancelled { if watchdog.timedOut { self.report(nil, URLError(.timedOut)) }; onDone(nil); return }
                if stream.completed == nil {
                    self.onFailure?(.network(trAny("部分字幕未翻译完成，可重试")))
                }
                onDone(stream.completed)
            } catch {
                self.report(nil, watchdog.timedOut ? URLError(.timedOut) : error)
                onDone(nil)
            }
        }
        box.task = t
        watchdog.attach(t)
        track(id, t, watchdog)
        if cancelled() { watchdog.cancel() }
    }
}

extension Translator {
    /// Apple Translation framework: on-device, no network. The framework returns
    /// the whole translated string, so emit one delta and finish.
    private func translateViaApple(deadline: TimeInterval, id: UUID, chunk: String,
                                   onDelta: @escaping @Sendable (String) -> Void,
                                   onDone: @escaping @Sendable (String?) -> Void) {
        let timeout = max(0.5, min(5, deadline - ProcessInfo.processInfo.systemUptime))
        let box = TaskBox()
        let watchdog = TranslationAttemptDeadline(deadline: deadline)
        let t = Task {
            defer { watchdog.close(); self.untrack(id, box.task) }
            guard !Task.isCancelled else { onDone(nil); return }
            let result = await LocalTranslator.shared.translate(chunk, timeout: timeout)
            guard !Task.isCancelled else { onDone(nil); return }
            if let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onDelta(result)
                onDone(result)
            } else {
                self.onFailure?(.localUnavailable(trAny("本机翻译暂不可用，请下载语言包或换一个引擎")))
                onDone(nil)
            }
        }
        box.task = t
        watchdog.attach(t)
        track(id, t, watchdog)
    }

    /// Optional high-quality local model. Implemented by the MLX bridge; until
    /// then this reports a clear local-unavailable error instead of dropping text.
    private func translateViaMLX(deadline: TimeInterval, id: UUID, chunk: String, previous: String,
                                 onDelta: @escaping @Sendable (String) -> Void,
                                 onDone: @escaping @Sendable (String?) -> Void) {
        let timeout = max(1, min(25, deadline - ProcessInfo.processInfo.systemUptime))
        let source = sourceLanguage
        let target = targetLanguage
        let box = TaskBox()
        let watchdog = TranslationAttemptDeadline(deadline: deadline)
        let t = Task {
            defer { watchdog.close(); self.untrack(id, box.task) }
            do {
                let result = try await MLXModelController.shared.translate(
                    chunk, source: source, target: target, timeout: timeout)
                guard !Task.isCancelled else { onDone(nil); return }
                let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    self.onFailure?(.localUnavailable(trAny("本机高质量模型没有返回译文")))
                    onDone(nil)
                    return
                }
                onDelta(text)
                onDone(text)
            } catch let failure as TranslateFailure {
                self.onFailure?(failure)
                onDone(nil)
            } catch {
                self.onFailure?(.localUnavailable(trAny("本机高质量模型暂时不可用")))
                onDone(nil)
            }
        }
        box.task = t
        watchdog.attach(t)
        track(id, t, watchdog)
    }
}

// ==== 切块 ====

private let cjkSentenceEnd: Set<Character> = ["。", "！", "？", "．"]
private let cjkClauseEnd: Set<Character> = ["、", "，", "；", "：", "」", "』", "）"]

/// 文本是否主要是无空格脚本（中/日/韩）：切块规则不能靠空格与英文标点
func isSpacelessScript(_ s: String) -> Bool {
    var cjk = 0, letters = 0
    for u in s.unicodeScalars {
        switch u.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xAC00...0xD7AF, 0xFF66...0xFF9F: cjk += 1
        case 0x41...0x5A, 0x61...0x7A: letters += 1
        default: break
        }
    }
    return cjk > 0 && cjk >= letters
}

/// 切块长度档：短 = 逗号就切、出字最快但意思碎；中（默认）= 句子基本完整再切；长 = 更连贯，每句晚出 1～2 秒
/// 默认使用「中」档，兼顾句意完整性与翻译延迟
struct ChunkTuning: Sendable {
    var clauseMinPendingLatin: Int    // 拉丁文字：未翻部分超过多少字符才允许在逗号/分号处切
    var clauseMinLenLatin: Int        // 且切出来的块至少多少字符
    var clauseMinPendingCJK: Int      // 中日韩：同上
    var clauseMinLenCJK: Int
    var hardCutCJK: Int               // 无标点硬切：中日韩按字数
    var hardCutLatin: Int             // 无标点硬切：拉丁按字符数
    var timeout: TimeInterval         // 无标点等多久后按时间切
    var timeoutMinCJK: Int            // 超时切至少要有多少字
    var timeoutMinLatin: Int
    var minSentenceCJK: Int           // 句号到了但整句太短：先不切，等下一句一起（超时仍会切）
    var minSentenceLatin: Int

    static let short = ChunkTuning(clauseMinPendingLatin: 20, clauseMinLenLatin: 8, clauseMinPendingCJK: 12, clauseMinLenCJK: 6,
                                   hardCutCJK: 24, hardCutLatin: 32, timeout: 1.2, timeoutMinCJK: 10, timeoutMinLatin: 18,
                                   minSentenceCJK: 0, minSentenceLatin: 0)
    // 中档阈值介于短档与长档之间，平衡连贯性和出字速度
    static let medium = ChunkTuning(clauseMinPendingLatin: 30, clauseMinLenLatin: 14, clauseMinPendingCJK: 18, clauseMinLenCJK: 9,
                                    hardCutCJK: 32, hardCutLatin: 48, timeout: 1.3, timeoutMinCJK: 12, timeoutMinLatin: 22,
                                    minSentenceCJK: 6, minSentenceLatin: 14)
    static let long = ChunkTuning(clauseMinPendingLatin: 70, clauseMinLenLatin: 36, clauseMinPendingCJK: 40, clauseMinLenCJK: 20,
                                  hardCutCJK: 56, hardCutLatin: 96, timeout: 2.0, timeoutMinCJK: 18, timeoutMinLatin: 40,
                                  minSentenceCJK: 14, minSentenceLatin: 36)
    static func named(_ s: String) -> ChunkTuning { s == "short" ? .short : s == "long" ? .long : .medium }
}

/// 切块位置：优先句尾；未翻部分较长时退而取最后一个逗号/分句处。英文句末需后跟空格；全角标点不需要
func sentenceCutoff(_ text: String, doneChars: Int, tuning: ChunkTuning = .medium) -> Int {
    let chars = Array(text)
    var last = 0
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c == "…" {
            // 省略号：后面是空格/结尾（英文）或非 ASCII（中日文）都算句末
            if i + 1 >= chars.count || chars[i + 1] == " " || !chars[i + 1].isASCII { last = i + 1 }
        } else if c == "." || c == "!" || c == "?" {
            var j = i + 1
            while j < chars.count, "\"')]".contains(chars[j]) { j += 1 }
            if j >= chars.count || chars[j] == " " { last = j }
        } else if cjkSentenceEnd.contains(c) {
            last = i + 1
        }
        i += 1
    }
    if last > doneChars { return last }
    let pendingCount = chars.count - doneChars
    if pendingCount > tuning.clauseMinPendingLatin {
        var lc = -1
        var k = doneChars
        while k < chars.count - 1 {
            if ",;:—".contains(chars[k]) && chars[k + 1] == " " { lc = k + 2 - doneChars }
            k += 1
        }
        if lc > tuning.clauseMinLenLatin { return doneChars + lc }
    }
    if pendingCount > tuning.clauseMinPendingCJK {
        // 中/日文分句号：不需要后跟空格；至少凑够字数再切，避免碎块
        var lc = -1
        var k = doneChars
        while k < chars.count {
            if cjkClauseEnd.contains(chars[k]) { lc = k + 1 - doneChars }
            k += 1
        }
        if lc > tuning.clauseMinLenCJK { return doneChars + lc }
    }
    return last
}
