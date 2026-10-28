import Foundation

private func makeContent(
    personalText: String = "Send the Japanese slides",
    sourceID: String = "chunk-1",
    startSeconds: Int = 185
) -> MeetingSummaryContent {
    let ref = SummarySourceRef(segmentID: sourceID, startSeconds: startSeconds)
    return MeetingSummaryContent(
        overview: [SummaryBlock(id: "overview-1", text: "Localization planning meeting", sourceRefs: [ref])],
        currentState: [],
        decisions: [],
        actionItems: [SummaryActionItem(id: "action-1", text: "Send the Japanese slides", owner: "Alex", deadline: "Friday", sourceRefs: [ref])],
        personalItems: [SummaryBlock(id: "personal-1", text: personalText, sourceRefs: [ref])],
        openQuestions: []
    )
}

private func testDocumentRoundTripPreservesEvidence() throws {
    let segment = SummarySourceSegment(id: "chunk-1", startSeconds: 185, text: "Alex, please send the Japanese slides by Friday.")
    let document = MeetingSummaryDocument(
        recordID: "record-1",
        transcriptFileName: "meeting.md",
        content: makeContent(),
        sourceIndex: [segment.id: segment],
        processedThrough: segment.id,
        schemaVersion: 1,
        promptVersion: "2026-08-31-v1",
        sourceFingerprint: nil,
        updatedAt: Date(timeIntervalSince1970: 0),
        isFinal: false,
        status: .active
    )

    let encoded = try JSONEncoder().encode(document)
    let decoded = try JSONDecoder().decode(MeetingSummaryDocument.self, from: encoded)
    precondition(decoded == document, "Codable round-trip must preserve summary content and source evidence")
}

private func testAliasMatchingUsesBoundariesAndCJKNormalization() {
    precondition(SummaryAliasMatcher.containsAlias(in: "Alex, please send it", aliases: ["alex"]))
    precondition(!SummaryAliasMatcher.containsAlias(in: "Alexander owns it", aliases: ["Alex"]), "Latin aliases must not match inside a longer name")
    precondition(SummaryAliasMatcher.containsAlias(in: "小田さんお願いします", aliases: ["小田"]))
    precondition(SummaryAliasMatcher.containsAlias(in: "ＡＬＥＸ さん", aliases: ["alex"]), "Compatibility-width Latin text must normalize")
}

private func testSummaryPreferencesArePrivacyConservative() {
    precondition(!MeetingSummaryPreferences.shouldGenerate(consent: .undecided, enabled: true))
    precondition(!MeetingSummaryPreferences.shouldGenerate(consent: .disabled, enabled: true))
    precondition(MeetingSummaryPreferences.shouldGenerate(consent: .enabled, enabled: true))
    precondition(!MeetingSummaryPreferences.shouldGenerate(consent: .enabled, enabled: false))

    let aliases = MeetingSummaryPreferences.normalizedAliases(from: " Alex \nＡＬＥＸ\n\n小田\n小田\n" + (0..<20).map { "Name\($0)" }.joined(separator: "\n"))
    precondition(aliases.count == 10, "At most ten aliases are sent")
    precondition(aliases.prefix(2) == ["Alex", "小田"], "Blank and normalized duplicate aliases are removed")
}

private func testResponseRejectsUnknownEvidenceAndUnmentionedAlias() throws {
    let segment = SummarySourceSegment(id: "chunk-1", startSeconds: 185, text: "Alex, please send the Japanese slides by Friday.")
    let request = SummarizeRequest(
        requestID: "request-1",
        previous: nil,
        previousSourceIDs: [],
        segments: [segment],
        targetLanguage: "Simplified Chinese",
        aliases: ["Alex"],
        final: false,
        schemaVersion: 1,
        promptVersion: "2026-08-31-v1"
    )
    let valid = SummarizeResponse(content: makeContent(), processedThrough: "chunk-1", schemaVersion: 1, promptVersion: "2026-08-31-v1")
    try MeetingSummaryValidation.validate(response: valid, request: request)

    var ordinaryOnly = makeContent()
    ordinaryOnly.personalItems = []
    let noAliasRequest = SummarizeRequest(
        requestID: "request-no-alias",
        previous: nil,
        previousSourceIDs: [],
        segments: [segment],
        targetLanguage: "Simplified Chinese",
        aliases: [],
        final: false,
        schemaVersion: 1,
        promptVersion: "2026-08-31-v1"
    )
    try MeetingSummaryValidation.validate(
        response: SummarizeResponse(content: ordinaryOnly, processedThrough: "chunk-1", schemaVersion: 1, promptVersion: "2026-08-31-v1"),
        request: noAliasRequest
    )
    do {
        try MeetingSummaryValidation.validate(response: valid, request: noAliasRequest)
        preconditionFailure("Personal items must stay hidden when no aliases are configured")
    } catch MeetingSummaryValidationError.personalItemWithoutAliasEvidence {
        // Expected.
    }

    let unknown = SummarizeResponse(content: makeContent(sourceID: "chunk-404"), processedThrough: "chunk-1", schemaVersion: 1, promptVersion: "2026-08-31-v1")
    do {
        try MeetingSummaryValidation.validate(response: unknown, request: request)
        preconditionFailure("Unknown source IDs must be rejected")
    } catch MeetingSummaryValidationError.unknownSourceReference {
        // Expected.
    }

    let noMentionRequest = SummarizeRequest(
        requestID: "request-2",
        previous: nil,
        previousSourceIDs: [],
        segments: [SummarySourceSegment(id: "chunk-2", startSeconds: 200, text: "Please send the slides by Friday.")],
        targetLanguage: "Simplified Chinese",
        aliases: ["Alex"],
        final: false,
        schemaVersion: 1,
        promptVersion: "2026-08-31-v1"
    )
    let unsupportedPersonal = SummarizeResponse(content: makeContent(sourceID: "chunk-2", startSeconds: 200), processedThrough: "chunk-2", schemaVersion: 1, promptVersion: "2026-08-31-v1")
    do {
        try MeetingSummaryValidation.validate(response: unsupportedPersonal, request: noMentionRequest)
        preconditionFailure("Personal items without an explicit alias mention must be rejected")
    } catch MeetingSummaryValidationError.personalItemWithoutAliasEvidence {
        // Expected.
    }

    var wrongTimeContent = makeContent(sourceID: "chunk-1")
    wrongTimeContent.overview[0].sourceRefs = [SummarySourceRef(segmentID: "chunk-1", startSeconds: 999)]
    let wrongTime = SummarizeResponse(
        content: wrongTimeContent,
        processedThrough: "chunk-1",
        schemaVersion: 1,
        promptVersion: "2026-08-31-v1"
    )
    do {
        try MeetingSummaryValidation.validate(response: wrongTime, request: request)
        preconditionFailure("A forged source timestamp must be rejected")
    } catch MeetingSummaryValidationError.sourceReferenceTimeMismatch {
        // Expected.
    }

    var oversizedContent = makeContent()
    oversizedContent.actionItems = (0..<20).map { index in
        SummaryActionItem(
            id: "carry-\(index)",
            text: String(repeating: "c", count: 950),
            owner: nil,
            deadline: nil,
            sourceRefs: [SummarySourceRef(segmentID: "chunk-1", startSeconds: 185)]
        )
    }
    let oversized = SummarizeResponse(
        content: oversizedContent,
        processedThrough: "chunk-1",
        schemaVersion: 1,
        promptVersion: "2026-08-31-v1"
    )
    do {
        try MeetingSummaryValidation.validate(response: oversized, request: request)
        preconditionFailure("A summary that cannot be carried into the next request must be rejected")
    } catch MeetingSummaryValidationError.contentTooLarge {
        // Expected.
    }
}

private func testInterruptedRetryAllowsMovedFingerprintWhenEvidenceExists() {
    precondition(MeetingSummaryRetryPolicy.canRetry(status: .interrupted, hasSourceIndex: true, fingerprintMatches: false))
    precondition(!MeetingSummaryRetryPolicy.canRetry(status: .interrupted, hasSourceIndex: false, fingerprintMatches: false))
    precondition(MeetingSummaryRetryPolicy.canRetry(status: .failed, hasSourceIndex: false, fingerprintMatches: true))
    precondition(!MeetingSummaryRetryPolicy.canRetry(status: .finished, hasSourceIndex: true, fingerprintMatches: true))
}

do {
    try testDocumentRoundTripPreservesEvidence()
    testAliasMatchingUsesBoundariesAndCJKNormalization()
    testSummaryPreferencesArePrivacyConservative()
    try testResponseRejectsUnknownEvidenceAndUnmentionedAlias()
    testInterruptedRetryAllowsMovedFingerprintWhenEvidenceExists()
    print("PASS: meeting summary model, alias, and evidence validation")
} catch {
    fatalError("FAIL: \(error)")
}
