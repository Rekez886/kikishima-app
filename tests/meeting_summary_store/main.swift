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
        let directory = fileManager.temporaryDirectory
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

        let store = MeetingSummaryStore(fileManager: fileManager)
        try await store.save(document, beside: transcript)
        let loadedDocument = try await store.load(for: transcript)
        precondition(loadedDocument == document)
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

        let trashState = TrashState()
        let failingTrashStore = MeetingSummaryStore(fileManager: fileManager) { url in
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

        let batchTranscriptA = directory.appendingPathComponent("Batch A.md")
        let batchTranscriptB = directory.appendingPathComponent("Batch B.md")
        let batchTranscriptC = directory.appendingPathComponent("Batch C.md")
        try await writer.write(markdown: "batch-a", to: batchTranscriptA)
        try await writer.write(markdown: "batch-b", to: batchTranscriptB)
        try await writer.write(markdown: "batch-c", to: batchTranscriptC)
        let batchTrashState = BatchTrashState()
        let batchTrashStore = MeetingSummaryStore(fileManager: fileManager) { url in
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
