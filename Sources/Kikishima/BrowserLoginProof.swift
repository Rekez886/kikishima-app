import Foundation
import CryptoKit
import Security

/// Each browser login keeps its verifier in memory. Only the S256 challenge
/// goes into the URL; the verifier travels directly to the handoff endpoint.
struct BrowserLoginProof {
    let state: String
    let verifier: String
    var challenge: String { Self.challenge(for: verifier) }

    static func challenge(for verifier: String) -> String {
        encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func generate() -> BrowserLoginProof? {
        var bytes = [UInt8](repeating: 0, count: 64)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return .init(state: encode(Data(bytes.prefix(32))), verifier: encode(Data(bytes.suffix(32))))
    }

    private static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
