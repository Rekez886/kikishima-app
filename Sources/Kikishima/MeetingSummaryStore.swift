import CryptoKit
import Foundation

protocol MeetingSummaryPersisting: Sendable {
    func save(_ document: MeetingSummaryDocument, beside transcriptURL: URL) async throws
}

enum MeetingRecordOperationError: Error {
    case destinationExists(URL)
    case rollbackFailed(operation: String, rollback: String)
}

struct MeetingRecordBatchTrashFailure: Sendable {
    let url: URL
    let message: String
}

struct MeetingRecordBatchTrashResult: Sendable {
    let succeeded: [URL]
    let failures: [MeetingRecordBatchTrashFailure]
}

actor MeetingSummaryStore {
    private struct Association {
        let url: URL
        let document: MeetingSummaryDocument
    }

    private let fileManager: FileManager
    private let trashItem: TrashItemOperation
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.trashItem = { url in
            try trashTranscript(at: url, fileManager: fileManager)
        }
        self.encoder = Self.makeEncoder()
        self.decoder = Self.makeDecoder()
    }

    init(fileManager: FileManager = .default, trashItem: @escaping TrashItemOperation) {
        self.fileManager = fileManager
        self.trashItem = trashItem
        self.encoder = Self.makeEncoder()
        self.decoder = Self.makeDecoder()
    }

    func save(_ document: MeetingSummaryDocument, beside transcriptURL: URL) throws {
        var stored = document
        stored.transcriptFileName = transcriptURL.lastPathComponent
        if fileManager.fileExists(atPath: transcriptURL.path) {
            stored.sourceFingerprint = try Self.sha256(of: transcriptURL)
        }

        let destination = sidecarURL(recordID: stored.recordID, beside: transcriptURL)
        try atomicWrite(try encoder.encode(stored), to: destination)
    }

    func load(for transcriptURL: URL) throws -> MeetingSummaryDocument? {
        guard var document = try associatedDocument(for: transcriptURL)?.document else { return nil }
        if document.status == .active || document.status == .finalizing {
            document.status = .interrupted
        }
        return document
    }

    /// Caption recovery changes only translations. Keep an already matching
    /// summary associated with the new bytes, including after a Finder rename.
    /// A previously stale fingerprint must stay stale.
    func replaceTranscript(expected: String, with replacement: String, at url: URL) throws {
        let association = try associatedDocument(for: url)
        let priorFingerprint = SHA256.hash(data: Data(expected.utf8)).map { String(format: "%02x", $0) }.joined()
        try TranscriptWriter.replaceSynchronously(expected: expected, with: replacement, at: url)
        guard let association, association.document.sourceFingerprint == priorFingerprint else { return }
        var document = association.document
        document.transcriptFileName = url.lastPathComponent
        document.sourceFingerprint = SHA256.hash(data: Data(replacement.utf8)).map { String(format: "%02x", $0) }.joined()
        do {
            try atomicWrite(try encoder.encode(document), to: association.url)
        } catch {
            // If the sidecar cannot follow, undo only our own unchanged write.
            try TranscriptWriter.replaceSynchronously(expected: replacement, with: expected, at: url,
                                                       checkingCancellation: false)
            throw error
        }
    }

    func renameRecord(from sourceURL: URL, to destinationURL: URL) throws {
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        guard !samePath(source, destination) else { return }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw MeetingRecordOperationError.destinationExists(destination)
        }

        let association = try associatedDocument(for: source)
        let oldSidecar = association?.url
        let newSidecar = association.map { sidecarURL(recordID: $0.document.recordID, beside: destination) }
        if let newSidecar, let oldSidecar, !samePath(newSidecar, oldSidecar),
           fileManager.fileExists(atPath: newSidecar.path) {
            throw MeetingRecordOperationError.destinationExists(newSidecar)
        }

        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: destination)

        guard var updated = association?.document, let oldSidecar, let newSidecar else { return }
        var movedSidecar = false
        do {
            if !samePath(oldSidecar, newSidecar) {
                try fileManager.createDirectory(at: newSidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: oldSidecar, to: newSidecar)
                movedSidecar = true
            }
            updated.transcriptFileName = destination.lastPathComponent
            if updated.isFinal {
                updated.sourceFingerprint = try Self.sha256(of: destination)
            }
            try atomicWrite(try encoder.encode(updated), to: newSidecar)
        } catch {
            let operationError = error
            do {
                if movedSidecar, fileManager.fileExists(atPath: newSidecar.path) {
                    try fileManager.createDirectory(at: oldSidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.moveItem(at: newSidecar, to: oldSidecar)
                }
                try fileManager.moveItem(at: destination, to: source)
            } catch {
                throw MeetingRecordOperationError.rollbackFailed(
                    operation: operationError.localizedDescription,
                    rollback: error.localizedDescription
                )
            }
            throw operationError
        }
    }

    func trashRecord(at transcriptURL: URL) throws {
        let association = try associatedDocument(for: transcriptURL)
        let recoverableTranscriptURL = try trashItem(transcriptURL)
        guard let sidecarURL = association?.url else { return }

        do {
            _ = try trashItem(sidecarURL)
        } catch {
            let operationError = error
            guard let recoverableTranscriptURL else {
                throw MeetingRecordOperationError.rollbackFailed(
                    operation: operationError.localizedDescription,
                    rollback: "The trash operation did not return a recoverable transcript URL."
                )
            }
            do {
                try fileManager.createDirectory(at: transcriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: recoverableTranscriptURL, to: transcriptURL)
            } catch {
                throw MeetingRecordOperationError.rollbackFailed(
                    operation: operationError.localizedDescription,
                    rollback: error.localizedDescription
                )
            }
            throw operationError
        }
    }

    func trashRecords(at transcriptURLs: [URL]) -> MeetingRecordBatchTrashResult {
        var succeeded: [URL] = []
        var failures: [MeetingRecordBatchTrashFailure] = []
        for transcriptURL in transcriptURLs {
            do {
                try trashRecord(at: transcriptURL)
                succeeded.append(transcriptURL)
            } catch {
                failures.append(MeetingRecordBatchTrashFailure(url: transcriptURL, message: error.localizedDescription))
            }
        }
        return MeetingRecordBatchTrashResult(succeeded: succeeded, failures: failures)
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 64 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func associatedDocument(for transcriptURL: URL) throws -> Association? {
        let associations = try allAssociations(beside: transcriptURL)
        let nameMatches = associations.filter { $0.document.transcriptFileName == transcriptURL.lastPathComponent }
        if nameMatches.count == 1 { return nameMatches[0] }
        if nameMatches.count > 1 { return nil }

        guard fileManager.fileExists(atPath: transcriptURL.path) else { return nil }
        let fingerprint = try Self.sha256(of: transcriptURL)
        let fingerprintMatches = associations.filter { $0.document.sourceFingerprint == fingerprint }
        return fingerprintMatches.count == 1 ? fingerprintMatches[0] : nil
    }

    private func allAssociations(beside transcriptURL: URL) throws -> [Association] {
        let directory = summaryDirectory(beside: transcriptURL)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }

        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let document = try? decoder.decode(MeetingSummaryDocument.self, from: data) else {
                return nil
            }
            return Association(url: url, document: document)
        }
    }

    private func summaryDirectory(beside transcriptURL: URL) -> URL {
        transcriptURL.deletingLastPathComponent()
            .appendingPathComponent(".kikishima-summaries", isDirectory: true)
    }

    private func sidecarURL(recordID: String, beside transcriptURL: URL) -> URL {
        summaryDirectory(beside: transcriptURL)
            .appendingPathComponent(recordID, isDirectory: false)
            .appendingPathExtension("json")
    }

    private func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        _ = fileManager.createFile(atPath: temporary.path, contents: nil)
        defer { try? fileManager.removeItem(at: temporary) }

        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    private nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

extension MeetingSummaryStore: MeetingSummaryPersisting {}
