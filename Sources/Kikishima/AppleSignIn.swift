// 「通过 Apple 登录」：原生 ASAuthorization；需要 com.apple.developer.applesignin 权利 + 内嵌 Developer ID 描述文件
// 没内嵌描述文件时按钮不显示（isAvailable = false），避免点了报错
import AuthenticationServices
import AppKit
import Security

@MainActor
final class AppleSignIn: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    static let shared = AppleSignIn()
    private(set) var nonce = ""
    private var completion: ((Result<String, Error>) -> Void)?
    private var controller: ASAuthorizationController?

    /// 构建时只有描述文件带 applesignin 才会内嵌 embedded.provisionprofile
    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundlePath + "/Contents/embedded.provisionprofile")
    }

    func start(completion: @escaping (Result<String, Error>) -> Void) {
        self.completion = completion
        nonce = Self.randomNonce()
        let req = ASAuthorizationAppleIDProvider().createRequest()
        req.requestedScopes = [.email]
        req.nonce = nonce
        let c = ASAuthorizationController(authorizationRequests: [req])
        c.delegate = self
        c.presentationContextProvider = self
        controller = c
        c.performRequests()
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = cred.identityToken, let token = String(data: data, encoding: .utf8) else {
            completion?(.failure(NSError(domain: "AppleSignIn", code: 1, userInfo: [NSLocalizedDescriptionKey: trAny("Apple 没有返回身份令牌")])))
            completion = nil; return
        }
        completion?(.success(token)); completion = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        completion?(.failure(error)); completion = nil   // 取消也回调：上层据此复位「登录中」，否则按钮永远转圈
    }

    private static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
