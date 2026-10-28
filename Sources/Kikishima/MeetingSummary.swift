import Foundation
import CryptoKit

struct SummarySourceSegment: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let startSeconds: Int
    let text: String
}

struct SummarySourceRef: Codable, Equatable, Hashable, Sendable {
    let segmentID: String
    let startSeconds: Int
}

struct SummaryBlock: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var text: String
    var sourceRefs: [SummarySourceRef]
}

struct SummaryActionItem: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var text: String
    var owner: String?
    var deadline: String?
    var sourceRefs: [SummarySourceRef]
}

struct MeetingSummaryContent: Codable, Equatable, Sendable {
    var overview: [SummaryBlock]
    var currentState: [SummaryBlock]
    var decisions: [SummaryBlock]
    var actionItems: [SummaryActionItem]
    var personalItems: [SummaryBlock]
    var openQuestions: [SummaryBlock]
}

enum MeetingSummaryStatus: String, Codable, Sendable {
    case active
    case finalizing
    case finished
    case failed
    case interrupted
}

struct MeetingSummaryDocument: Codable, Equatable, Sendable {
    var recordID: String
    var transcriptFileName: String
    var content: MeetingSummaryContent
    var sourceIndex: [String: SummarySourceSegment]
    var processedThrough: String?
    var schemaVersion: Int
    var promptVersion: String
    var sourceFingerprint: String?
    var updatedAt: Date
    var isFinal: Bool
    var status: MeetingSummaryStatus
}

struct SummarizeRequest: Codable, Equatable, Sendable {
    var requestID: String
    var previous: MeetingSummaryContent?
    var previousSourceIDs: [String]
    var segments: [SummarySourceSegment]
    var targetLanguage: String
    var aliases: [String]
    var final: Bool
    var schemaVersion: Int
    var promptVersion: String
    // Local correlation only. The strict server JSON schema and idempotency
    // body stay unchanged; this random UUID travels in a separate header.
    var costSessionID: String? = nil
    enum CodingKeys: String, CodingKey {
        case requestID, previous, previousSourceIDs, segments, targetLanguage, aliases, final, schemaVersion, promptVersion
    }
}

/// A stable local cost-correlation id for both UUID and legacy record ids.
enum MeetingSummaryCostSession {
    static func id(for recordID: String) -> UUID {
        if let uuid = UUID(uuidString: recordID) { return uuid }
        var bytes = Array(SHA256.hash(data: Data(recordID.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

struct SummarizeResponse: Codable, Equatable, Sendable {
    var content: MeetingSummaryContent
    var processedThrough: String
    var schemaVersion: Int
    var promptVersion: String
}

enum SummaryAliasMatcher {
    static func normalized(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func containsAlias(in text: String, aliases: [String]) -> Bool {
        let normalizedText = normalized(text)
        guard !normalizedText.isEmpty else { return false }

        return aliases.contains { rawAlias in
            let alias = normalized(rawAlias)
            guard !alias.isEmpty else { return false }
            if containsCJK(alias) { return normalizedText.contains(alias) }

            let escaped = NSRegularExpression.escapedPattern(for: alias)
            guard let expression = try? NSRegularExpression(
                pattern: "(?<![\\p{L}\\p{N}_])\(escaped)(?![\\p{L}\\p{N}_])"
            ) else { return false }
            let range = NSRange(normalizedText.startIndex..<normalizedText.endIndex, in: normalizedText)
            return expression.firstMatch(in: normalizedText, range: range) != nil
        }
    }

    private static func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xF900...0xFAFF, 0xAC00...0xD7AF, 0xFF66...0xFF9F:
                return true
            default:
                return false
            }
        }
    }
}

enum MeetingSummaryConsent: String, Codable, Sendable {
    case undecided
    case enabled
    case disabled
}

enum MeetingSummaryRetryPolicy {
    /// Interrupted/failed summaries may retry from sidecar evidence even if
    /// autosave moved the markdown fingerprint. Finished docs stay fingerprint-gated.
    static func canRetry(status: MeetingSummaryStatus, hasSourceIndex: Bool, fingerprintMatches: Bool) -> Bool {
        switch status {
        case .interrupted, .failed:
            return hasSourceIndex || fingerprintMatches
        case .active, .finalizing, .finished:
            return false
        }
    }
}

enum MeetingSummaryPreferences {
    static func shouldGenerate(consent: MeetingSummaryConsent, enabled: Bool) -> Bool {
        consent == .enabled && enabled
    }

    static func normalizedAliases(from text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawAlias in text.components(separatedBy: .newlines) {
            let alias = rawAlias.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = SummaryAliasMatcher.normalized(alias)
            guard !normalized.isEmpty,
                  alias.lengthOfBytes(using: .utf8) <= 128,
                  seen.insert(normalized).inserted else { continue }
            result.append(alias)
            if result.count == 10 { break }
        }
        return result
    }
}

enum MeetingSummarySearch {
    static func matches(
        query: String,
        title: String,
        transcriptText: String,
        summary: MeetingSummaryDocument?
    ) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if title.localizedCaseInsensitiveContains(query) || transcriptText.localizedCaseInsensitiveContains(query) {
            return true
        }
        guard let content = summary?.content else { return false }
        let blockText = (content.overview + content.currentState + content.decisions + content.personalItems + content.openQuestions)
            .map(\.text)
        let actionText = content.actionItems.flatMap { item in
            [item.text, item.owner, item.deadline].compactMap { $0 }
        }
        return (blockText + actionText).contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

enum MeetingSummaryValidationError: Error, Equatable {
    case versionMismatch
    case contentTooLarge
    case sectionLimitExceeded
    case itemTextTooLarge
    case missingSourceReference
    case unknownSourceReference
    case sourceReferenceTimeMismatch
    case invalidProcessedThrough
    case personalItemWithoutAliasEvidence
}

enum MeetingSummaryValidation {
    private static let maximumItemBytes = 1_024
    private static let maximumContentBytes = 20 * 1_024

    static func validate(response: SummarizeResponse, request: SummarizeRequest) throws {
        guard response.schemaVersion == request.schemaVersion,
              response.promptVersion == request.promptVersion else {
            throw MeetingSummaryValidationError.versionMismatch
        }

        // Duplicate segment IDs must not crash validation; first occurrence wins.
        let currentSegments = Dictionary(request.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let knownSourceIDs = Set(request.previousSourceIDs).union(currentSegments.keys)
        guard response.processedThrough == request.segments.last?.id else {
            throw MeetingSummaryValidationError.invalidProcessedThrough
        }

        let content = response.content
        guard try JSONEncoder().encode(content).count <= maximumContentBytes else {
            throw MeetingSummaryValidationError.contentTooLarge
        }
        guard content.overview.count <= 2,
              content.currentState.count <= 8,
              content.decisions.count <= 20,
              content.actionItems.count <= 20,
              content.personalItems.count <= 20,
              content.openQuestions.count <= 20 else {
            throw MeetingSummaryValidationError.sectionLimitExceeded
        }

        for block in content.overview + content.currentState + content.decisions + content.personalItems + content.openQuestions {
            try validate(text: block.text, refs: block.sourceRefs, knownSourceIDs: knownSourceIDs, currentSegments: currentSegments)
        }
        for item in content.actionItems {
            try validate(text: item.text, refs: item.sourceRefs, knownSourceIDs: knownSourceIDs, currentSegments: currentSegments)
        }

        let trustedPrevious = request.previous?.personalItems ?? []
        for item in content.personalItems where !trustedPrevious.contains(item) {
            let hasAliasEvidence = item.sourceRefs.contains { ref in
                guard let segment = currentSegments[ref.segmentID], segment.startSeconds == ref.startSeconds else { return false }
                return SummaryAliasMatcher.containsAlias(in: segment.text, aliases: request.aliases)
            }
            guard hasAliasEvidence else {
                throw MeetingSummaryValidationError.personalItemWithoutAliasEvidence
            }
        }
    }

    private static func validate(
        text: String,
        refs: [SummarySourceRef],
        knownSourceIDs: Set<String>,
        currentSegments: [String: SummarySourceSegment]
    ) throws {
        guard !refs.isEmpty else { throw MeetingSummaryValidationError.missingSourceReference }
        guard text.lengthOfBytes(using: .utf8) <= maximumItemBytes else {
            throw MeetingSummaryValidationError.itemTextTooLarge
        }
        guard refs.allSatisfy({ knownSourceIDs.contains($0.segmentID) }) else {
            throw MeetingSummaryValidationError.unknownSourceReference
        }
        guard refs.allSatisfy({ ref in
            guard let segment = currentSegments[ref.segmentID] else { return true }
            return segment.startSeconds == ref.startSeconds
        }) else {
            throw MeetingSummaryValidationError.sourceReferenceTimeMismatch
        }
    }
}
