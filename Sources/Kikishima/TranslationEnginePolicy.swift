/// Rules for choosing the translation engine in the local-first build.
/// Pure value logic so the UI and tests can share it.
enum TranslationEnginePolicy {
    enum Engine: String, CaseIterable {
        case apple    // Apple Translation framework, on-device, zero download
        case mlx      // optional TranslateGemma via MLX, high quality but slower
        case openAI   // direct to OpenAI with the user's own key
    }

    static let defaultEngine: Engine = .apple
    static let storageKey = "translationEngine"

    /// OpenAI keys are long; very short strings are almost always a paste error.
    static let minimumKeyLength = 20

    static func normalizedKey(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.lowercased().hasPrefix("bearer ") {
            key = String(key.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
        }
        return key
    }

    static func isValidKey(_ raw: String) -> Bool {
        let key = normalizedKey(raw)
        return key.count >= minimumKeyLength && !key.contains(where: { $0.isWhitespace })
    }

    /// Never show the whole key back to the user or write it into logs.
    static func maskedHint(_ key: String) -> String {
        let key = normalizedKey(key)
        guard !key.isEmpty else { return "" }
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        return "\(key.prefix(3))…\(key.suffix(4))"
    }

    static func requiresKey(_ engine: Engine) -> Bool { engine == .openAI }
    static func isLocal(_ engine: Engine) -> Bool { engine == .apple || engine == .mlx }
    static func requiresDownload(_ engine: Engine) -> Bool { engine == .mlx }
    static func pausesForAccountQuota(_ engine: Engine) -> Bool { false }

    /// TranslateGemma expects ISO 639-1 codes or regional variants.
    static func mlxLanguageCode(_ code: String) -> String {
        switch code {
        case "zh-Hans", "zh_CN", "zh-CN": return "zh"
        case "zh-Hant", "zh_TW", "zh-TW", "zh_HK", "zh-HK": return "zh-TW"
        case "pt", "pt-PT": return "pt"
        default: return code.split(whereSeparator: { $0 == "_" || $0 == "-" }).first.map(String.init) ?? code
        }
    }

    /// Migrate the old proxy/BYO boolean. Existing BYO users keep their key path;
    /// everyone else moves to the on-device default.
    static func migratedEngine(useProxy: Bool?, hasKey: Bool) -> Engine {
        if useProxy == false, hasKey { return .openAI }
        return .apple
    }
}
