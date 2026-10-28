import Foundation

/// Input is cumulative audible capture time, not wall time. Quiet rooms never
/// advance the clock. The caller excludes paused, signed-out and rate-limit time.
struct TranslationConnectivityPolicy {
    private(set) var isOffline = false
    private(set) var consecutiveFailures = 0
    private(set) var audibleWithoutSuccess: TimeInterval = 0
    private var countedChunks: Set<UUID> = []
    private var previousAudio: TimeInterval = 0
    private var wasEnabled = false

    mutating func advance(audioTime: TimeInterval, enabled: Bool) {
        let elapsed = max(0, audioTime - previousAudio)
        previousAudio = audioTime
        if enabled && wasEnabled { audibleWithoutSuccess += elapsed }
        wasEnabled = enabled
        if enabled && audibleWithoutSuccess >= 15 { isOffline = true }
    }

    mutating func failed(chunk: UUID, enabled: Bool) {
        guard enabled, countedChunks.insert(chunk).inserted else { return }
        consecutiveFailures += 1
        if consecutiveFailures >= 3 { isOffline = true }
    }

    mutating func succeeded(audioTime: TimeInterval) {
        consecutiveFailures = 0
        audibleWithoutSuccess = 0
        previousAudio = audioTime
        isOffline = false
        // A retry of an already counted chunk never becomes a new failed chunk.
    }
}

/// Translator's child Tasks inherit this value, including bounded subrequests.
/// Capture it before hopping back to MainActor; never infer a chunk from callback order.
struct TranslationConnectivityRequest: Sendable, Equatable {
    let chunk: UUID
    let attempt: UUID
    static let context = TaskLocal<TranslationConnectivityRequest?>(wrappedValue: nil)
    static var current: TranslationConnectivityRequest? { context.wrappedValue }
}

/// A value owned by the single callback consumer. Never placed in TaskLocal or
/// captured by producer tasks; each attempt has its own dictionary value.
struct TranslationConnectivityStatusBuffer {
    private var forwardsStatus: Bool?
    private var pendingStatus: String?

    mutating func receiveStatus(_ text: String) -> String? {
        if let forwardsStatus { return forwardsStatus ? text : nil }
        pendingStatus = text
        return nil
    }

    mutating func classifyStatus(transient: Bool) -> String? {
        forwardsStatus = !transient
        defer { pendingStatus = nil }
        return transient ? nil : pendingStatus
    }
}
