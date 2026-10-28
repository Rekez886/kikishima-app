import Foundation

private enum InjectedFailure: Error {
    case secondTrashMove
}

private final class TrashState: @unchecked Sendable {
    var calls = 0
}

private final class BatchTrashState: @unchecked Sendable {
    var attempted: [String] = []
}

private func emptyContent() -> MeetingSummaryContent {
    MeetingSummaryContent(
        overview: [],
        currentState: [],
        decisions: [],
        actionItems: [],
        personalItems: [],
        openQuestions: []
    )
}

@main
struct MeetingSummaryStoreTest {
    static func main() async throws {
        let fileManager = FileManager.default
        guard let temporaryPath = ProcessInfo.processInfo.environment["TMPDIR"] else {
            preconditionFailure("Run through the test wrapper to isolate temporary files")
        }
        let temporaryRoot = URL(fileURLWithPath: temporaryPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        precondition(temporaryRoot.lastPathComponent.hasPrefix("kikishima-test."))
        precondition(["/tmp", "/private/tmp"].contains(temporaryRoot.deletingLastPathComponent().path))
        let directory = temporaryRoot
            .appendingPathComponent("kikishima-summary-store-\(UUID().uuidString)", isDirectory: true)
        let trashDirectory = directory.appendingPathComponent("Trash", isDirectory: true)
        let transcript = directory.appendingPathComponent("Meeting.md")

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let writer = TranscriptWriter(fileManager: fileManager)
        try await writer.write(markdown: "abc", to: transcript)
        let transcriptText = try String(contentsOf: transcript, encoding: .utf8)
        precondition(transcriptText == "abc")

        let fingerprint = try MeetingSummaryStore.sha256(of: transcript)
        precondition(fingerprint == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        let document = MeetingSummaryDocument(
            recordID: "record-1",
            transcriptFileName: transcript.lastPathComponent,
            content: emptyContent(),
            sourceIndex: ["segment-1": SummarySourceSegment(id: "segment-1", startSeconds: 0, text: "Hello")],
            processedThrough: "segment-1",
            schemaVersion: 1,
            promptVersion: "2026-08-31-v1",
            sourceFingerprint: fingerprint,
            updatedAt: Date(timeIntervalSince1970: 1_788_134_400),
            isFinal: true,
            status: .finished
        )

        let store = MeetingSummaryStore(fileManager: fileManager, trashItem: { _ in
            preconditionFailure("Ambiguous associations must fail before any trash operation")
        })
        try await store.save(document, beside: transcript)
        let loadedDocument = try await store.load(for: transcript)
        precondition(loadedDocument == document)

        // Sidecars are decoded from disk, so reject record IDs that could
        // escape the summary directory when building their filename.
        let unsafeTranscript = directory.appendingPathComponent("Unsafe.md")
        try await writer.write(markdown: "unsafe", to: unsafeTranscript)
        var unsafeDocument = document
        unsafeDocument.recordID = "../escaped"
        do {
            try await store.save(unsafeDocument, beside: unsafeTranscript)
            preconditionFailure("Path-traversal record IDs must be rejected")
        } catch MeetingRecordOperationError.invalidRecordID("../escaped") {
            // Expected.
        }

        // A case-only rename is a same-file move on the default macOS volume.
        let caseSource = directory.appendingPathComponent("Case.md")
        let caseDestination = directory.appendingPathComponent("case.md")
        try await writer.write(markdown: "case", to: caseSource)
        var caseDocument = document
        caseDocument.recordID = "record-case"
        caseDocument.transcriptFileName = caseSource.lastPathComponent
        caseDocument.sourceFingerprint = try MeetingSummaryStore.sha256(of: caseSource)
        try await store.save(caseDocument, beside: caseSource)
        try await store.renameRecord(from: caseSource, to: caseDestination)
        precondition(fileManager.fileExists(atPath: caseDestination.path))
        let caseLoaded = try await store.load(for: caseDestination)
        precondition(caseLoaded?.recordID == "record-case")
        precondition(caseLoaded?.transcriptFileName == caseDestination.lastPathComponent)
        try await store.discardSummary(recordID: "record-case", beside: caseDestination)
        let discardedCase = try await store.load(for: caseDestination)
        precondition(discardedCase == nil, "Discarding a summary removes its sidecar")
        precondition(!fileManager.fileExists(
            atPath: directory.appendingPathComponent(".kikishima-summaries/record-case.json").path))

        var searchableDocument = document
        searchableDocument.content.decisions = [
            SummaryBlock(id: "decision-1", text: "Launch on Friday", sourceRefs: [SummarySourceRef(segmentID: "segment-1", startSeconds: 0)])
        ]
        precondition(
            MeetingSummarySearch.matches(
                query: "Friday",
                title: "Meeting",
                transcriptText: "Nothing matching here",
                summary: searchableDocument
            ),
            "A transcript must match when the query appears only in summary text"
        )

        let interruptedTranscript = directory.appendingPathComponent("Interrupted.md")
        try await writer.write(markdown: "interrupted", to: interruptedTranscript)
        var interruptedDocument = document
        interruptedDocument.recordID = "record-interrupted"
        interruptedDocument.transcriptFileName = interruptedTranscript.lastPathComponent
        interruptedDocument.isFinal = false
        interruptedDocument.status = .active
        interruptedDocument.sourceFingerprint = nil
        try await store.save(interruptedDocument, beside: interruptedTranscript)
        let loadedInterrupted = try await store.load(for: interruptedTranscript)
        precondition(loadedInterrupted?.status == .interrupted, "An unfinished persisted summary remains visible as interrupted")

        var failedDocument = interruptedDocument
        failedDocument.status = .failed
        try await store.save(failedDocument, beside: interruptedTranscript)
        let loadedFailed = try await store.load(for: interruptedTranscript)
        precondition(loadedFailed?.status == .failed, "A failed summary remains visible as failed")

        let recoveryURL = directory.appendingPathComponent("Recovery.md")
        try await writer.write(markdown: "source + unfinished", to: recoveryURL)
        var recoveryDocument = failedDocument
        recoveryDocument.recordID = "record-recovery"
        try await store.save(recoveryDocument, beside: recoveryURL)
        try await store.replaceTranscript(expected: "source + unfinished", with: "source + translation", at: recoveryURL)
        let recoveredSummary = try await store.load(for: recoveryURL)
        let recoveryFingerprint = try MeetingSummaryStore.sha256(of: recoveryURL)
        precondition(recoveredSummary?.sourceFingerprint == recoveryFingerprint,
                     "Caption recovery must preserve summary retry eligibility")
        precondition(recoveredSummary?.sourceIndex == recoveryDocument.sourceIndex && recoveredSummary?.status == .failed)
        let movedRecovery = directory.appendingPathComponent("Recovery moved in Finder.md")
        try fileManager.moveItem(at: recoveryURL, to: movedRecovery)
        let recoveredAssociation = try await store.load(for: movedRecovery)
        precondition(recoveredAssociation?.recordID == "record-recovery",
                     "Recovery must preserve summary association through external rename")
        // Refreshing a fingerprint must not silently approve unrelated prior edits.
        try "external source edit".write(to: movedRecovery, atomically: true, encoding: .utf8)
        // Restore the known filename so association can find a deliberately stale sidecar.
        try fileManager.moveItem(at: movedRecovery, to: recoveryURL)
        try await store.replaceTranscript(expected: "external source edit", with: "another translation", at: recoveryURL)
        let staleSummary = try await store.load(for: recoveryURL)
        precondition(staleSummary?.sourceFingerprint == recoveryFingerprint,
                     "A previously stale source fingerprint must not be approved")

        let renamed = directory.appendingPathComponent("Renamed.md")
        try await store.renameRecord(from: transcript, to: renamed)
        precondition(!fileManager.fileExists(atPath: transcript.path))
        precondition(fileManager.fileExists(atPath: renamed.path))
        let renamedDocument = try await store.load(for: renamed)
        precondition(renamedDocument?.recordID == document.recordID)
        precondition(renamedDocument?.transcriptFileName == renamed.lastPathComponent)
        let oldAssociation = try await store.load(for: transcript)
        precondition(oldAssociation == nil)

        let externallyRenamed = directory.appendingPathComponent("Externally Renamed.md")
        try fileManager.moveItem(at: renamed, to: externallyRenamed)
        let fingerprintAssociation = try await store.load(for: externallyRenamed)
        precondition(fingerprintAssociation?.recordID == document.recordID, "A unique final fingerprint must recover an external rename")

        let sidecarDirectory = directory.appendingPathComponent(".kikishima-summaries", isDirectory: true)
        var ambiguousDocument = document
        ambiguousDocument.recordID = "record-2"
        ambiguousDocument.transcriptFileName = "Another name.md"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(ambiguousDocument).write(
            to: sidecarDirectory.appendingPathComponent("record-2.json"),
            options: .atomic
        )
        let ambiguousAssociation = try await store.load(for: externallyRenamed)
        precondition(ambiguousAssociation == nil, "Two fingerprint matches must not auto-link")
        try fileManager.removeItem(at: sidecarDirectory.appendingPathComponent("record-2.json"))
        try fileManager.moveItem(at: externallyRenamed, to: renamed)

        // Duplicate filename claims resolve by fingerprint when unique, and
        // refuse to trash the transcript when they stay ambiguous.
        let ambiguousTrashURL = directory.appendingPathComponent("Ambiguous Trash.md")
        try await writer.write(markdown: "ambiguous trash", to: ambiguousTrashURL)
        let ambiguousFingerprint = try MeetingSummaryStore.sha256(of: ambiguousTrashURL)
        var firstClaim = document
        firstClaim.recordID = "record-claim-a"
        firstClaim.transcriptFileName = ambiguousTrashURL.lastPathComponent
        firstClaim.sourceFingerprint = ambiguousFingerprint
        var secondClaim = firstClaim
        secondClaim.recordID = "record-claim-b"
        secondClaim.sourceFingerprint = "0000"
        try await store.save(firstClaim, beside: ambiguousTrashURL)
        try encoder.encode(secondClaim).write(
            to: sidecarDirectory.appendingPathComponent("record-claim-b.json"),
            options: .atomic
        )
        let resolvedClaim = try await store.load(for: ambiguousTrashURL)
        precondition(resolvedClaim?.recordID == "record-claim-a",
                     "A duplicate filename must fall back to a unique fingerprint")
        var thirdClaim = firstClaim
        thirdClaim.recordID = "record-claim-c"
        try await store.save(thirdClaim, beside: ambiguousTrashURL)
        do {
            try await store.trashRecord(at: ambiguousTrashURL)
            preconditionFailure("Ambiguous sidecars must block deletion")
        } catch let error as MeetingRecordOperationError {
            guard case .ambiguousAssociation = error else { throw error }
        }
        precondition(fileManager.fileExists(atPath: ambiguousTrashURL.path))

        let trashState = TrashState()
        let failingTrashStore = MeetingSummaryStore(fileManager: fileManager) { url in
            precondition(url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(directory.path + "/"),
                         "Trash fixtures must remain inside this test's temporary directory")
            trashState.calls += 1
            if trashState.calls == 2 { throw InjectedFailure.secondTrashMove }
            try fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
            let destination = trashDirectory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try fileManager.moveItem(at: url, to: destination)
            return destination
        }

        do {
            try await failingTrashStore.trashRecord(at: renamed)
            preconditionFailure("Second trash move must fail")
        } catch InjectedFailure.secondTrashMove {
            // Expected.
        }
        precondition(fileManager.fileExists(atPath: renamed.path), "Transcript must be restored after sidecar trash fails")
        let restoredDocument = try await failingTrashStore.load(for: renamed)
        precondition(restoredDocument != nil, "Sidecar must remain associated after rollback")

        let successfulTrashState = TrashState()
        let successfulTrashStore = MeetingSummaryStore(fileManager: fileManager) { url in
            precondition(url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(directory.path + "/"),
                         "Trash fixtures must remain inside this test's temporary directory")
            successfulTrashState.calls += 1
            try fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
            let destination = trashDirectory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try fileManager.moveItem(at: url, to: destination)
            return destination
        }
        try await successfulTrashStore.trashRecord(at: renamed)
        precondition(successfulTrashState.calls == 2, "Transcript and sidecar must both move to Trash")
        precondition(!fileManager.fileExists(atPath: renamed.path))
        let trashedDocument = try await successfulTrashStore.load(for: renamed)
        precondition(trashedDocument == nil)

        // Corrupt sidecars stay invisible to load, but the History view can
        // surface a count instead of silently pretending the summary is gone.
        let corruptTranscript = directory.appendingPathComponent("Corrupt summary.md")
        try await writer.write(markdown: "corrupt summary", to: corruptTranscript)
        try Data("not json".utf8).write(
            to: sidecarDirectory.appendingPathComponent("record-corrupt.json"),
            options: .atomic
        )
        let corruptLoad = try await successfulTrashStore.load(for: corruptTranscript)
        precondition(corruptLoad == nil)
        let corruptCount = await successfulTrashStore.unreadableSummaryCount()
        precondition(corruptCount == 1, "A corrupt sidecar must be counted")
        try await successfulTrashStore.discardSummary(
            recordID: "record-corrupt", beside: corruptTranscript
        )
        let clearedCount = await successfulTrashStore.unreadableSummaryCount()
        precondition(clearedCount == 0, "Discarding a corrupt sidecar clears the warning")

        let batchTranscriptA = directory.appendingPathComponent("Batch A.md")
        let batchTranscriptB = directory.appendingPathComponent("Batch B.md")
        let batchTranscriptC = directory.appendingPathComponent("Batch C.md")
        try await writer.write(markdown: "batch-a", to: batchTranscriptA)
        try await writer.write(markdown: "batch-b", to: batchTranscriptB)
        try await writer.write(markdown: "batch-c", to: batchTranscriptC)
        let batchTrashState = BatchTrashState()
        let batchTrashStore = MeetingSummaryStore(fileManager: fileManager) { url in
            precondition(url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(directory.path + "/"),
                         "Trash fixtures must remain inside this test's temporary directory")
            batchTrashState.attempted.append(url.lastPathComponent)
            if url == batchTranscriptB { throw InjectedFailure.secondTrashMove }
            try fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
            let destination = trashDirectory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try fileManager.moveItem(at: url, to: destination)
            return destination
        }
        let batchResult = await batchTrashStore.trashRecords(at: [batchTranscriptA, batchTranscriptB, batchTranscriptC])
        precondition(batchTrashState.attempted == ["Batch A.md", "Batch B.md", "Batch C.md"], "A failed item must not stop later deletions")
        precondition(batchResult.succeeded == [batchTranscriptA, batchTranscriptC])
        precondition(batchResult.failures.map(\.url) == [batchTranscriptB])
        precondition(!fileManager.fileExists(atPath: batchTranscriptA.path), "First selected transcript must move to Trash")
        precondition(fileManager.fileExists(atPath: batchTranscriptB.path), "Failed transcript must remain in place")
        precondition(!fileManager.fileExists(atPath: batchTranscriptC.path), "Later selected transcripts must still move to Trash")

        print("PASS: transcript writer and meeting summary store")
    }
}
