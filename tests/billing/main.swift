import Foundation

@main struct BillingTests {
    @MainActor static func pump() async { for _ in 0..<30 { await Task.yield() } }
    @MainActor static func waitRequests(_ count: Int) async {
        for _ in 0..<500 { if Translator.session.pending.count >= count { return }; await Task.yield() }
        fatalError("billing request missing")
    }
    @MainActor static func main() async {
        let s = BillingHarness()
        s.openUpgrade(); s.openUpgrade()
        await waitRequests(1)
        let req = Translator.session.pending[0].request
        precondition(req.url?.path == "/billing/checkout" && req.httpMethod == "POST")
        precondition(req.value(forHTTPHeaderField: "Authorization") == "Bearer account-a")
        precondition(String(data: req.httpBody!, encoding: .utf8) == "{}")
        precondition(Translator.session.pending.count == 1, "duplicate checkout suppressed")
        Translator.session.reply(0, ["url": "https://buy.polar.sh/test"]); await pump()
        precondition(NSWorkspace.shared.urls.count == 1 && s.plan == "free" && !s.billingBusy)
        s.resetBillingState()

        s.openSubscriptionManagement(); await waitRequests(2)
        precondition(Translator.session.pending[1].request.url?.path == "/billing/portal")
        s.sessionToken = "account-b"; s.accountEmail = "b@example.test"
        Translator.session.reply(1, ["url": "https://polar.sh/other"]); await pump()
        precondition(NSWorkspace.shared.urls.count == 1, "old account cannot open portal")

        s.openUpgrade(); await waitRequests(3)
        Translator.session.reply(2, ["url": "https://evil.test"]); await pump()
        precondition(NSWorkspace.shared.urls.count == 1 && !s.billingError.isEmpty)
        precondition(AppDelegate.opened > 0, "failure visible in settings")
        for raw in ["http://polar.sh", "https://user@polar.sh", "https://polar.sh.evil.test", "javascript:alert(1)"] {
            precondition(BillingPolicy.browserURL(raw) == nil)
        }

        s.refreshPlan(); await waitRequests(4)
        s.refreshPlan(); await pump()
        precondition(Translator.session.pending.count == 4, "ordinary polls coalesce instead of starving slow requests")
        s.restorePurchases(); await waitRequests(5)
        precondition(Translator.session.pending[4].request.url?.path == "/billing/refresh")
        Translator.session.reply(4, ["plan": "pro", "email": "changed@example.test", "tokens": 12, "quota": NSNull()])
        await pump()
        precondition(s.plan == "pro" && !s.billingBusy && s.accountEmail == "changed@example.test")
        Translator.session.reply(3, ["plan": "free"]); await pump()
        precondition(s.plan == "pro", "old me cannot undo restore")

        s.restorePurchases(); await waitRequests(6)
        s.sessionToken = "account-c"; s.accountEmail = "c@example.test"; s.plan = "free"
        Translator.session.reply(5, ["plan": "pro"]); await pump()
        precondition(s.plan == "free" && !s.billingBusy)
        s.restorePurchases(); await waitRequests(7)
        s.sessionToken = "account-d"
        Translator.session.reply(6, [:], status: 401); await pump()
        precondition(s.sessionToken == "account-d", "late 401 cannot sign out new account")

        s.plan = "pro"; s.restorePurchases(); await waitRequests(8)
        Translator.session.reply(7, ["error": "billing_not_linked"], status: 409); await pump()
        precondition(s.plan == "pro" && !s.billingBusy && !s.billingError.isEmpty)
        s.planExpires = "2099-01-01"; s.subscriptionStatus = "active"
        s.restorePurchases(); await waitRequests(9)
        Translator.session.reply(8, ["plan": "free", "tokens": 2, "quota": 240000]); await pump()
        precondition(s.plan == "free" && s.planExpires == nil && s.subscriptionStatus.isEmpty)
        s.sessionToken = ""
        s.openUpgrade(); await pump()
        precondition(Translator.session.pending.count == 9, "signed-out checkout cannot start")
        s.sessionToken = "account-e"; s.accountEmail = "e@example.test"
        s.refreshPlan(); await waitRequests(10)
        s.openUpgrade(); await waitRequests(11)
        Translator.session.reply(9, ["plan": "free", "email": "canonical@example.test"]); await pump()
        Translator.session.reply(10, ["url": "https://buy.polar.sh/current"]); await pump()
        precondition(!s.billingBusy && NSWorkspace.shared.urls.last?.path == "/current",
                     "earlier /me cannot strand a newer billing operation")
        s.resetBillingState()
        print("PASS actual app billing: endpoints, identity, double click, unsafe URLs, account switch, stale refresh/401, restore and downgrade")
    }
}
