import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Local-first meeting summarizer. Apple Foundation Models is the default;
/// a user-supplied OpenAI key is the higher-quality fallback. The server path
/// is gone, so summaries work without an account or any Kikishima service.
final class LocalMeetingSummaryClient: MeetingSummaryServicing, @unchecked Sendable {
    static let requestTimeout: TimeInterval = 90

    private let engine: @Sendable () -> TranslationEnginePolicy.Engine
    private let openAIKey: @Sendable () -> String
    private let openAIModel: String
    private let session: URLSession
    private let encoder = JSONEncoder()

    init(
        engine: @escaping @Sendable () -> TranslationEnginePolicy.Engine,
        openAIKey: @escaping @Sendable () -> String,
        openAIModel: String = "gpt-5.6-luna",
        session: URLSession = LocalMeetingSummaryClient.makeSession()
    ) {
        self.engine = engine
        self.openAIKey = openAIKey
        self.openAIModel = openAIModel
        self.session = session
    }

    func summarize(_ request: SummarizeRequest) async throws -> SummarizeResponse {
        if Task.isCancelled { throw MeetingSummaryClientError.cancelled }
        guard !request.segments.isEmpty || request.final else {
            throw MeetingSummaryClientError.invalidRequest
        }

        let prompt = SummaryPrompt.make(request)
        let raw: String
        switch engine() {
        case .openAI:
            raw = try await summarizeWithOpenAI(prompt)
        case .apple, .mlx:
            if #available(macOS 26.0, *), Self.foundationModelAvailable {
                raw = try await summarizeWithFoundationModels(prompt)
            } else if !openAIKey().isEmpty {
                raw = try await summarizeWithOpenAI(prompt)
            } else {
                throw MeetingSummaryClientError.localUnavailable
            }
        }

        let content = try SummaryOutputRepair.repair(raw, request: request)
        guard let processedThrough = request.segments.last?.id else {
            throw MeetingSummaryClientError.invalidResponse
        }
        return SummarizeResponse(
            content: content,
            processedThrough: processedThrough,
            schemaVersion: request.schemaVersion,
            promptVersion: request.promptVersion
        )
    }

    // MARK: - OpenAI

    private func summarizeWithOpenAI(_ prompt: SummaryPrompt) async throws -> String {
        let key = TranslationEnginePolicy.normalizedKey(openAIKey())
        guard !key.isEmpty else { throw MeetingSummaryClientError.unauthorized }
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw MeetingSummaryClientError.invalidRequest
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = Self.requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": openAIModel,
            "messages": [
                ["role": "system", "content": prompt.system],
                ["role": "user", "content": prompt.user],
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0.2,
            "max_completion_tokens": 1600,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw MeetingSummaryClientError.cancelled
            }
            throw MeetingSummaryClientError.network
        }
        guard let http = response as? HTTPURLResponse else {
            throw MeetingSummaryClientError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            break
        case 401:
            throw MeetingSummaryClientError.unauthorized
        case 429:
            throw MeetingSummaryClientError.rateLimited
        default:
            throw MeetingSummaryClientError.server(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw MeetingSummaryClientError.invalidResponse
        }
        return content
    }

    // MARK: - Apple Foundation Models

    @available(macOS 26.0, *)
    private static var foundationModelAvailable: Bool {
#if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
#endif
        return false
    }

    @available(macOS 26.0, *)
    private func summarizeWithFoundationModels(_ prompt: SummaryPrompt) async throws -> String {
#if canImport(FoundationModels)
        let session = LanguageModelSession(instructions: prompt.system)
        do {
            let response = try await session.respond(to: prompt.user)
            return response.content
        } catch is CancellationError {
            throw MeetingSummaryClientError.cancelled
        } catch {
            throw MeetingSummaryClientError.localUnavailable
        }
#else
        throw MeetingSummaryClientError.localUnavailable
#endif
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}

// MARK: - Prompt

struct SummaryPrompt: Sendable {
    let system: String
    let user: String

    static func make(_ request: SummarizeRequest) -> SummaryPrompt {
        let schema = """
        {
          "overview": [{"text": "...", "sourceSegmentIDs": ["id"]}],
          "currentState": [{"text": "...", "sourceSegmentIDs": ["id"]}],
          "decisions": [{"text": "...", "sourceSegmentIDs": ["id"]}],
          "actionItems": [{"text": "...", "owner": "name or null", "deadline": "date or null", "sourceSegmentIDs": ["id"]}],
          "personalItems": [{"text": "...", "sourceSegmentIDs": ["id"]}],
          "openQuestions": [{"text": "...", "sourceSegmentIDs": ["id"]}]
        }
        """
        let system = """
        You summarize meetings. Return ONLY one JSON object, no markdown, no commentary.
        Shape: \(schema)
        Rules:
        - Write in \(request.targetLanguage).
        - Merge the previous summary with the new segments. Do not repeat the same point.
        - Every item needs at least one sourceSegmentIDs value copied exactly from the new segment ids.
        - overview: 1-2 items. currentState, decisions, personalItems, openQuestions: at most 8 each. actionItems: at most 8.
        - personalItems only when the segment explicitly mentions one of these aliases: \(request.aliases.joined(separator: ", ")).
        - Keep each text under 400 characters. Never invent facts, owners or dates.
        """
        var previous = ""
        if let content = request.previous,
           let data = try? JSONEncoder().encode(content),
           let json = String(data: data, encoding: .utf8) {
            previous = String(json.prefix(6_000))
        }
        var lines: [String] = []
        for segment in request.segments {
            lines.append("[\(segment.id)] (\(segment.startSeconds)s) \(segment.text)")
        }
        let segments = String(lines.joined(separator: "\n").prefix(12_000))
        let user = """
        Previous summary (may be empty):
        \(previous)

        New segments:
        \(segments)
        """
        return SummaryPrompt(system: system, user: user)
    }
}

// MARK: - Tolerant JSON repair

enum SummaryOutputRepair {
    private static let maximumTextBytes = 1_024
    private static let maximumItems = 8

    private struct RawBlock: Decodable {
        var text: String
        var sourceRefs: [SummarySourceRef]?
        var sourceSegmentIDs: [String]?
    }

    private struct RawAction: Decodable {
        var text: String
        var owner: String?
        var deadline: String?
        var sourceRefs: [SummarySourceRef]?
        var sourceSegmentIDs: [String]?
    }

    private struct RawContent: Decodable {
        var overview: [RawBlock]?
        var currentState: [RawBlock]?
        var decisions: [RawBlock]?
        var actionItems: [RawAction]?
        var personalItems: [RawBlock]?
        var openQuestions: [RawBlock]?
    }

    static func repair(_ raw: String, request: SummarizeRequest) throws -> MeetingSummaryContent {
        let cleaned = extractJSON(from: raw)
        guard let data = cleaned.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RawContent.self, from: data) else {
            throw MeetingSummaryClientError.invalidResponse
        }
        let known = Dictionary(request.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let aliases = request.aliases

        func refs(_ block: RawBlock) -> [SummarySourceRef] {
            var result: [SummarySourceRef] = []
            var seen = Set<String>()
            for ref in block.sourceRefs ?? [] {
                guard let segment = known[ref.segmentID], seen.insert(ref.segmentID).inserted else { continue }
                result.append(SummarySourceRef(segmentID: ref.segmentID, startSeconds: segment.startSeconds))
            }
            for id in block.sourceSegmentIDs ?? [] {
                guard let segment = known[id], seen.insert(id).inserted else { continue }
                result.append(SummarySourceRef(segmentID: id, startSeconds: segment.startSeconds))
            }
            return result
        }

        func blocks(_ raw: [RawBlock]?, aliasesRequired: Bool) -> [SummaryBlock] {
            var out: [SummaryBlock] = []
            for block in raw ?? [] {
                let text = trimmed(block.text)
                guard !text.isEmpty else { continue }
                let source = refs(block)
                guard !source.isEmpty else { continue }
                if aliasesRequired {
                    let hasAlias = source.contains { ref in
                        guard let segment = known[ref.segmentID] else { return false }
                        return SummaryAliasMatcher.containsAlias(in: segment.text, aliases: aliases)
                    }
                    guard hasAlias else { continue }
                }
                out.append(SummaryBlock(id: UUID().uuidString.lowercased(), text: text, sourceRefs: source))
                if out.count == maximumItems { break }
            }
            return out
        }

        func actions(_ raw: [RawAction]?) -> [SummaryActionItem] {
            var out: [SummaryActionItem] = []
            for item in raw ?? [] {
                let text = trimmed(item.text)
                guard !text.isEmpty else { continue }
                let block = RawBlock(text: item.text, sourceRefs: item.sourceRefs, sourceSegmentIDs: item.sourceSegmentIDs)
                let source = refs(block)
                guard !source.isEmpty else { continue }
                out.append(SummaryActionItem(
                    id: UUID().uuidString.lowercased(),
                    text: text,
                    owner: optional(item.owner),
                    deadline: optional(item.deadline),
                    sourceRefs: source
                ))
                if out.count == maximumItems { break }
            }
            return out
        }

        let content = MeetingSummaryContent(
            overview: Array(blocks(decoded.overview, aliasesRequired: false).prefix(2)),
            currentState: blocks(decoded.currentState, aliasesRequired: false),
            decisions: blocks(decoded.decisions, aliasesRequired: false),
            actionItems: actions(decoded.actionItems),
            personalItems: blocks(decoded.personalItems, aliasesRequired: true),
            openQuestions: blocks(decoded.openQuestions, aliasesRequired: false)
        )
        guard !content.overview.isEmpty || !content.currentState.isEmpty
                || !content.decisions.isEmpty || !content.actionItems.isEmpty
                || !content.personalItems.isEmpty || !content.openQuestions.isEmpty else {
            throw MeetingSummaryClientError.invalidResponse
        }
        return content
    }

    private static func extractJSON(from raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        return text
    }

    private static func trimmed(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lengthOfBytes(using: .utf8) > maximumTextBytes else { return value }
        return String(value.prefix(maximumTextBytes))
    }

    private static func optional(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              value.lowercased() != "null" else { return nil }
        return String(value.prefix(128))
    }
}
