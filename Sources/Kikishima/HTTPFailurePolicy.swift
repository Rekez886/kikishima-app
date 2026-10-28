/// Classify Worker failures without deciding whether the current plan has a quota.
enum HTTPFailurePolicy {
    enum Classification: Equatable {
        case quotaExceeded
        case rateLimited
        case temporary
    }

    static func classify(status: Int, errorCode: String?) -> Classification {
        guard status == 429 else { return .temporary }
        switch errorCode {
        case "quota_exceeded": return .quotaExceeded
        case "rate_limited": return .rateLimited
        default: return .temporary
        }
    }

    /// Quota copy is owned by CaptionState's current-plan gate.
    static func messageKey(status: Int, errorCode: String?) -> String? {
        switch classify(status: status, errorCode: errorCode) {
        case .quotaExceeded: return nil
        case .rateLimited: return "请求太频繁，稍等片刻"
        case .temporary: return "翻译服务暂时故障（%@），稍后自动恢复"
        }
    }
}
