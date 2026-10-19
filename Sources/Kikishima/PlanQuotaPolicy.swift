enum PlanQuotaPolicy {
    static func showsQuota(plan: String) -> Bool { plan == "free" }
    static func remainingMinutes(plan: String, tokens: Int, quota: Int) -> Int? {
        guard showsQuota(plan: plan), quota > 0 else { return nil }
        return max(0, (quota - tokens) / 4000)
    }
    static func shouldPauseForQuota(plan: String) -> Bool { showsQuota(plan: plan) }
    static func quotaMessageKey(plan: String) -> String? {
        showsQuota(plan: plan) ? "本周免费额度已用完，%@ 重置" : nil
    }
    static let rateLimitMessageKey = "请求太频繁，稍等片刻"
}
