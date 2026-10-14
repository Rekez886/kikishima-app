// 翻译层：OpenAI chat completions 流式，逻辑移植自验证过的网页版
import Foundation
import Security

// API key 存储。开发期用 app 私有文件（0600）：自签名证书不被钥匙串 ACL 信任，每次重编译都会重新要密码。
// 正式 Developer ID 签名后切回钥匙串（保留 KeychainStore 实现）。
enum Keychain {
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

    static func loadKey() -> String {
        let stored = KeychainStore.loadKey()
        if !stored.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return stored
        }
        let file = (try? String(contentsOf: fileURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !file.isEmpty, KeychainStore.saveKey(file) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        return file
    }

    static func saveKey(_ key: String) {
        if KeychainStore.saveKey(key) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}

enum KeychainStore {
    private static let service = "Kikishima"
    private static let account = "openai-key"

    @discardableResult
    static func saveKey(_ key: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var add = query
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        return status == errSecSuccess || status == errSecDuplicateItem
    }

    static func loadKey() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// 翻译失败的分类：状态机据此决定「停翻并提示」还是「退避重试」
enum TranslateFailure: Sendable {
    case unauthorized          // 401：会话过期/无效 → 清会话，要求重新登录
    case paymentRequired       // 402：需要订阅
    case quotaExceeded         // 429 quota_exceeded：本期额度用完
    case rateLimited           // 429 rate_limited：瞬时限频，退避
    case freePoolExhausted     // 503 free_pool_exhausted：免费池今日用尽
    case network(String)       // 断网/超时：可重试
    case server(Int)           // 5xx / 其他
    case cancelled
}

final class Translator {
    var model: String = "gpt-5.6-luna"
    var glossary: String = ""           // 术语表原文（每行一条，「→」指定译法）
    var targetLanguage: String = "Simplified Chinese"   // 目标语言（英文名，进 prompt）
    var onStatus: (@Sendable (String) -> Void)?          // 人话提示回调（菜单状态行）
    var onFailure: (@Sendable (TranslateFailure) -> Void)?
    // 引擎模式：proxy = 走自家 Cloudflare 代理（订阅，prompt 在服务器组装）；byo = 用户自备 OpenAI key
    var useProxy = true
    var proxyURL = "https://api.kikishima.com"
    var sessionToken = ""
    private var useReasoningEffort = true
    private var usePriority = true      // OpenAI priority 通道（不支持时自动降级）
    private var useTemperature = true   // 低温度压创造性（不支持时自动降级）

    /// 一次请求 15 秒硬超时：会议里一句话等不了更久；挂起的请求会堵住 inflight 名额
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
    private final class TaskBox { var task: Task<Void, Never>? }
    private func track(_ id: UUID, _ t: Task<Void, Never>) { tasksLock.lock(); tasks[id] = t; tasksLock.unlock() }
    /// 只在登记的还是「自己」时才注销：BYO 400 降级会用同一 id 重发，外层结束不能把内层的登记抹掉
    private func untrack(_ id: UUID, _ me: Task<Void, Never>?) {
        tasksLock.lock(); if let me, tasks[id] == me { tasks[id] = nil }; tasksLock.unlock()
    }
    /// 停止字幕时取消所有在途请求（否则 onDone 迟到会把 inflight 计数和 UI 弄乱）
    func cancel(_ id: UUID) {
        tasksLock.lock(); let task = tasks.removeValue(forKey: id); let group = groups.removeValue(forKey: id); tasksLock.unlock()
        group?.cancel(); task?.cancel()
    }
    func cancelAll() {
        tasksLock.lock(); let all = tasks; let allGroups = groups; tasks = [:]; groups = [:]; tasksLock.unlock()
        allGroups.values.forEach { $0.cancel() }; all.values.forEach { $0.cancel() }
    }
    private func trackGroup(_ id: UUID, _ task: Task<Void, Never>) { tasksLock.lock(); groups[id] = task; tasksLock.unlock() }
    private func finishGroup(_ id: UUID, _ me: Task<Void, Never>?) { tasksLock.lock(); if let me, groups[id] == me { groups[id] = nil }; tasksLock.unlock() }

    private func report(_ code: Int?, _ error: Error?) {
        if let error, error is CancellationError || (error as? URLError)?.code == .cancelled { onFailure?(.cancelled); return }
        let msg: String
        if let code {
            switch code {
            case 401: msg = trAny("API key 无效或已吊销 — 打开设置检查"); onFailure?(.unauthorized)
            case 429: msg = trAny("翻译服务繁忙或额度不足，稍后再试"); onFailure?(.rateLimited)
            case 500...599: msg = trAny("翻译服务暂时故障（%@），稍后自动恢复", code); onFailure?(.server(code))
            default: msg = trAny("翻译API错误 %@", code); onFailure?(.server(code))
            }
        } else if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost: msg = trAny("无网络 — 字幕仅转写，恢复联网后自动继续翻译")
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

    /// 预热连接（TLS+HTTP/2 握手提前做掉，首句翻译省 300-500ms）
    /// 代理模式：打 /health（免鉴权、最轻）；BYO：打一次 1 token 的 completions
    func warmup() {
        if useProxy {
            guard let url = URL(string: proxyURL.trimmingCharacters(in: .init(charactersIn: "/")) + "/health") else { return }
            Self.session.dataTask(with: URLRequest(url: url)).resume()
            return
        }
        let key = Keychain.loadKey()
        guard !key.isEmpty else { return }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["model": model, "messages": [["role": "user", "content": "hi"]], "max_completion_tokens": 1]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        Self.session.dataTask(with: req).resume()
    }

    /// Freeze source-order context at the caller. Every retry and bounded subrequest
    /// uses that context, never the last network request to happen to execute.
    func translate(id: UUID = UUID(), chunk: String, previous: String = "",
                   onDelta: @escaping @Sendable (String) -> Void,
                   onDone: @escaping @Sendable (String?) -> Void) {
        let parts = TranslationText.parts(TranslationText.acknowledgement(chunk) ?? chunk)
        guard !parts.isEmpty else { onDone(nil); return }
        let groupBox = TaskBox()
        let group = Task {
            defer { self.finishGroup(id, groupBox.task) }
            var finished = "", context = previous
            for part in parts {
                guard !Task.isCancelled else { onDone(nil); return }
                let prefix = finished
                let result: String? = await withCheckedContinuation { continuation in
                    self.translatePart(id: id, chunk: part, previous: context, cancelled: { groupBox.task?.isCancelled ?? false }, onDelta: { live in
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

    private func translatePart(id: UUID, chunk: String, previous: String, cancelled: @escaping @Sendable () -> Bool,
                   onDelta: @escaping @Sendable (String) -> Void,
                   onDone: @escaping @Sendable (String?) -> Void) {
        if useProxy { translateViaProxy(id: id, chunk: chunk, previous: previous, cancelled: cancelled, onDelta: onDelta, onDone: onDone); return }
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
        req.timeoutInterval = Self.requestTimeout

        let box = TaskBox()
        let t = Task {
            defer { self.untrack(id, box.task) }
            do {
                let (bytes, resp) = try await Self.session.bytes(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 400 {
                    // 参数不被接受时逐个降级重试：先 priority 再 reasoning_effort
                    if self.usePriority { self.usePriority = false; self.translatePart(id: id, chunk: chunk, previous: previous, cancelled: cancelled, onDelta: onDelta, onDone: onDone); return }
                    if self.useTemperature { self.useTemperature = false; self.translatePart(id: id, chunk: chunk, previous: previous, cancelled: cancelled, onDelta: onDelta, onDone: onDone); return }
                    if self.useReasoningEffort { self.useReasoningEffort = false; self.translatePart(id: id, chunk: chunk, previous: previous, cancelled: cancelled, onDelta: onDelta, onDone: onDone); return }
                }
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    self.report((resp as? HTTPURLResponse)?.statusCode, nil)
                    onDone(nil); return
                }
                var stream = TranslationStream()
                for try await line in bytes.lines {
                    if Task.isCancelled { onDone(nil); return }
                    let before = stream.text
                    stream.accept(line)
                    if stream.text != before { onDelta(stream.text) }
                    if stream.done { break }
                }
                if Task.isCancelled { onDone(nil); return }
                if stream.completed == nil {
                    self.onFailure?(.network(trAny("部分字幕未翻译完成，可重试")))
                }
                onDone(stream.completed)
            } catch {
                self.report(nil, error)
                onDone(nil)
            }
        }
        box.task = t
        track(id, t)
        if cancelled() { t.cancel() }
    }
}

extension Translator {
    /// 代理模式：只发片段+上下文+目标语+术语表，服务器组 prompt、注入 key、记账；回的是同样的 OpenAI SSE
    func translateViaProxy(id: UUID, chunk: String, previous: String, cancelled: @escaping @Sendable () -> Bool,
                           onDelta: @escaping @Sendable (String) -> Void,
                           onDone: @escaping @Sendable (String?) -> Void) {
        guard !sessionToken.isEmpty, let url = URL(string: proxyURL.trimmingCharacters(in: .init(charactersIn: "/")) + "/translate") else {
            onFailure?(.unauthorized); onDone(nil); return
        }
        var body: [String: Any] = ["chunk": chunk, "target": targetLanguage]
        if !previous.isEmpty { body["previous"] = TranslationText.context(previous) }
        if !glossary.isEmpty { body["glossary"] = String(glossary.split(separator: "\n").prefix(80).joined(separator: "\n").prefix(4000)) }   // 与服务器同一上限：80 条 / 4000 字
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = Self.requestTimeout
        let box = TaskBox()
        let t = Task {
            defer { self.untrack(id, box.task) }
            do {
                let (bytes, resp) = try await Self.session.bytes(for: req)
                guard let http = resp as? HTTPURLResponse else { onDone(nil); return }
                if http.statusCode != 200 {
                    // 非 200：读完正文取服务器的 error 代号，再分类
                    var raw = ""
                    for try await line in bytes.lines { raw += line; if raw.count > 8192 { break } }   // 网关/WAF 的大 HTML 错误页不无限累积
                    let code = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])?["error"] as? String ?? ""
                    switch (http.statusCode, code) {
                    case (401, _): onStatus?(trAny("登录已过期，请重新登录")); onFailure?(.unauthorized)
                    case (402, _): onStatus?(trAny("需要订阅 Pro")); onFailure?(.paymentRequired)
                    case (429, "rate_limited"): onStatus?(trAny("请求太频繁，稍等片刻")); onFailure?(.rateLimited)
                    case (429, _): onStatus?(trAny("本期翻译额度已用完")); onFailure?(.quotaExceeded)
                    case (503, "free_pool_exhausted"): onStatus?(trAny("今日免费额度已用完")); onFailure?(.freePoolExhausted)
                    default: onStatus?(trAny("翻译服务错误 %@", http.statusCode)); onFailure?(.server(http.statusCode))
                    }
                    onDone(nil); return
                }
                var stream = TranslationStream()
                for try await line in bytes.lines {
                    if Task.isCancelled { onDone(nil); return }
                    let before = stream.text
                    stream.accept(line)
                    if stream.text != before { onDelta(stream.text) }
                    if stream.done { break }
                }
                if Task.isCancelled { onDone(nil); return }
                if stream.completed == nil {
                    self.onFailure?(.network(trAny("部分字幕未翻译完成，可重试")))
                }
                onDone(stream.completed)
            } catch {
                self.report(nil, error)
                onDone(nil)
            }
        }
        box.task = t
        track(id, t)
        if cancelled() { t.cancel() }
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
