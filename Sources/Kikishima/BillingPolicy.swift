import Foundation

enum BillingPolicy {
    static func browserURL(_ raw: String?) -> URL? {
        guard let raw, raw.count <= 4096, let url = URL(string: raw),
              url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host,
              ["polar.sh", "buy.polar.sh", "sandbox.polar.sh", "sandbox-buy.polar.sh"].contains(host) else { return nil }
        return url
    }

    @MainActor static func errorText(_ code: String) -> String {
        switch code {
        case "billing_not_configured": return tr("订阅服务尚未配置，请稍后重试")
        case "billing_not_linked": return tr("未找到与当前账号绑定的购买，请确认账号或联系支持")
        case "rate_limited": return tr("操作太频繁，请稍后重试")
        default: return tr("无法连接订阅服务，请稍后重试")
        }
    }
}
