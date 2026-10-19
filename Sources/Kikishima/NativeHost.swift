// Chrome 原生消息宿主：Chrome 以「chrome-extension://<id>/」为参数启动本 app 的可执行文件，走 stdin/stdout（4 字节长度 + JSON）
// 扩展不登录、不存密钥：翻译请求在这里用 app 的会话令牌转给服务器；扩展在 YouTube 页显示字幕时用分布式通知告知 GUI 进程收起自己的字幕窗
import Foundation
import AppKit

enum NativeHost {
    /// 这一版 app 期望的扩展版本（跟 chrome-extension/manifest.json 的 version 同步；发版时需校验两者一致）
    static let expectedExtensionVersion = "1.1.5"
    /// 开发者模式装的 ID（由 chrome-extension/manifest.json 的 key 决定，固定）；商店上架后会多一个商店分配的 ID，
    /// 用 `defaults write com.kikishima.mac chromeStoreExtensionID <id>` 或下面的常量补上，两个都写进白名单
    static let devExtensionID = "gekennmfdgkinclbjmnaembfcjoepplk"
    static let storeExtensionID = ""   // 上架后填这里（也可用 UserDefaults 覆盖）
    static var extensionIDs: [String] {
        var ids = [devExtensionID, storeExtensionID, UserDefaults.standard.string(forKey: "chromeStoreExtensionID") ?? ""]
        ids = ids.filter { !$0.isEmpty }
        return Array(Set(ids)).sorted()
    }
    static let hostName = "com.kikishima.host"
    /// 扩展在网页上显示字幕（on/off）；以及扩展刚打招呼（GUI 据此显示「已连接」）
    static let notification = Notification.Name("com.kikishima.youtube")
    static let helloNotification = Notification.Name("com.kikishima.extension.hello")
    /// 保留给「app 与扩展之间的轻量信号」：目前只用来让 GUI 知道扩展装了（hello）
    static let commandNotification = Notification.Name("com.kikishima.extension.command")
    static let captionNotification = Notification.Name("com.kikishima.caption")

    /// app 启动时写宿主清单（Chrome 按名字找可执行文件路径；app 挪了位置再启动会自动更新）。只给装了的 Chromium 系浏览器写
    static func installManifest() {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let manifest: [String: Any] = [
            "name": hostName, "description": "Kikishima native messaging host", "path": exe, "type": "stdio",
            "allowed_origins": extensionIDs.map { "chrome-extension://\($0)/" },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { return }
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        for sub in ["Google/Chrome", "Google/Chrome Beta", "Google/Chrome Canary", "Chromium", "Microsoft Edge", "Arc", "BraveSoftware/Brave-Browser"] {
            let browserDir = support.appendingPathComponent(sub, isDirectory: true)
            guard FileManager.default.fileExists(atPath: browserDir.path) else { continue }
            let dir = browserDir.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent("\(hostName).json"))
        }
    }

    private static let writeLock = NSLock()
    /// 管道断了（Chrome 先走一步）写 stdout 会吃 SIGPIPE；run() 里已忽略信号，这里再吞掉写失败
    private static func emit(_ obj: [String: Any]) {
        guard let out = try? JSONSerialization.data(withJSONObject: obj) else { return }
        writeLock.lock(); defer { writeLock.unlock() }
        var n = UInt32(out.count)
        do {
            try FileHandle.standardOutput.write(contentsOf: Data(bytes: &n, count: 4))
            try FileHandle.standardOutput.write(contentsOf: out)
        } catch { /* Chrome 已断开：忽略，读循环走到 EOF 收尾 */ }
    }
    /// GUI 有没有回应过（收到任何字幕通知即算在线）：startLive 后据此停止重投
    private static let ackLock = NSLock()
    nonisolated(unsafe) private static var guiAcked = false
    private static func markAck() { ackLock.lock(); guiAcked = true; ackLock.unlock() }
    private static func isAcked() -> Bool { ackLock.lock(); defer { ackLock.unlock() }; return guiAcked }

    /// 宿主模式：读循环在后台线程（读到 EOF = Chrome 断开就退出），主线程跑 RunLoop
    /// 收 GUI 推来的实时字幕并转发给扩展 —— 网页里显示 app 听到并翻好的字幕
    static func run() {
        signal(SIGPIPE, SIG_IGN)   // Chrome 断开后写 stdout 不要直接杀进程，否则来不及告诉 GUI 停下
        DistributedNotificationCenter.default().addObserver(forName: captionNotification, object: nil, queue: .main) { n in
            markAck()
            var msg: [String: Any] = ["type": "caption"]
            for (k, v) in (n.userInfo ?? [:]) { if let key = k as? String { msg[key] = v } }
            emit(msg)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let input = FileHandle.standardInput
            let defaults = UserDefaults.standard
            while true {
                let header = input.readData(ofLength: 4)
                guard header.count == 4 else { break }
                let len = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }   // Chrome 用本机字节序
                guard len > 0, len < 4_000_000 else { break }
                let body = input.readData(ofLength: Int(len))
                guard body.count == Int(len), let msg = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { continue }
                let reply = handle(msg, defaults: defaults)
                if !reply.isEmpty { emit(reply) }   // 空 = 异步路径，结果稍后自己 emit
            }
            // Chrome 断开：告诉 GUI 停掉为网页开的实时字幕，再退出
            DistributedNotificationCenter.default().postNotificationName(commandNotification, object: nil, userInfo: ["cmd": "stopLive"], deliverImmediately: true)
            Thread.sleep(forTimeInterval: 0.2)
            exit(0)
        }
        RunLoop.current.run()
    }

    /// GUI 没在跑就后台启动它（不抢焦点）：扩展要实时字幕时需要 GUI 干活
    @discardableResult
    private static func ensureAppRunning() -> Bool {
        let bid = Bundle.main.bundleIdentifier ?? "com.kikishima.mac"
        if !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty { return true }
        var url = Bundle.main.bundleURL
        while url.pathExtension != "app", url.pathComponents.count > 2 { url = url.deletingLastPathComponent() }
        guard url.pathExtension == "app" else { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.arguments = ["--background"]   // 被扩展拉起来时不弹主窗口、不抢焦点
        NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
        return false
    }

    private static func handle(_ msg: [String: Any], defaults d: UserDefaults) -> [String: Any] {
        let id: Any = msg["id"] ?? NSNull()
        let type = msg["type"] as? String ?? ""
        let token = d.string(forKey: "sessionToken") ?? ""
        let target = d.string(forKey: "targetLang") ?? "Simplified Chinese"
        switch type {
        case "hello":
            d.set(Date().timeIntervalSince1970, forKey: "chromeHostLastHello")   // 备用：GUI 下次启动也能看到
            if let v = msg["extVersion"] as? String { d.set(v, forKey: "chromeExtVersion") }
            // 宿主是独立进程，GUI 不会自动看到它写的 UserDefaults：用分布式通知实时告诉 GUI
            DistributedNotificationCenter.default().postNotificationName(helloNotification, object: nil, userInfo: nil, deliverImmediately: true)
            return [
                "id": id, "ok": true, "signedIn": !token.isEmpty, "target": target,
                "display": d.string(forKey: "captionDisplay") ?? "both",
                "ui": d.string(forKey: "uiLanguage") ?? "en",
                "plan": d.string(forKey: "plan") ?? "",
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                "wantExtVersion": expectedExtensionVersion,   // 扩展据此提示用户去下载新版
                "extDownloadURL": "https://downloads.kikishima.com/extension/kikishima-chrome.zip",
            ]
        case "active":
            var info: [String: Any] = ["on": msg["on"] as? Bool ?? false]
            if let t = msg["title"] as? String { info["title"] = t }
            DistributedNotificationCenter.default().postNotificationName(notification, object: nil, userInfo: info, deliverImmediately: true)
            return ["id": id, "ok": true]
        case "translate":
            guard !token.isEmpty else { return ["id": id, "error": "unauthorized"] }
            guard let lines = msg["lines"] as? [String], !lines.isEmpty, lines.count <= 60 else { return ["id": id, "error": "bad_request"] }
            let want = (msg["target"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? target   // 扩展菜单里选的译文语言优先；合法性由服务器判
            let from = msg["from"] as? Int ?? 0   // 这一批在整份字幕里的起始行号，原样回带
            translate(lines: lines, target: want, token: token, defaults: d, id: id, from: from)   // 异步 + 流式：翻好一行推一行
            return [:]
        default:
            return ["id": id, "error": "unknown_type"]
        }
    }

    /// 一批字幕行 → 服务器 /translate/batch（SSE）。每收到一行就 emit 一条 {id, i, t}，收完 emit {id, done}
    private static func translate(lines: [String], target: String, token: String, defaults d: UserDefaults, id: Any, from: Int = 0) {
        let base = (d.string(forKey: "proxyURL") ?? "https://api.kikishima.com").trimmingCharacters(in: .init(charactersIn: "/"))
        guard let url = URL(string: base + "/translate/batch") else { emit(["id": id, "error": "bad_url"]); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 75
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["lines": lines, "target": target]
        if let g = d.string(forKey: "glossary"), !g.isEmpty {
            body["glossary"] = String(g.split(separator: "\n").prefix(80).joined(separator: "\n").prefix(4000))
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        Task {
            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                guard let http = resp as? HTTPURLResponse else { emit(["id": id, "error": "network"]); return }
                if http.statusCode != 200 {
                    var body = ""
                    for try await l in bytes.lines { body += l; if body.count > 2000 { break } }
                    let err = ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any])?["error"] as? String
                    emit(["id": id, "error": err ?? "http_\(http.statusCode)"])
                    return
                }
                var count = 0
                for try await line in bytes.lines {
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard !payload.isEmpty, let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
                    if obj["done"] as? Bool == true { break }
                    if let i = obj["i"] as? Int, let t = obj["t"] as? String {
                        count += 1
                        emit(["id": id, "i": i, "t": t, "from": from])   // 逐行推给扩展，网页那边收一条画一条
                    }
                }
                emit(["id": id, "done": true, "count": count])
            } catch {
                emit(["id": id, "error": "network"])
            }
        }
    }
}
