import Foundation

@main struct Check {
    @MainActor static func main() async throws {
        let h = Host()
        h.tick(0)
        let first = UUID()
        for _ in 0..<3 { h.handleFailure(.network("翻译请求超时"), chunk: first) }
        precondition(h.status == "running" && h.visibleStatus == nil)
        precondition(h.translationConnectivity.consecutiveFailures == 1)
        h.handleFailure(.server(500), chunk: UUID())
        precondition(h.visibleStatus == nil)
        h.handleFailure(.network("翻译连接失败"), chunk: UUID())
        precondition(h.translationOffline && h.visibleStatus?.text == "离线，正在重连")
        precondition(h.visibleStatus?.action == nil)
        h.errorBanner = CaptionBanner(text: "permission", action: .openSettings)
        precondition(h.visibleStatus?.text == "permission")
        h.errorBanner = nil
        precondition(h.visibleStatus?.text == "离线，正在重连")
        h.success()
        precondition(!h.translationOffline && h.visibleStatus == nil)
        h.handleFailure(.network("timeout"), chunk: UUID())
        h.success()
        h.handleFailure(.network("timeout"), chunk: UUID())
        h.handleFailure(.network("timeout"), chunk: UUID())
        precondition(!h.translationOffline)

        let clock = Host()
        clock.tick(0); clock.tick(14.9)
        precondition(!clock.translationOffline)
        clock.tick(15)
        precondition(clock.translationOffline)
        clock.success()
        for _ in 0..<240 { clock.tick(15) } // 60 seconds quiet: audible counter unchanged.
        precondition(!clock.translationOffline)
        clock.paused = true; clock.tick(15); clock.tick(75)
        precondition(!clock.translationOffline)
        clock.paused = false; clock.tick(75); clock.tick(89.9)
        precondition(!clock.translationOffline)
        clock.tick(90); precondition(clock.translationOffline)
        for gate in 0..<3 {
            let inactive = Host()
            inactive.tick(0)
            if gate == 0 { inactive.translationPaused = true }
            if gate == 1 { inactive.sessionToken = "" }
            if gate == 2 { inactive.running = false }
            inactive.tick(0); inactive.tick(60)
            for _ in 0..<3 { inactive.handleFailure(.network("timeout"), chunk: UUID()) }
            precondition(!inactive.translationOffline)
        }

        let rate = Host()
        rate.tick(0)
        for _ in 0..<3 { rate.handleFailure(.rateLimited, chunk: UUID()) }
        rate.tick(20)
        precondition(!rate.translationOffline && rate.translationConnectivity.consecutiveFailures == 0)
        precondition(rate.status == PlanQuotaPolicy.rateLimitMessageKey)
        rate.rateLimitedUntil = nil; rate.tick(20)
        rate.handleFailure(.network("timeout"), chunk: UUID())
        rate.handleFailure(.rateLimited, chunk: UUID())
        precondition(rate.translationConnectivity.consecutiveFailures == 1)
        // An already in-flight network failure still counts during another request's rate backoff.
        rate.handleFailure(.network("timeout"), chunk: UUID())
        precondition(!rate.translationOffline)
        rate.handleFailure(.server(502), chunk: UUID())
        precondition(rate.translationOffline)

        let exhausted = Host()
        var chunk = CaptionChunk(en: "source text")
        chunk.translationAttempts = 3
        chunk.zh = "partial"
        precondition(!chunk.translationExhausted, "third attempt in progress is not exhausted")
        exhausted.chunks = [chunk]
        exhausted.finish(nil, idx: 0)
        let row = exhausted.chunks[0]
        precondition(row.translationExhausted && row.captionFinalized && !row.translationComplete)
        precondition(row.en == "source text" && row.zh.isEmpty && row.captionTranslation.isEmpty)
        precondition(showsSource(row, DisplayState(), current: false), "source remains visible with translation-only enabled")
        precondition(exhausted.visibleStatus == nil && exhausted.errorBanner == nil)
        exhausted.translationConnectivity.failed(chunk: UUID(), enabled: true)
        exhausted.translationConnectivity.failed(chunk: UUID(), enabled: true)
        exhausted.translationConnectivity.failed(chunk: UUID(), enabled: true)
        exhausted.chunks.append(CaptionChunk(en: "next source"))
        exhausted.finish("translated", idx: 1)
        precondition(!exhausted.translationOffline && exhausted.visibleStatus == nil)
        let record = TranscriptRecovery(header: "fixture\n", incompleteLabel: "retry",
            settings: .init(targetLanguage: "English", glossary: "", model: "fixture", useProxy: true),
            rows: [.init(source: row.en, translation: row.zh, complete: recordComplete(row), marker: false, stamp: "00:00", previousSource: "")])
        let markdown = try record.markdown()
        let decoded = TranscriptRecovery.decode(markdown)!
        precondition(decoded.incompleteCount == 1)
        var retried = false, saved = false
        try await TranscriptRecoveryRun.run(record: decoded, markdown: markdown, url: URL(fileURLWithPath: "/tmp/kk033-fixture.md"),
            deadline: .now.advanced(by: .seconds(1)), translate: { row, _, _ in
                retried = true; precondition(row.source == "source text"); return "translated"
            }, replace: { _, replacement, _ in saved = true; precondition(replacement.contains("translated")) }, didSave: {})
        precondition(retried && saved)

        // Compare real current and frozen BASE handlers, including exact user text.
        for plan in ["free", "pro", "dev"] {
            for failure: TranslateFailure in [.unauthorized, .paymentRequired, .quotaExceeded, .freePoolExhausted] {
                let current = Host(), baseline = Host()
                current.plan = plan; baseline.plan = plan
                current.handleFailure(failure, chunk: UUID()); baseline.baselineFailure(failure)
                precondition(current.errorBanner == baseline.errorBanner)
                precondition(current.status == baseline.status)
                precondition(current.translationPaused == baseline.translationPaused)
                precondition(current.pauseReason == baseline.pauseReason)
                if plan == "free" { precondition(current.errorBanner?.showsStatusLine == true) }
            }
        }
        for transient in [true, false] {
            var before = TranslationConnectivityStatusBuffer()
            precondition(before.receiveStatus("message") == nil)
            precondition(before.classifyStatus(transient: transient) == (transient ? nil : "message"))
            var after = TranslationConnectivityStatusBuffer()
            precondition(after.classifyStatus(transient: transient) == nil)
            precondition(after.receiveStatus("message") == (transient ? nil : "message"))
        }
        // Producer order and stale checks exercise the real production consumer.
        for failure: TranslateFailure in [.unauthorized, .paymentRequired, .quotaExceeded, .freePoolExhausted] {
            for beforeFailure in [true, false] {
                let actual = Host(), expected = Host()
                let request = TranslationConnectivityRequest(chunk: UUID(), attempt: UUID())
                actual.activeTranslationAttempts[request.chunk] = request.attempt
                let pair = AsyncStream<TranslationCallbackEvent>.makeStream()
                let replacedAttempt = TranslationConnectivityRequest(chunk: request.chunk, attempt: UUID())
                pair.continuation.yield(.status(replacedAttempt, "replaced attempt"))
                pair.continuation.yield(.failure(replacedAttempt, .paymentRequired))
                pair.continuation.yield(.completion(replacedAttempt, { preconditionFailure("replaced attempt completed") }))
                if beforeFailure { pair.continuation.yield(.status(request, "original status")) }
                pair.continuation.yield(.failure(request, failure))
                if !beforeFailure { pair.continuation.yield(.status(request, "original status")) }
                pair.continuation.yield(.completion(request, { actual.activeTranslationAttempts[request.chunk] = nil }))
                pair.continuation.yield(.status(request, "late status"))
                pair.continuation.yield(.failure(request, .network("late failure")))
                pair.continuation.finish()
                if beforeFailure { expected.status = "original status" }
                expected.baselineFailure(failure)
                if !beforeFailure { expected.status = "original status" }
                await actual.consumeTranslationCallbacks(pair.stream, generation: 1)
                precondition(actual.status == expected.status)
                precondition(actual.visibleStatus == expected.visibleStatus)
                precondition(actual.errorBanner?.showsStatusLine == true)
                precondition(actual.translationConnectivity.consecutiveFailures == 0)
            }
        }
        for failure: TranslateFailure in [.network("timeout"), .server(500), .cancelled] {
            let host = Host()
            let request = TranslationConnectivityRequest(chunk: UUID(), attempt: UUID())
            host.activeTranslationAttempts[request.chunk] = request.attempt
            let pair = AsyncStream<TranslationCallbackEvent>.makeStream()
            pair.continuation.yield(.status(request, "transient before"))
            pair.continuation.yield(.failure(request, failure))
            pair.continuation.yield(.status(request, "transient after"))
            pair.continuation.yield(.completion(request, {
                precondition(host.status == "running" && host.visibleStatus == nil)
                host.activeTranslationAttempts[request.chunk] = nil
            }))
            pair.continuation.finish()
            await host.consumeTranslationCallbacks(pair.stream, generation: 1)
            precondition(host.status == "running")
        }
        let stale = Host()
        let staleRequest = TranslationConnectivityRequest(chunk: UUID(), attempt: UUID())
        stale.activeTranslationAttempts[staleRequest.chunk] = staleRequest.attempt
        let oldSession = AsyncStream<TranslationCallbackEvent>.makeStream()
        oldSession.continuation.yield(.status(staleRequest, "old session"))
        oldSession.continuation.yield(.failure(staleRequest, .paymentRequired))
        oldSession.continuation.yield(.completion(staleRequest, { preconditionFailure("stale completion ran") }))
        oldSession.continuation.finish()
        await stale.consumeTranslationCallbacks(oldSession.stream, generation: 0)
        precondition(stale.status == "running" && stale.visibleStatus == nil)
        // Interleaved requests retain independent value buffers.
        let interleaved = Host()
        let network = TranslationConnectivityRequest(chunk: UUID(), attempt: UUID())
        let payment = TranslationConnectivityRequest(chunk: UUID(), attempt: UUID())
        interleaved.activeTranslationAttempts[network.chunk] = network.attempt
        interleaved.activeTranslationAttempts[payment.chunk] = payment.attempt
        let mixed = AsyncStream<TranslationCallbackEvent>.makeStream()
        mixed.continuation.yield(.status(network, "transient"))
        mixed.continuation.yield(.status(payment, "需要订阅 Pro"))
        mixed.continuation.yield(.failure(network, .network("timeout")))
        mixed.continuation.yield(.failure(payment, .paymentRequired))
        mixed.continuation.finish()
        await interleaved.consumeTranslationCallbacks(mixed.stream, generation: 1)
        precondition(interleaved.status == "需要订阅 Pro")
        precondition(interleaved.visibleStatus?.action == .upgrade)
        // The same Task topology as Translator.translate -> translatePart.
        let request = TranslationConnectivityRequest(chunk: UUID(), attempt: UUID())
        let inherited = TranslationConnectivityRequest.context.withValue(request) {
            Task { await Task { TranslationConnectivityRequest.current?.chunk }.value }
        }
        let actual = await inherited.value
        precondition(actual == request.chunk && TranslationConnectivityRequest.current == nil)
        print("PASS policy and production handlers: thresholds, retries, rate limit, gates, exhaustion, record recovery, priority, BASE auth/quota parity and TaskLocal inheritance")
    }
}
