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
        for gate in [0, 2] {
            let inactive = Host()
            inactive.tick(0)
            if gate == 0 { inactive.translationPaused = true }
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
        for transient in [true, false] {
            var before = TranslationConnectivityStatusBuffer()
            precondition(before.receiveStatus("message") == nil)
            precondition(before.classifyStatus(transient: transient) == (transient ? nil : "message"))
            var after = TranslationConnectivityStatusBuffer()
            precondition(after.classifyStatus(transient: transient) == nil)
            precondition(after.receiveStatus("message") == (transient ? nil : "message"))
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
        oldSession.continuation.yield(.completion(staleRequest, { preconditionFailure("stale completion ran") }))
        oldSession.continuation.finish()
        await stale.consumeTranslationCallbacks(oldSession.stream, generation: 0)
        precondition(stale.status == "running" && stale.visibleStatus == nil)
        // The same Task topology as Translator.translate -> translatePart.
        let request = TranslationConnectivityRequest(chunk: UUID(), attempt: UUID())
        let inherited = TranslationConnectivityRequest.context.withValue(request) {
            Task { await Task { TranslationConnectivityRequest.current?.chunk }.value }
        }
        let actual = await inherited.value
        precondition(actual == request.chunk && TranslationConnectivityRequest.current == nil)
        print("PASS policy and production handlers: thresholds, retries, rate limit, gates, exhaustion, priority, transient callbacks, stale session rejection and TaskLocal inheritance")
    }
}
