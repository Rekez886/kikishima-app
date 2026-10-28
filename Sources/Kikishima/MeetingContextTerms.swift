import Foundation

enum MeetingContextTerms {
    static func mergedGlossary(
        permanent: String,
        context: MeetingContext?,
        maxLines: Int = 80,
        maxCharacters: Int = 4_000
    ) -> String {
        guard maxLines > 0, maxCharacters > 0 else { return "" }

        var candidates = permanent
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let context {
            candidates.append(context.title.trimmingCharacters(in: .whitespacesAndNewlines))
            candidates.append(contentsOf: context.attendeeNames.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            })
        }

        var seen: Set<String> = []
        var accepted: [String] = []
        var characterCount = 0

        for candidate in candidates {
            let key = CalendarCandidatePolicy.normalizedTitle(candidate)
            guard !key.isEmpty, !seen.contains(key), accepted.count < maxLines else { continue }
            let addedCharacters = candidate.count + (accepted.isEmpty ? 0 : 1)
            guard characterCount + addedCharacters <= maxCharacters else { continue }
            seen.insert(key)
            accepted.append(candidate)
            characterCount += addedCharacters
        }

        return accepted.joined(separator: "\n")
    }

    static func recordTitle(from raw: String, maxCharacters: Int = 80) -> String {
        guard maxCharacters > 0 else { return "" }
        let safe = raw
            .replacingOccurrences(
                of: "[/:\\\\\n\r\t\"*?<>|]",
                with: " ",
                options: .regularExpression
            )
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(safe.prefix(maxCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
