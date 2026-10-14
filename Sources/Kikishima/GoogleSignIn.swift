// 「使用 Google 登录」：桌面 app 的 OAuth 2.0 PKCE 回环流程
// 1) 本机 127.0.0.1 随机端口起一个一次性 HTTP 监听（只绑回环）  2) 打开浏览器到 Google 授权页  3) Google 重定向回本机带 code
// 4) 用 code + code_verifier 换 id_token  5) id_token 交给服务器 /auth/google 换会话（服务器验签 aud）
// client_secret：Google 对「桌面应用」类型明说它不算机密（随 app 分发），但不进 Git：读 Application Support/Kikishima/google_client_secret
// 用户关掉浏览器不回来：3 分钟超时收尾，登录按钮不会永远转圈
import Foundation
import Network
import AppKit
import CryptoKit

@MainActor
final class GoogleSignIn {
    static let shared = GoogleSignIn()
    static let clientID = "947025923836-4qbcnd05od8g8glmuapl90tbkn68jpgu.apps.googleusercontent.com"
    static let timeout: TimeInterval = 180

    private var listener: NWListener?
    private var verifier = ""
    private var state = ""
    private(set) var nonce = ""
    private var port: UInt16 = 0
    private var onIDToken: ((Result<String, Error>) -> Void)?
    private var timeoutTask: Task<Void, Never>?

    static var clientSecret: String? {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kikishima/google_client_secret")
        let s = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }
    static var isConfigured: Bool { clientSecret != nil }

    enum GError: LocalizedError {
        case notConfigured, listenFailed, badCallback, tokenExchange(String), cancelled, timedOut
        var errorDescription: String? {
            switch self {
            case .notConfigured: return trAny("Google 登录尚未配置")
            case .listenFailed: return trAny("无法在本机开启回环端口")
            case .badCallback: return trAny("浏览器回调无效")
            case .tokenExchange(let m): return trAny("换取令牌失败：%@", m)
            case .cancelled: return trAny("已取消")
            case .timedOut: return trAny("登录超时，请重试")
            }
        }
    }

    /// 发起登录；成功回 id_token。上一次没完成的会先以「已取消」收尾
    func start(completion: @escaping (Result<String, Error>) -> Void) {
        guard Self.clientSecret != nil else { completion(.failure(GError.notConfigured)); return }
        cancel()
        onIDToken = completion
        verifier = Self.randomURLSafe(64)
        state = Self.randomURLSafe(24)
        nonce = Self.randomURLSafe(24)
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback   // 只监听 127.0.0.1：局域网碰不到，也不触发防火墙弹窗
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in Task { @MainActor in self?.handle(conn) } }
            l.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                if case .ready = st, let p = l.port?.rawValue {
                    Task { @MainActor in self.port = p; self.openBrowser() }
                } else if case .failed = st {
                    Task { @MainActor in self.finish(.failure(GError.listenFailed)) }
                }
            }
            l.start(queue: .main)
            listener = l
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.timeout))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(GError.timedOut))
            }
        } catch { finish(.failure(GError.listenFailed)) }
    }

    /// 取消进行中的登录：回调方能收到「已取消」并复位 UI
    func cancel() {
        if onIDToken != nil { finish(.failure(GError.cancelled)) }
        listener?.cancel(); listener = nil
    }

    private var redirectURI: String { "http://127.0.0.1:\(port)/callback" }

    private func openBrowser() {
        let challenge = Self.b64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: Self.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "nonce", value: nonce),
            .init(name: "prompt", value: "select_account"),
        ]
        NSWorkspace.shared.open(c.url!)
    }

    /// 读一次 HTTP 请求，取 code，回一页「可以关掉了」，然后换令牌
    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        let expectedState = state
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            let req = String(decoding: data ?? Data(), as: UTF8.self)
            let firstLine = req.split(separator: "\r\n").first.map(String.init) ?? ""
            let tokens = firstLine.split(separator: " ")
            let method = tokens.first.map(String.init) ?? ""
            let path = tokens.dropFirst().first.map(String.init) ?? ""
            guard method == "GET", path == "/callback" || path.hasPrefix("/callback?") else {
                conn.cancel()
                return
            }
            var code: String?, st: String?
            if let comps = URLComponents(string: "http://127.0.0.1" + path) {
                code = comps.queryItems?.first { $0.name == "code" }?.value
                st = comps.queryItems?.first { $0.name == "state" }?.value
            }
            let ok = code != nil && st == expectedState
            let body = ok
                ? "<html><body style='font-family:-apple-system;text-align:center;padding-top:80px'><h2>✓ Kikishima</h2><p>\(trAny("登录成功，可以关闭这个页面回到 app。"))</p></body></html>"
                : "<html><body style='font-family:-apple-system;text-align:center;padding-top:80px'><h2>Kikishima</h2><p>\(trAny("登录失败，请回到 app 重试。"))</p></body></html>"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
            Task { @MainActor in
                self.listener?.cancel(); self.listener = nil
                guard ok, let code else { self.finish(.failure(GError.badCallback)); return }
                await self.exchange(code: code)
            }
        }
    }

    private func exchange(code: String) async {
        guard let secret = Self.clientSecret else { finish(.failure(GError.notConfigured)); return }
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "code": code, "client_id": Self.clientID, "client_secret": secret,
            "redirect_uri": redirectURI, "grant_type": "authorization_code", "code_verifier": verifier,
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }.joined(separator: "&")
        req.httpBody = Data(form.utf8)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let idToken = json["id_token"] as? String else {
                finish(.failure(GError.tokenExchange((json["error_description"] as? String) ?? (json["error"] as? String) ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")))
                return
            }
            finish(.success(idToken))
        } catch { finish(.failure(error)) }
    }

    private func finish(_ r: Result<String, Error>) {
        timeoutTask?.cancel(); timeoutTask = nil
        listener?.cancel(); listener = nil
        let cb = onIDToken; onIDToken = nil
        cb?(r)
    }

    private static func randomURLSafe(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return b64url(Data(bytes))
    }
    private static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
