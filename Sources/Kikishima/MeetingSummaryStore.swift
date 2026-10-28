import CryptoKit
import Foundation

protocol MeetingSummaryPersisting: Sendable {
    func save(_ document: MeetingSummaryDocument, beside transcriptURL: URL) async throws
}

protocol MeetingSummaryDiscarding: Sendable {
    func discardSummary(recordID: String, beside transcriptURL: URL) async throws
}

enum MeetingRecordOperationError: Error {
    case destinationExists(URL)
    case rollbackFailed(operation: String, rollback: String)
    case invalidRecordID(String)
    case ambiguousAssociation(URL)
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
    private struct FingerprintEntry { let size: UInt64; let date: Date; let hash: String }
    private struct AssociationCacheEntry {
        let stamp: String
        let associations: [Association]
        let corrupt: Set<URL>
    }
    private var fingerprintCache: [String: FingerprintEntry] = [:]
    private var associationCache: [String: AssociationCacheEntry] = [:]
    private var corruptSidecars: Set<URL> = []

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

    func unreadableSummaryCount() -> Int {
        corruptSidecars.count
    }

    func save(_ document: MeetingSummaryDocument, beside transcriptURL: URL) throws {
        guard Self.isValidRecordID(document.recordID) else {
            throw MeetingRecordOperationError.invalidRecordID(document.recordID)
        }
        var stored = document
        stored.transcriptFileName = transcriptURL.lastPathComponent
        if fileManager.fileExists(atPath: transcriptURL.path) {
            stored.sourceFingerprint = try fingerprint(for: transcriptURL)
        }

        let destination = sidecarURL(recordID: stored.recordID, beside: transcriptURL)
        try atomicWrite(try encoder.encode(stored), to: destination)
        corruptSidecars.remove(destination.standardizedFileURL)
        invalidateAssociations(beside: transcriptURL)
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
    func replaceTranscript(expected: String, with replacement: String, at url: URL,
                            checkingCancellation: Bool = true) throws {
        let association = try associatedDocument(for: url)
        let priorFingerprint = SHA256.hash(data: Data(expected.utf8)).map { String(format: "%02x", $0) }.joined()
        try TranscriptWriter.replaceSynchronously(expected: expected, with: replacement, at: url,
                                                   checkingCancellation: checkingCancellation)
        guard let association, association.document.sourceFingerprint == priorFingerprint else { return }
        invalidateAssociations(beside: url)
        invalidateFingerprint(for: url)
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
        let destinationExists = fileManager.fileExists(atPath: destination.path)
        let destinationIsSameFile = destinationExists && sameFile(source, destination)
        guard !destinationExists || destinationIsSameFile else {
            throw MeetingRecordOperationError.destinationExists(destination)
        }

        let association = try associatedDocument(for: source)
        if let association, !Self.isValidRecordID(association.document.recordID) {
            throw MeetingRecordOperationError.invalidRecordID(association.document.recordID)
        }
        let oldSidecar = association?.url
        let newSidecar = association.map { sidecarURL(recordID: $0.document.recordID, beside: destination) }
        if let newSidecar, let oldSidecar, !samePath(newSidecar, oldSidecar),
           fileManager.fileExists(atPath: newSidecar.path) {
            throw MeetingRecordOperationError.destinationExists(newSidecar)
        }

        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try moveFile(from: source, to: destination)

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
                updated.sourceFingerprint = try fingerprint(for: destination)
            }
            try atomicWrite(try encoder.encode(updated), to: newSidecar)
            invalidateAssociations(beside: destination)
            invalidateFingerprint(for: source)
            invalidateFingerprint(for: destination)
        } catch {
            let operationError = error
            do {
                if movedSidecar, fileManager.fileExists(atPath: newSidecar.path) {
                    try fileManager.createDirectory(at: oldSidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.moveItem(at: newSidecar, to: oldSidecar)
                }
                try moveFile(from: destination, to: source)
            } catch {
                throw MeetingRecordOperationError.rollbackFailed(
                    operation: operationError.localizedDescription,
                    rollback: error.localizedDescription
                )
            }
            throw operationError
        }
    }

    func discardSummary(recordID: String, beside transcriptURL: URL) async throws {
        guard Self.isValidRecordID(recordID) else {
            throw MeetingRecordOperationError.invalidRecordID(recordID)
        }
        let sidecar = sidecarURL(recordID: recordID, beside: transcriptURL)
        if fileManager.fileExists(atPath: sidecar.path) {
            try fileManager.removeItem(at: sidecar)
        }
        corruptSidecars.remove(sidecar.standardizedFileURL)
        invalidateAssociations(beside: transcriptURL)
        invalidateFingerprint(for: transcriptURL)
    }

    func trashRecord(at transcriptURL: URL) throws {
        let associations = try allAssociations(beside: transcriptURL)
        let nameMatches = associations.filter { $0.document.transcriptFileName == transcriptURL.lastPathComponent }
        let association = try associatedDocument(for: transcriptURL)
        if association == nil, nameMatches.count > 1 {
            // Refuse to trash the transcript while leaving several plausible
            // sidecars behind; the user can resolve the duplicate first.
            throw MeetingRecordOperationError.ambiguousAssociation(transcriptURL)
        }
        let recoverableTranscriptURL = try trashItem(transcriptURL)
        guard let sidecarURL = association?.url else { return }

        do {
            _ = try trashItem(sidecarURL)
            invalidateAssociations(beside: transcriptURL)
            invalidateFingerprint(for: transcriptURL)
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

        guard fileManager.fileExists(atPath: transcriptURL.path) else { return nil }
        let fingerprint = try fingerprint(for: transcriptURL)
        let fingerprintMatches = associations.filter { $0.document.sourceFingerprint == fingerprint }
        return fingerprintMatches.count == 1 ? fingerprintMatches[0] : nil
    }

    private func allAssociations(beside transcriptURL: URL) throws -> [Association] {
        let directory = summaryDirectory(beside: transcriptURL)
        guard fileManager.fileExists(atPath: directory.path) else {
            corruptSidecars = []
            return []
        }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }

        let stamp = directoryStamp(directory, urls: urls)
        if let cached = associationCache[directory.path], cached.stamp == stamp {
            corruptSidecars = cached.corrupt
            return cached.associations
        }
        var corrupt: Set<URL> = []
        let associations = urls.compactMap { url -> Association? in
            guard let data = try? Data(contentsOf: url),
                  let document = try? decoder.decode(MeetingSummaryDocument.self, from: data) else {
                corrupt.insert(url.standardizedFileURL)
                return nil
            }
            return Association(url: url, document: document)
        }
        corruptSidecars = corrupt
        associationCache[directory.path] = AssociationCacheEntry(
            stamp: stamp, associations: associations, corrupt: corrupt
        )
        return associations
    }

    private func directoryStamp(_ directory: URL, urls: [URL]) -> String {
        let directoryDate = (try? directory.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
        var totalSize = 0
        var newest = Date.distantPast
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            totalSize += values.fileSize ?? 0
            if let date = values.contentModificationDate, date > newest { newest = date }
        }
        return "\(directoryDate.timeIntervalSince1970)-\(newest.timeIntervalSince1970)-\(urls.count)-\(totalSize)"
    }

    private func fingerprint(for url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = UInt64(max(0, values.fileSize ?? 0))
        let date = values.contentModificationDate ?? .distantPast
        let key = url.standardizedFileURL.path
        if let cached = fingerprintCache[key], cached.size == size, cached.date == date {
            return cached.hash
        }
        let hash = try Self.sha256(of: url)
        fingerprintCache[key] = FingerprintEntry(size: size, date: date, hash: hash)
        return hash
    }

    private func invalidateAssociations(beside transcriptURL: URL) {
        let directory = summaryDirectory(beside: transcriptURL)
        associationCache.removeValue(forKey: directory.path)
    }

    private func invalidateFingerprint(for url: URL) {
        fingerprintCache.removeValue(forKey: url.standardizedFileURL.path)
    }

    private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = try? lhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let right = try? rhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else {
            return false
        }
        return (left as? NSObject)?.isEqual(right) ?? false
    }

    /// Case-only renames on case-insensitive volumes need a temporary hop; a
    /// direct move to the differently-cased path can be rejected as existing.
    private func moveFile(from source: URL, to destination: URL) throws {
        if samePath(source, destination) { return }
        if fileManager.fileExists(atPath: destination.path), sameFile(source, destination) {
            let temporary = source.deletingLastPathComponent()
                .appendingPathComponent(".kikishima-move-\(UUID().uuidString)")
            try fileManager.moveItem(at: source, to: temporary)
            do {
                try fileManager.moveItem(at: temporary, to: destination)
            } catch {
                try? fileManager.moveItem(at: temporary, to: source)
                throw error
            }
        } else {
            try fileManager.moveItem(at: source, to: destination)
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

    /// Record IDs come from sidecars; never let one escape the summary folder.
    private static func isValidRecordID(_ recordID: String) -> Bool {
        !recordID.isEmpty
            && recordID != "."
            && recordID != ".."
            && !recordID.contains("/")
            && !recordID.contains("\\")
            && !recordID.contains("\0")
            && recordID.utf8.count <= 200
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

extension MeetingSummaryStore: MeetingSummaryPersisting, MeetingSummaryDiscarding {}
