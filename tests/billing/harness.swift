import Foundation

@MainActor func tr(_ value: String, _ args: CVarArg...) -> String { String(format: value, arguments: args) }
@MainActor final class NSWorkspace {
    static let shared = NSWorkspace()
    var urls: [URL] = []
    func open(_ url: URL) -> Bool { urls.append(url); return true }
}
enum Section { case settings }
@MainActor enum AppDelegate {
    static var opened = 0
    static func enter(section: Section) { opened += 1 }
}
@MainActor final class Transport {
    struct Pending { let request: URLRequest; let continuation: CheckedContinuation<(Data, URLResponse), Error> }
    var pending: [Pending] = []
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { pending.append(Pending(request: request, continuation: $0)) }
    }
    func reply(_ index: Int, _ object: [String: Any], status: Int = 200) {
        let p = pending[index]
        p.continuation.resume(returning: (try! JSONSerialization.data(withJSONObject: object),
            HTTPURLResponse(url: p.request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!))
    }
}
@MainActor enum Translator { static var session = Transport() }
@MainActor final class BillingHarness {
    struct AuthRequestContext { let epoch: Int; let account: String }
    var authGeneration = 0
    var accountEmail = "a@example.test"
    var sessionToken = "account-a" { didSet { authGeneration += 1; resetBillingState() } }
    var proxyURL = "https://fixture.invalid"
    var plan = "free"
    var planExpires: String?
    var upgradePollTask: Task<Void, Never>?
    var billingTask: Task<Void, Never>?
    var planRefreshTask: Task<Void, Never>?
    var planRequestGeneration = 0
    var billingBusy = false
    var billingError = ""
    var lastPlanRefresh: Date?
    var subscriptionStatus = ""
    var subscriptionExpires: Date?
    var usageTokens = 0
    var usageQuota = 0
    var quotaResetAt: Date?
    var remainingMinutes: Int? = 0
    var translationPaused = false
    var pausedAt: Date?
    enum Pause { case quota, payment, freePool, session }
    enum Action { case upgrade }
    struct Banner { var action: Action }
    var errorBanner: Banner?
    var pauseReason: Pause?
    func sessionExpired() { sessionToken = ""; plan = "" }
    func unpause() { translationPaused = false }
    func retryFailedChunks() {}
    // EXTRACTED_METHODS
}
