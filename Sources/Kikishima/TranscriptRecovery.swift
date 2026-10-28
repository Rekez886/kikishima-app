import Foundation

/// Recovery travels with the Markdown through rename, export and Trash. It never
/// contains credentials or service URLs. Edited/legacy records remain readable,
/// but are not automatically rewritten.
struct TranscriptRecovery: Codable, Sendable {
    struct Settings: Codable, Sendable {
        var targetLanguage: String
        var glossary: String
        var model: String
        var useProxy: Bool
    }
    struct Row: Codable, Sendable {
        var source: String
        var translation: String
        var complete: Bool
        var marker: Bool
        var stamp: String
        var previousSource: String
    }
    var version = 1
    var header: String
    var incompleteLabel: String
    var settings: Settings
    var rows: [Row]

    var incompleteCount: Int { rows.filter { !$0.marker && !$0.complete }.count }
    private static let prefix = "<!-- kikishima-recovery-v1:"
    private static let suffix = " -->\n"
    private static let maximumRows = 50_000

    var body: String {
        var result = header
        for row in rows where !row.source.isEmpty {
            if row.marker {
                result += "---\n\n*\(row.source)*\n\n---\n\n"
            } else {
                result += "`\(row.stamp)` \(row.source)\n\n\(row.translation)\n\n"
                if !row.complete { result += "*\(incompleteLabel)*\n\n" }
            }
        }
        return result
    }

    func markdown() throws -> String {
        guard incompleteCount > 0 else { return body }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return body + Self.prefix + (try encoder.encode(self)).base64EncodedString() + Self.suffix
    }

    static func decode(_ markdown: String) -> Self? {
        guard let record = parsed(markdown), record.rows.count <= maximumRows else { return nil }
        return record
    }

    /// Returns true only when the recovery block is otherwise valid but too
    /// large to retry, so the UI can explain the limit instead of calling the
    /// record corrupted.
    static func exceedsRowLimit(_ markdown: String) -> Bool {
        guard let record = parsed(markdown) else { return false }
        return record.rows.count > maximumRows
    }

    private static func parsed(_ markdown: String) -> Self? {
        guard markdown.utf8.count <= 16 * 1024 * 1024,
              markdown.hasSuffix(suffix),
              let range = markdown.range(of: prefix, options: .backwards),
              let data = Data(base64Encoded: String(markdown[range.upperBound..<markdown.index(markdown.endIndex, offsetBy: -suffix.count)])),
              let record = try? JSONDecoder().decode(Self.self, from: data),
              record.version == 1, record.incompleteCount > 0,
              !record.settings.targetLanguage.isEmpty,
              record.body == String(markdown[..<range.lowerBound]) else { return nil }
        return record
    }

    static func visibleText(_ markdown: String) -> String {
        decode(markdown)?.body ?? markdown
    }
}

/// A standalone job. Its injected translation function has no live-session state.
/// Completed rows are written in small batches, with a forced flush on
/// cancellation so user-visible progress is retained.
@MainActor
enum TranscriptRecoveryRun {
    static func run(
        record: TranscriptRecovery, markdown: String, url: URL,
        deadline: ContinuousClock.Instant,
        translate: (TranscriptRecovery.Row, TranscriptRecovery.Settings, ContinuousClock.Instant) async -> String?,
        replace: (String, String, URL) async throws -> Void,
        flush: ((String, String, URL) async throws -> Void)? = nil,
        didSave: () -> Void
    ) async throws {
        var record = record
        var expected = markdown
        var pendingSaves = 0

        func replacementMarkdown() async throws -> String {
            // Long meetings spend real time JSON/base64-encoding the whole
            // recovery block. Keep that work off the main thread; the sidecar
            // write itself already runs on MeetingSummaryStore's actor.
            if record.rows.count > 200 {
                let snapshot = record
                return try await Task.detached(priority: .utility) {
                    try snapshot.markdown()
                }.value
            }
            return try record.markdown()
        }

        func persist(force: Bool) async throws {
            guard pendingSaves > 0 else { return }
            let replacement = try await replacementMarkdown()
            if force, let flush {
                try await flush(expected, replacement, url)
            } else {
                try await replace(expected, replacement, url)
            }
            expected = replacement
            pendingSaves = 0
            didSave()
        }

        for index in record.rows.indices where !record.rows[index].marker && !record.rows[index].complete {
            guard !Task.isCancelled, ContinuousClock.now < deadline else {
                try? await persist(force: true)
                return
            }
            let result = await translate(record.rows[index], record.settings, deadline)
            guard !Task.isCancelled, ContinuousClock.now < deadline else {
                try? await persist(force: true)
                return
            }
            // One failed row must not abort the remaining rows; it stays
            // incomplete for the next recovery run.
            guard let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            record.rows[index].translation = result
            record.rows[index].complete = true
            pendingSaves += 1
            if pendingSaves >= 8 {
                try await persist(force: false)
            }
        }
        try await persist(force: false)
    }
}
