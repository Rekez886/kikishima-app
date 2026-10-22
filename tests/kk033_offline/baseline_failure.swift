// Frozen from KK-034 74f405c; unchanged-error oracle only.
    private func handleFailure(_ f: TranslateFailure) {
        guard running || starting || finishingCaptions else { return }
        switch f {
        case .unauthorized:
            sessionExpired()
        case .paymentRequired:
            pause(.payment)
            errorBanner = CaptionBanner(text: tr("需要订阅 Pro 才能继续翻译"), action: .upgrade)
        case .quotaExceeded:
            guard PlanQuotaPolicy.shouldPauseForQuota(plan: plan),
                  let key = PlanQuotaPolicy.quotaMessageKey(plan: plan) else { return }
            pause(.quota)
            errorBanner = CaptionBanner(text: tr(key, resetText), action: .upgrade)
            status = tr("额度已用完 · 仅转写")
        case .freePoolExhausted:
            guard PlanQuotaPolicy.shouldPauseForQuota(plan: plan) else { return }
            pause(.freePool)
            errorBanner = CaptionBanner(text: tr("今日免费额度已被用完，明天再来，或升级 Pro 不受影响"), action: .upgrade)
            status = tr("免费额度今日用尽 · 仅转写")
        case .rateLimited:
            rateLimitedUntil = Date().addingTimeInterval(4)
            status = tr(PlanQuotaPolicy.rateLimitMessageKey)
            let gen = sessionGen
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) { [weak self] in
                guard let self, self.sessionGen == gen else { return }
                self.retryFailedChunks()
            }
        case .network(let msg):
            status = msg
        case .server(let code):
            status = tr("翻译服务错误 %@，稍后自动重试", code)
        case .cancelled:
            break
        }
    }
