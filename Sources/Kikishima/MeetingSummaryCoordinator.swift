import Foundation

enum CoordinatorState: Equatable, Sendable {
    case idle
    case active(generation: Int)
    case finalizing(generation: Int)
    case finished(generation: Int)
    case failed(generation: Int, message: String)

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

struct MeetingSummaryCoordinatorSnapshot: Equatable, Sendable {
    let state: CoordinatorState
    let document: MeetingSummaryDocument?
    let pendingCount: Int
    let isRequestInFlight: Bool
    let lastError: String?
    let workingRecordIDs: Set<String>
}

struct MeetingSummaryCandidate: Equatable, Sendable {
    let id: String
    let createdAt: Date
    let preferredText: String?
    let fallbackText: String
}

struct MeetingSummaryLifecycleBuffer: Sendable {
    private let startedAt: Date
    private var emittedIDs: Set<String> = []

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    mutating func acceptTranslated(id: String, createdAt: Date, text: String) -> SummarySourceSegment? {
        makeSegment(id: id, createdAt: createdAt, text: text)
    }

    mutating func retract(_ ids: Set<String>) {
        emittedIDs.subtract(ids)
    }

    mutating func finalize(_ candidates: [MeetingSummaryCandidate]) -> [SummarySourceSegment] {
        candidates.compactMap { candidate in
            makeSegment(
                id: candidate.id,
                createdAt: candidate.createdAt,
                text: candidate.preferredText ?? candidate.fallbackText
            )
        }
    }

    private mutating func makeSegment(id: String, createdAt: Date, text: String) -> SummarySourceSegment? {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty, emittedIDs.insert(id).inserted else { return nil }
        return SummarySourceSegment(
            id: id,
            startSeconds: max(0, Int(createdAt.timeIntervalSince(startedAt))),
            text: cleanText
        )
    }
}

actor MeetingSummaryCoordinator {
    private struct Session: Sendable {
        let generation: Int
        let recordID: String
        var transcriptURL: URL
        let startedAt: Date
        let targetLanguage: String
        let aliases: [String]
    }

    private static let initialDelay: TimeInterval = 3 * 60
    private static let interval: TimeInterval = 5 * 60
    private static let initialCharacters = 500
    private static let characterTrigger = 6_000
    private static let maximumRequestBytes = 60 * 1_024
    private static let maximumSegmentsBytes = 31 * 1_024
    private static let maximumSegmentPartBytes = 12 * 1_024
    private static let schemaVersion = 1
    private static let promptVersion = "2026-08-31-v1"

    private let client: any MeetingSummaryServicing
    private let store: any MeetingSummaryPersisting
    private let onChange: (@Sendable (MeetingSummaryCoordinatorSnapshot) -> Void)?
    private let encoder = JSONEncoder()
    // Actor methods can interleave at await. Keep sidecar writes in mutation order,
    // including a retract queued while an older response is being saved.
    private var persistenceTail: Task<Void, Error>?

    private func persist(_ document: MeetingSummaryDocument, beside url: URL) async throws {
        let previous = persistenceTail
        let store = self.store
        let task = Task {
            if let previous { _ = try? await previous.value }
            try await store.save(document, beside: url)
        }
        persistenceTail = task
        try await task.value
    }

    private struct DetachedWork {
        var transcriptURL: URL
        var document: MeetingSummaryDocument
        var pending: [SummarySourceSegment]
        var retryRequest: SummarizeRequest?
        var ignoredRequestIDs: Set<String>
        var lastStartedRequest: SummarizeRequest?
        var inFlight: Task<Void, Never>?
        var inFlightRequestID: String?
        var targetLanguage: String
        var aliases: [String]
        var failedDuringFinalization: Bool
    }

    private var session: Session?
    private var state: CoordinatorState = .idle
    private var document: MeetingSummaryDocument?
    private var pending: [SummarySourceSegment] = []
    private var inFlight: Task<Void, Never>?
    private var inFlightRequestID: String?
    private var lastStartedRequest: SummarizeRequest?
    private var ignoredRequestIDs: Set<String> = []
    private var detachedByGeneration: [Int: DetachedWork] = [:]
    private var retryRequest: SummarizeRequest?
    private var lastRequestAt: Date?
    private var lastError: String?
    private var failedDuringFinalization = false

    init(
        client: any MeetingSummaryServicing,
        store: any MeetingSummaryPersisting,
        onChange: (@Sendable (MeetingSummaryCoordinatorSnapshot) -> Void)? = nil
    ) {
        self.client = client
        self.store = store
        self.onChange = onChange
    }

    func begin(
        generation: Int,
        recordID: String,
        transcriptURL: URL,
        startedAt: Date,
        targetLanguage: String,
        aliases: [String]
    ) {
        if let session {
            if session.generation > generation {
                installDetachedIfNeeded(
                    generation: generation,
                    recordID: recordID,
                    transcriptURL: transcriptURL,
                    startedAt: startedAt,
                    targetLanguage: targetLanguage,
                    aliases: aliases
                )
                return
            }
            if session.generation == generation {
                inFlight?.cancel()
            } else if isWorking(recordID: recordID) {
                return
            } else {
                snapshotCurrentToDetached()
            }
        }
        inFlight = nil
        inFlightRequestID = nil
        lastStartedRequest = nil
        retryRequest = nil
        ignoredRequestIDs = []
        pending = []
        lastRequestAt = nil
        lastError = nil
        failedDuringFinalization = false
        session = Session(
            generation: generation,
            recordID: recordID,
            transcriptURL: transcriptURL,
            startedAt: startedAt,
            targetLanguage: targetLanguage,
            aliases: aliases
        )
        document = Self.makeDocument(
            recordID: recordID,
            transcriptURL: transcriptURL,
            startedAt: startedAt
        )
        state = .active(generation: generation)
        emit()
    }

    func accept(_ segment: SummarySourceSegment, generation: Int) {
        guard let session, session.generation == generation, !segment.text.isEmpty else { return }
        switch state {
        case .active, .finalizing, .failed: break
        case .idle, .finished: return
        }
        appendIfNew(Self.split(segment))
        emit()
    }

    func retract(_ ids: Set<String>, generation: Int) async {
        guard let session, session.generation == generation, !ids.isEmpty else { return }
        pending.removeAll { ids.contains($0.id) || ids.contains(Self.rootID($0.id)) }
        if let retry = retryRequest {
            let filtered = retry.segments.filter { !ids.contains($0.id) && !ids.contains(Self.rootID($0.id)) }
            retryRequest = filtered.isEmpty ? nil : {
                var next = retry
                next.segments = filtered
                return next
            }()
        }
        if let started = lastStartedRequest, started.requestID == inFlightRequestID,
           (started.segments.contains(where: { ids.contains($0.id) || ids.contains(Self.rootID($0.id)) })
            || started.previousSourceIDs.contains(where: { ids.contains($0) || ids.contains(Self.rootID($0)) })) {
            ignoredRequestIDs.insert(started.requestID)
        }
        if var document {
            for key in document.sourceIndex.keys where ids.contains(key) || ids.contains(Self.rootID(key)) {
                document.sourceIndex.removeValue(forKey: key)
            }
            document.content = Self.stripping(document.content, ids: ids)
            self.document = document
        }
        emit()
        // No session-owned mutation after this suspension: begin() may run here.
        if let document { try? await persist(document, beside: session.transcriptURL) }
    }

    func tick(now: Date, generation: Int) async {
        guard let session, session.generation == generation, inFlight == nil else { return }
        if case .failed = state {
            guard !failedDuringFinalization else { return }
            state = .active(generation: generation)
            document?.status = .active
        }
        guard case .active = state else { return }

        let request: SummarizeRequest?
        if let retryRequest {
            request = retryRequest
        } else {
            let age = now.timeIntervalSince(session.startedAt)
            guard age >= Self.initialDelay, !pending.isEmpty else { return }
            let characters = pending.reduce(0) { $0 + $1.text.count }
            if document?.processedThrough == nil {
                guard characters >= Self.initialCharacters else { return }
            } else {
                let elapsed = lastRequestAt.map { now.timeIntervalSince($0) } ?? Self.interval
                guard elapsed >= Self.interval || characters >= Self.characterTrigger else { return }
            }
            request = makeRequest(final: false)
        }
        guard let request else { return }
        let task = start(request, triggeredAt: now, generation: generation)
        await task.value
    }

    func finalize(
        remaining: [SummarySourceSegment],
        transcriptURL: URL,
        generation: Int
    ) async {
        if session?.generation != generation {
            await finalizeDetached(remaining: remaining, transcriptURL: transcriptURL, generation: generation)
            return
        }
        guard var session, session.generation == generation else { return }
        if case .finished = state { return }
        session.transcriptURL = transcriptURL
        self.session = session
        appendIfNew(remaining.flatMap(Self.split))
        state = .finalizing(generation: generation)
        document?.status = .finalizing
        failedDuringFinalization = false
        emit()

        if let task = inFlight { await task.value }
        if self.session?.generation != generation {
            await finalizeDetached(remaining: remaining, transcriptURL: transcriptURL, generation: generation)
            return
        }
        if case .failed = state { return }

        while !pending.isEmpty {
            state = .finalizing(generation: generation)
            document?.status = .finalizing
            guard let request = retryRequest ?? makeRequest(final: true) else {
                failWithoutRequest(generation: generation, message: "summary_request_too_large")
                return
            }
            let task = start(request, triggeredAt: Date(), generation: generation)
            await task.value
            if self.session?.generation != generation {
                await finalizeDetached(remaining: [], transcriptURL: transcriptURL, generation: generation)
                return
            }
            if case .failed = state { return }
        }

        guard var finalDocument = document, let currentSession = self.session else { return }
        if finalDocument.isFinal {
            state = .finished(generation: generation)
            emit()
            return
        }
        finalDocument.isFinal = true
        finalDocument.status = .finished
        finalDocument.updatedAt = Date()
        document = finalDocument
        do {
            try await persist(finalDocument, beside: currentSession.transcriptURL)
            if self.session?.generation != generation { return }
            state = .finished(generation: generation)
            lastError = nil
            emit()
        } catch {
            if self.session?.generation != generation { return }
            failWithoutRequest(generation: generation, message: String(describing: error))
        }
    }

    func retryFinal(transcriptURL: URL, generation: Int) async {
        guard session?.generation == generation else { return }
        if case .finished = state { return }
        guard failedDuringFinalization || state.isFailed else { return }
        await finalize(remaining: [], transcriptURL: transcriptURL, generation: generation)
    }

    func snapshot() -> MeetingSummaryCoordinatorSnapshot {
        snapshotValue()
    }

    func isWorking(recordID: String) -> Bool {
        workingRecordIDs().contains(recordID)
    }

    private func start(_ request: SummarizeRequest, triggeredAt: Date, generation: Int) -> Task<Void, Never> {
        let client = self.client
        let task = Task { [weak self] in
            do {
                let response = try await client.summarize(request)
                await self?.finishSuccess(response, request: request, triggeredAt: triggeredAt, generation: generation)
            } catch {
                await self?.finishFailure(request: request, generation: generation, message: String(describing: error))
            }
        }
        if session?.generation == generation {
            inFlightRequestID = request.requestID
            lastStartedRequest = request
            inFlight = task
            emit()
        } else if var work = detachedByGeneration[generation] {
            work.inFlightRequestID = request.requestID
            work.lastStartedRequest = request
            work.inFlight = task
            detachedByGeneration[generation] = work
        }
        return task
    }

    private func finishSuccess(
        _ response: SummarizeResponse,
        request: SummarizeRequest,
        triggeredAt: Date,
        generation: Int
    ) async {
        if isIgnored(request.requestID, generation: generation) {
            clearIgnored(request.requestID, generation: generation)
            clearInFlight(generation: generation, requestID: request.requestID)
            if session?.generation == generation { emit() }
            return
        }
        if session?.generation != generation {
            await applyDetachedSuccess(response, request: request, triggeredAt: triggeredAt, generation: generation)
            return
        }
        guard inFlightRequestID == request.requestID,
              var updated = document,
              let transcriptURL = session?.transcriptURL else { return }

        let stayingFinalizing: Bool
        if case .finalizing = state { stayingFinalizing = true } else { stayingFinalizing = false }
        updated.content = response.content
        updated.processedThrough = response.processedThrough
        for segment in request.segments { updated.sourceIndex[segment.id] = segment }
        updated.updatedAt = triggeredAt
        updated.isFinal = request.final
        updated.status = request.final ? .finished : stayingFinalizing ? .finalizing : .active

        do {
            try await persist(updated, beside: transcriptURL)
        } catch {
            await finishFailure(request: request, generation: generation, message: String(describing: error))
            return
        }
        if isIgnored(request.requestID, generation: generation) {
            clearIgnored(request.requestID, generation: generation)
            clearInFlight(generation: generation, requestID: request.requestID)
            emit()
            return
        }
        if session?.generation != generation {
            await applyDetachedSuccess(response, request: request, triggeredAt: triggeredAt, generation: generation)
            return
        }
        guard inFlightRequestID == request.requestID else { return }
        document = updated
        let sentIDs = Set(request.segments.map(\.id))
        pending.removeAll { sentIDs.contains($0.id) }
        retryRequest = nil
        lastRequestAt = triggeredAt
        lastError = nil
        inFlight = nil
        inFlightRequestID = nil
        failedDuringFinalization = false
        state = request.final
            ? .finished(generation: generation)
            : stayingFinalizing ? .finalizing(generation: generation) : .active(generation: generation)
        emit()
    }

    private func finishFailure(request: SummarizeRequest, generation: Int, message: String) async {
        if isIgnored(request.requestID, generation: generation) {
            clearIgnored(request.requestID, generation: generation)
            clearInFlight(generation: generation, requestID: request.requestID)
            if session?.generation == generation { emit() }
            return
        }
        if session?.generation != generation {
            await applyDetachedFailure(request: request, generation: generation, message: message)
            return
        }
        guard inFlightRequestID == request.requestID else { return }
        finishFailureState(request: request, generation: generation, message: message)
        if var failedDocument = document, let transcriptURL = session?.transcriptURL {
            for segment in pending { failedDocument.sourceIndex[segment.id] = segment }
            document = failedDocument
            try? await persist(failedDocument, beside: transcriptURL)
        }
    }

    private func finishFailureState(request: SummarizeRequest, generation: Int, message: String) {
        let wasFinalizing: Bool
        if case .finalizing = state { wasFinalizing = true } else { wasFinalizing = false }
        retryRequest = request
        failedDuringFinalization = request.final || wasFinalizing
        lastError = message
        document?.isFinal = request.final || wasFinalizing
        document?.status = .failed
        state = .failed(generation: generation, message: message)
        inFlight = nil
        inFlightRequestID = nil
        emit()
    }

    private func failWithoutRequest(generation: Int, message: String) {
        failedDuringFinalization = true
        lastError = message
        document?.status = .failed
        state = .failed(generation: generation, message: message)
        emit()
    }

    private func makeRequest(final: Bool) -> SummarizeRequest? {
        guard let session, let document else { return nil }
        return makeRequest(
            final: final,
            document: document,
            pending: pending,
            targetLanguage: session.targetLanguage,
            aliases: session.aliases
        )
    }

    private func makeRequest(
        final: Bool,
        document: MeetingSummaryDocument,
        pending: [SummarySourceSegment],
        targetLanguage: String,
        aliases: [String]
    ) -> SummarizeRequest? {
        guard !pending.isEmpty else { return nil }
        let previous = Self.hasContent(document.content) ? document.content : nil
        let previousSourceIDs = Self.referencedSourceIDs(in: document.content)
        let requestID = UUID().uuidString.lowercased()
        var selected: [SummarySourceSegment] = []

        for segment in pending {
            let candidate = selected + [segment]
            guard (try? encoder.encode(candidate).count).map({ $0 <= Self.maximumSegmentsBytes }) == true else { break }
            let candidateRequest = SummarizeRequest(
                requestID: requestID,
                previous: previous,
                previousSourceIDs: previousSourceIDs,
                segments: candidate,
                targetLanguage: targetLanguage,
                aliases: aliases,
                final: final && candidate.count == pending.count,
                schemaVersion: Self.schemaVersion,
                promptVersion: Self.promptVersion,
                costSessionID: UUID(uuidString: document.recordID)?.uuidString.lowercased()
            )
            guard (try? encoder.encode(candidateRequest).count).map({ $0 <= Self.maximumRequestBytes }) == true else { break }
            selected = candidate
        }
        guard !selected.isEmpty else { return nil }
        return SummarizeRequest(
            requestID: requestID,
            previous: previous,
            previousSourceIDs: previousSourceIDs,
            segments: selected,
            targetLanguage: targetLanguage,
            aliases: aliases,
            final: final && selected.count == pending.count,
            schemaVersion: Self.schemaVersion,
            promptVersion: Self.promptVersion,
            costSessionID: UUID(uuidString: document.recordID)?.uuidString.lowercased()
        )
    }

    private func snapshotCurrentToDetached() {
        guard let session, let document else { return }
        detachedByGeneration[session.generation] = DetachedWork(
            transcriptURL: session.transcriptURL,
            document: document,
            pending: pending,
            retryRequest: retryRequest,
            ignoredRequestIDs: ignoredRequestIDs,
            lastStartedRequest: lastStartedRequest,
            inFlight: inFlight,
            inFlightRequestID: inFlightRequestID,
            targetLanguage: session.targetLanguage,
            aliases: session.aliases,
            failedDuringFinalization: failedDuringFinalization
        )
    }

    private func installDetachedIfNeeded(
        generation: Int,
        recordID: String,
        transcriptURL: URL,
        startedAt: Date,
        targetLanguage: String,
        aliases: [String]
    ) {
        guard detachedByGeneration[generation] == nil else { return }
        detachedByGeneration[generation] = DetachedWork(
            transcriptURL: transcriptURL,
            document: Self.makeDocument(recordID: recordID, transcriptURL: transcriptURL, startedAt: startedAt),
            pending: [],
            retryRequest: nil,
            ignoredRequestIDs: [],
            lastStartedRequest: nil,
            inFlight: nil,
            inFlightRequestID: nil,
            targetLanguage: targetLanguage,
            aliases: aliases,
            failedDuringFinalization: false
        )
    }

    private func finalizeDetached(
        remaining: [SummarySourceSegment],
        transcriptURL: URL,
        generation: Int
    ) async {
        guard var work = detachedByGeneration[generation] else { return }
        work.transcriptURL = transcriptURL
        work.pending = appending(remaining.flatMap(Self.split), to: work.pending, document: work.document)
        work.document.status = .finalizing
        work.failedDuringFinalization = false
        detachedByGeneration[generation] = work
        emit()

        if let task = work.inFlight { await task.value }

        while let current = detachedByGeneration[generation] {
            if let task = current.inFlight {
                await task.value
                continue
            }
            if current.document.status == .failed {
                detachedByGeneration[generation] = nil
                emit()
                return
            }
            if current.pending.isEmpty {
                var finalDocument = current.document
                if !finalDocument.isFinal {
                    finalDocument.isFinal = true
                    finalDocument.status = .finished
                    finalDocument.updatedAt = Date()
                    try? await persist(finalDocument, beside: current.transcriptURL)
                }
                detachedByGeneration[generation] = nil
                emit()
                return
            }
            guard let request = makeRequest(
                final: true,
                document: current.document,
                pending: current.pending,
                targetLanguage: current.targetLanguage,
                aliases: current.aliases
            ) else {
                var failed = current
                failed.document.status = .failed
                failed.failedDuringFinalization = true
                try? await persist(failed.document, beside: failed.transcriptURL)
                detachedByGeneration[generation] = nil
                emit()
                return
            }
            let task = start(request, triggeredAt: Date(), generation: generation)
            await task.value
        }
    }

    private func applyDetachedSuccess(
        _ response: SummarizeResponse,
        request: SummarizeRequest,
        triggeredAt: Date,
        generation: Int
    ) async {
        guard var work = detachedByGeneration[generation] else { return }
        guard work.inFlightRequestID == request.requestID || work.inFlightRequestID == nil else { return }
        var updated = work.document
        updated.content = response.content
        updated.processedThrough = response.processedThrough
        for segment in request.segments { updated.sourceIndex[segment.id] = segment }
        updated.updatedAt = triggeredAt
        updated.isFinal = request.final && work.pending.filter { pending in
            !request.segments.contains(where: { $0.id == pending.id })
        }.isEmpty
        updated.status = updated.isFinal ? .finished : .finalizing
        try? await persist(updated, beside: work.transcriptURL)
        // finalizeDetached can append the stopped meeting's tail while saving.
        // Resume from its current queue instead of restoring the pre-save copy.
        guard let current = detachedByGeneration[generation],
              current.inFlightRequestID == request.requestID else { return }
        work = current
        let sentIDs = Set(request.segments.map(\.id))
        work.pending.removeAll { sentIDs.contains($0.id) }
        updated.isFinal = request.final && work.pending.isEmpty
        updated.status = updated.isFinal ? .finished : .finalizing
        work.retryRequest = nil
        work.document = updated
        work.inFlight = nil
        work.inFlightRequestID = nil
        work.failedDuringFinalization = false
        if updated.status == .finished, work.pending.isEmpty {
            detachedByGeneration[generation] = nil
        } else {
            detachedByGeneration[generation] = work
        }
        emit()
    }

    private func applyDetachedFailure(request: SummarizeRequest, generation: Int, message: String) async {
        guard var work = detachedByGeneration[generation] else { return }
        guard work.inFlightRequestID == request.requestID else { return }
        work.retryRequest = request
        work.failedDuringFinalization = true
        work.document.status = .failed
        work.inFlight = nil
        work.inFlightRequestID = nil
        for segment in work.pending { work.document.sourceIndex[segment.id] = segment }
        try? await persist(work.document, beside: work.transcriptURL)
        detachedByGeneration[generation] = nil
        emit()
    }

    private func isIgnored(_ requestID: String, generation: Int) -> Bool {
        if session?.generation == generation {
            return ignoredRequestIDs.contains(requestID)
        }
        return detachedByGeneration[generation]?.ignoredRequestIDs.contains(requestID) == true
    }

    private func clearIgnored(_ requestID: String, generation: Int) {
        if session?.generation == generation {
            ignoredRequestIDs.remove(requestID)
            return
        }
        guard var work = detachedByGeneration[generation] else { return }
        work.ignoredRequestIDs.remove(requestID)
        detachedByGeneration[generation] = work
    }

    private func clearInFlight(generation: Int, requestID: String) {
        if session?.generation == generation, inFlightRequestID == requestID {
            inFlight = nil
            inFlightRequestID = nil
            return
        }
        guard var work = detachedByGeneration[generation], work.inFlightRequestID == requestID else { return }
        work.inFlight = nil
        work.inFlightRequestID = nil
        detachedByGeneration[generation] = work
    }

    private func appending(
        _ segments: [SummarySourceSegment],
        to pending: [SummarySourceSegment],
        document: MeetingSummaryDocument?
    ) -> [SummarySourceSegment] {
        var pending = pending
        var seen = Set(pending.map(\.id))
        if let keys = document?.sourceIndex.keys { seen.formUnion(keys) }
        for segment in segments where seen.insert(segment.id).inserted {
            pending.append(segment)
        }
        return pending
    }

    private static func makeDocument(recordID: String, transcriptURL: URL, startedAt: Date) -> MeetingSummaryDocument {
        MeetingSummaryDocument(
            recordID: recordID,
            transcriptFileName: transcriptURL.lastPathComponent,
            content: emptyContent(),
            sourceIndex: [:],
            processedThrough: nil,
            schemaVersion: schemaVersion,
            promptVersion: promptVersion,
            sourceFingerprint: nil,
            updatedAt: startedAt,
            isFinal: false,
            status: .active
        )
    }

    private func appendIfNew(_ segments: [SummarySourceSegment]) {
        let known = Set(pending.map(\.id)).union(document?.sourceIndex.keys ?? Dictionary<String, SummarySourceSegment>().keys)
        var seen = known
        for segment in segments where !seen.contains(segment.id) {
            pending.append(segment)
            seen.insert(segment.id)
        }
    }

    private func emit() {
        onChange?(snapshotValue())
    }

    private func snapshotValue() -> MeetingSummaryCoordinatorSnapshot {
        MeetingSummaryCoordinatorSnapshot(
            state: state,
            document: document,
            pendingCount: pending.count,
            isRequestInFlight: inFlight != nil,
            lastError: lastError,
            workingRecordIDs: workingRecordIDs()
        )
    }

    private func workingRecordIDs() -> Set<String> {
        var ids: Set<String> = []
        if let document {
            switch state {
            case .active, .finalizing:
                ids.insert(document.recordID)
            case .failed, .idle, .finished:
                if inFlight != nil { ids.insert(document.recordID) }
            }
        }
        for work in detachedByGeneration.values {
            let busy = work.inFlight != nil
                || !work.pending.isEmpty
                || work.document.status == .active
                || work.document.status == .finalizing
            if busy { ids.insert(work.document.recordID) }
        }
        return ids
    }

    private static func emptyContent() -> MeetingSummaryContent {
        MeetingSummaryContent(
            overview: [],
            currentState: [],
            decisions: [],
            actionItems: [],
            personalItems: [],
            openQuestions: []
        )
    }

    private static func hasContent(_ content: MeetingSummaryContent) -> Bool {
        !content.overview.isEmpty || !content.currentState.isEmpty || !content.decisions.isEmpty
            || !content.actionItems.isEmpty || !content.personalItems.isEmpty || !content.openQuestions.isEmpty
    }

    private static func referencedSourceIDs(in content: MeetingSummaryContent) -> [String] {
        let blocks = content.overview + content.currentState + content.decisions + content.personalItems + content.openQuestions
        let ids = blocks.flatMap(\.sourceRefs).map(\.segmentID)
            + content.actionItems.flatMap(\.sourceRefs).map(\.segmentID)
        return Array(Set(ids)).sorted()
    }

    private static func stripping(_ content: MeetingSummaryContent, ids: Set<String>) -> MeetingSummaryContent {
        func matches(_ id: String) -> Bool {
            ids.contains(id) || ids.contains(rootID(id))
        }
        func filterBlocks(_ blocks: [SummaryBlock]) -> [SummaryBlock] {
            blocks.compactMap { block in
                if block.sourceRefs.isEmpty { return block }
                let refs = block.sourceRefs.filter { !matches($0.segmentID) }
                guard !refs.isEmpty else { return nil }
                var copy = block
                copy.sourceRefs = refs
                return copy
            }
        }
        func filterActions(_ items: [SummaryActionItem]) -> [SummaryActionItem] {
            items.compactMap { item in
                if item.sourceRefs.isEmpty { return item }
                let refs = item.sourceRefs.filter { !matches($0.segmentID) }
                guard !refs.isEmpty else { return nil }
                var copy = item
                copy.sourceRefs = refs
                return copy
            }
        }
        var content = content
        content.overview = filterBlocks(content.overview)
        content.currentState = filterBlocks(content.currentState)
        content.decisions = filterBlocks(content.decisions)
        content.actionItems = filterActions(content.actionItems)
        content.personalItems = filterBlocks(content.personalItems)
        content.openQuestions = filterBlocks(content.openQuestions)
        return content
    }

    private static func rootID(_ id: String) -> String {
        if let idx = id.lastIndex(of: ":"), id[id.index(after: idx)...].allSatisfy(\.isNumber) {
            return String(id[..<idx])
        }
        return id
    }

    private static func split(_ segment: SummarySourceSegment) -> [SummarySourceSegment] {
        guard segment.text.lengthOfBytes(using: .utf8) > maximumSegmentPartBytes else { return [segment] }
        var parts: [String] = []
        var current = ""
        var currentBytes = 0
        for character in segment.text {
            let value = String(character)
            let valueBytes = value.lengthOfBytes(using: .utf8)
            if currentBytes + valueBytes > maximumSegmentPartBytes, !current.isEmpty {
                parts.append(current)
                current = ""
                currentBytes = 0
            }
            current += value
            currentBytes += valueBytes
        }
        if !current.isEmpty { parts.append(current) }
        let baseID = String(segment.id.prefix(96))
        return parts.enumerated().map { index, text in
            SummarySourceSegment(
                id: "\(baseID):\(index)",
                startSeconds: segment.startSeconds,
                text: text
            )
        }
    }
}
