import Foundation

@main struct Checks {
    @MainActor static func main() async throws {
        // A non-cooperative ASR operation must not hold the stop deadline open.
        var finishASR: CheckedContinuation<Void, Never>?
        var events: [String] = []
        var pending = 7
        var inflight = 3
        let began = ContinuousClock.now
        await CaptionFinalization.drain(deadline: .now.advanced(by: .milliseconds(300)), asrBudget: .milliseconds(25),
            finishASR: { await withCheckedContinuation { finishASR = $0 } },
            freezeASR: { events.append("freeze") },
            flushTail: { allowed in precondition(allowed); events.append("flush"); pending += 1 },
            pumpTranslations: {
                precondition(events == ["freeze", "flush"])
                if inflight > 0 { inflight -= 1 }
                while inflight < 3, pending > 0 { pending -= 1; inflight += 1 }
                return inflight > 0
            })
        precondition(began.duration(to: .now) < .seconds(1))
        precondition(finishASR != nil && events == ["freeze", "flush"])
        finishASR?.resume()
        // Timeout with a permanently occupied translation slot is bounded too.
        let timeoutStart = ContinuousClock.now
        await CaptionFinalization.drain(deadline: .now.advanced(by: .milliseconds(80)),
            finishASR: {}, freezeASR: {}, flushTail: { precondition($0) }, pumpTranslations: { true })
        precondition(timeoutStart.duration(to: .now) < .milliseconds(400))

        // More than three tail chunks must drain, rather than stranding the queue.
        pending = 5; inflight = 3
        await CaptionFinalization.drain(deadline: .now.advanced(by: .seconds(1)),
            finishASR: {}, freezeASR: {}, flushTail: { _ in pending += 1 }, pumpTranslations: {
                if inflight > 0 { inflight -= 1 }
                while inflight < 3, pending > 0 { pending -= 1; inflight += 1 }
                return inflight > 0
            })
        precondition(pending == 0 && inflight == 0)

        // Parent cancellation releases the gate even if a translation callback never arrives.
        var late: (@MainActor (String?) -> Void)?
        let cancelled = Task { await CaptionDeadline.value(until: .now.advanced(by: .seconds(30))) { late = $0 } }
        while late == nil { await Task.yield() }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        precondition(cancelledResult == nil)
        late?("too late")
        late?("duplicate")
        let immediate: String? = await CaptionDeadline.value(until: .now.advanced(by: .seconds(1))) { done in
            done("first"); done("second")
        }
        precondition(immediate == "first")

        var cancelledASR: CheckedContinuation<Void, Never>?
        var mayTranslate = true
        var pumpCount = 0
        let cancelledStop = Task {
            await CaptionFinalization.drain(deadline: .now.advanced(by: .seconds(30)),
                finishASR: { await withCheckedContinuation { cancelledASR = $0 } },
                freezeASR: {}, flushTail: { mayTranslate = $0 },
                pumpTranslations: { pumpCount += 1; return true })
        }
        while cancelledASR == nil { await Task.yield() }
        cancelledStop.cancel()
        await cancelledStop.value
        precondition(!mayTranslate && pumpCount == 0)
        cancelledASR?.resume()

        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KK_TEST_TMP_ROOT"]!)
        let file = dir.appendingPathComponent("record.md")
        let writer = TranscriptWriter()
        let settings = TranscriptRecovery.Settings(targetLanguage: "Japanese", glossary: "Kiki → キキ", model: "fixture", useProxy: false)
        let record = TranscriptRecovery(header: "# Fixture\n\n", incompleteLabel: "Unfinished",
            settings: settings, rows: [
                .init(source: "Done", translation: "完成", complete: true, marker: false, stamp: "00:00:01", previousSource: ""),
                .init(source: "Changed my mind <!-- -->", translation: "partial", complete: false, marker: false, stamp: "00:00:02", previousSource: "Done"),
                .init(source: "Pause", translation: "", complete: false, marker: true, stamp: "", previousSource: ""),
                .init(source: "Last sentence", translation: "", complete: false, marker: false, stamp: "00:00:03", previousSource: "")
            ])
        let original = try record.markdown()
        precondition(TranscriptRecovery.decode(original)?.incompleteCount == 2)
        precondition(TranscriptRecovery.decode(original)?.rows[1].translation == "partial")
        precondition(TranscriptRecovery.decode(original.replacingOccurrences(of: "# Fixture", with: "# Edited")) == nil)
        precondition(TranscriptRecovery.decode("legacy text") == nil)
        precondition(TranscriptRecovery.decode(original + "external edit") == nil)
        var future = record; future.version = 2
        let futureMarkdown = try future.markdown()
        precondition(TranscriptRecovery.decode(futureMarkdown) == nil)
        precondition(TranscriptRecovery.visibleText(original) == record.body)
        try await writer.write(markdown: original, to: file)
        var calls: [String] = [], saves = 0
        let replace: (String, String, URL) async throws -> Void = { expected, replacement, url in
            try await writer.replace(expected: expected, with: replacement, at: url)
        }
        try await TranscriptRecoveryRun.run(record: record, markdown: original, url: file,
            deadline: .now.advanced(by: .seconds(1)), translate: { row, settings, _ in
                precondition(settings.targetLanguage == "Japanese" && settings.glossary == "Kiki → キキ")
                calls.append(row.source)
                if calls.count == 1 { precondition(row.previousSource == "Done"); return "補訳" }
                return nil
            }, replace: replace, didSave: { saves += 1 })
        let partiallyRecovered = try String(contentsOf: file, encoding: .utf8)
        let partial = TranscriptRecovery.decode(partiallyRecovered)!
        precondition(saves == 1 && calls.count == 2 && partial.incompleteCount == 1)
        precondition(partial.rows[0].translation == "完成" && partial.rows[1].translation == "補訳")
        precondition(partial.rows[1].stamp == "00:00:02" && partial.rows[3].previousSource.isEmpty)
        try await TranscriptRecoveryRun.run(record: partial, markdown: partiallyRecovered, url: file,
            deadline: .now.advanced(by: .seconds(1)), translate: { _, _, _ in "最終文" }, replace: replace, didSave: {})
        let complete = try String(contentsOf: file, encoding: .utf8)
        precondition(TranscriptRecovery.decode(complete) == nil && !complete.contains("kikishima-recovery"))
        precondition(complete.contains("最終文") && complete.contains("完成"))

        // Retry saves cannot overwrite an external edit or resurrect renamed/deleted files.
        for action in 0..<3 {
            try await writer.write(markdown: original, to: file)
            let moved = dir.appendingPathComponent("moved-\(action).md")
            var mutations = 0
            do {
                try await TranscriptRecoveryRun.run(record: record, markdown: original, url: file,
                    deadline: .now.advanced(by: .seconds(1)), translate: { _, _, _ in
                        mutations += 1
                        if mutations == 1 {
                            if action == 0 { try! "external".write(to: file, atomically: true, encoding: .utf8) }
                            else if action == 1 { try! FileManager.default.moveItem(at: file, to: moved) }
                            else { try! FileManager.default.removeItem(at: file) } // This fixture created it.
                        }
                        return "late"
                    }, replace: replace, didSave: { preconditionFailure("must not save") })
                preconditionFailure("must refuse")
            } catch {}
            if action == 0 {
                let edited = try String(contentsOf: file, encoding: .utf8)
                precondition(edited == "external")
            }
            else { precondition(!FileManager.default.fileExists(atPath: file.path)) }
        }

        try await writer.write(markdown: original, to: file)
        var lateRetry: (@MainActor (String?) -> Void)?
        let retry = Task {
            try await TranscriptRecoveryRun.run(record: record, markdown: original, url: file,
                deadline: .now.advanced(by: .seconds(30)), translate: { _, _, deadline in
                    await CaptionDeadline.value(until: deadline) { lateRetry = $0 }
                }, replace: replace, didSave: { preconditionFailure("cancelled write") })
        }
        while lateRetry == nil { await Task.yield() }
        retry.cancel()
        try await retry.value
        lateRetry?("late callback")
        let unchanged = try String(contentsOf: file, encoding: .utf8)
        precondition(unchanged == original)
        let compensatingWrite = Task { @MainActor in
            do {
                try TranscriptWriter.replaceSynchronously(expected: original, with: "wrong", at: file)
                preconditionFailure("new writes must respect cancellation")
            } catch {}
            try TranscriptWriter.replaceSynchronously(expected: original, with: "compensated", at: file,
                                                       checkingCancellation: false)
            do {
                try TranscriptWriter.replaceSynchronously(expected: original, with: "wrong", at: file,
                                                           checkingCancellation: false)
                preconditionFailure("compensation must still check current content")
            } catch {}
        }
        compensatingWrite.cancel()
        try await compensatingWrite.value
        let compensated = try String(contentsOf: file, encoding: .utf8)
        precondition(compensated == "compensated")

        // Cancellation between rows must flush completed translations instead
        // of dropping the whole batch.
        try await writer.write(markdown: original, to: file)
        var cancelledBatchWait: (@MainActor (String?) -> Void)?
        var cancelledBatchSaves = 0
        let cancelledBatch = Task {
            try await TranscriptRecoveryRun.run(record: record, markdown: original, url: file,
                deadline: .now.advanced(by: .seconds(30)), translate: { row, _, deadline in
                    if row.source.hasPrefix("Changed") { return "early" }
                    _ = await CaptionDeadline.value(until: deadline) { cancelledBatchWait = $0 }
                    return nil
                }, replace: { _, _, _ in
                    preconditionFailure("cancelled batch must use the forced flush")
                }, flush: { expected, replacement, url in
                    try TranscriptWriter.replaceSynchronously(
                        expected: expected, with: replacement, at: url,
                        checkingCancellation: false
                    )
                }, didSave: { cancelledBatchSaves += 1 })
        }
        while cancelledBatchWait == nil { await Task.yield() }
        cancelledBatch.cancel()
        cancelledBatchWait?(nil)
        try await cancelledBatch.value
        let cancelledBatchMarkdown = try String(contentsOf: file, encoding: .utf8)
        let cancelledBatchRecord = TranscriptRecovery.decode(cancelledBatchMarkdown)
        precondition(cancelledBatchRecord?.incompleteCount == 1)
        precondition(cancelledBatchRecord?.rows[1].translation == "early")
        precondition(cancelledBatchSaves == 1)

        print("PASS: bounded ASR/translation drain, cancellation, late callbacks, queued tails, persistent recovery and stale-file refusal")
    }
}
