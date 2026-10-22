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
        guard markdown.utf8.count <= 16 * 1024 * 1024,
              markdown.hasSuffix(suffix),
              let range = markdown.range(of: prefix, options: .backwards),
              let data = Data(base64Encoded: String(markdown[range.upperBound..<markdown.index(markdown.endIndex, offsetBy: -suffix.count)])),
              let record = try? JSONDecoder().decode(Self.self, from: data),
              record.version == 1, record.incompleteCount > 0,
              record.rows.count <= 50_000,
              !record.settings.targetLanguage.isEmpty,
              record.body == String(markdown[..<range.lowerBound]) else { return nil }
        return record
    }

    static func visibleText(_ markdown: String) -> String {
        decode(markdown)?.body ?? markdown
    }
}

/// A standalone job. Its injected translation function has no live-session state.
/// Each completed row is saved before proceeding, so cancellation retains progress.
@MainActor
enum TranscriptRecoveryRun {
    static func run(
        record: TranscriptRecovery, markdown: String, url: URL,
        deadline: ContinuousClock.Instant,
        translate: (TranscriptRecovery.Row, TranscriptRecovery.Settings, ContinuousClock.Instant) async -> String?,
        replace: (String, String, URL) async throws -> Void,
        didSave: () -> Void
    ) async throws {
        var record = record
        var expected = markdown
        for index in record.rows.indices where !record.rows[index].marker && !record.rows[index].complete {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return }
            let result = await translate(record.rows[index], record.settings, deadline)
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return }
            guard let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            record.rows[index].translation = result
            record.rows[index].complete = true
            let replacement = try record.markdown()
            try await replace(expected, replacement, url)
            expected = replacement
            didSave()
        }
    }
}
