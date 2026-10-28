import Foundation
func trAny(_ text: String) -> String { text }
func tr(_ text: String, _ args: CVarArg...) -> String { text + args.map { String(describing: $0) }.joined() }
struct TranslationTimingMetadata { var row = 0 }
enum TranslationText { static func acknowledgement(_ text: String) -> String? { nil } }
// FAILURE TYPE
// EVENT
// CHUNK
struct Meter {
    var audibleTime: TimeInterval = 0
    func snapshot() -> Meter { self }
}
struct Queue { var isEmpty = true; mutating func enqueue(_ id: UUID) { isEmpty = false } }
@MainActor final class Host {
    var running = true, starting = false, finishingCaptions = false, paused = false
    var translationPaused = false
    var sessionGen = 1, status = "running"
    enum PauseReason { case key, local }
    var pauseReason: PauseReason?, pausedAt: Date?, rateLimitedUntil: Date?
    var meter = Meter()
    var chunks: [CaptionChunk] = []
    var activeTranslationAttempts: [UUID: UUID] = [:]
    var switchingMeetingLanguage = false
    var silentTooLong = false, audioStalled = false
    var lastFinalMs = 0
    var translationRetryQueue = Queue()
    func pushChunk(_ chunk: CaptionChunk, index: Int) {}
    func updateRunningStatus() { status = "running" }
    func queueTranslatedChunksForMeetingSummary() {}
    func scheduleTranscriptSave() {}
    func retryFailedChunks() {}
    // PROPERTIES
    // METHODS
    func tick(_ audioTime: Double) { meter.audibleTime = audioTime; updateTranslationConnectivity() }
    func success() { translationSucceeded() }
    func finish(_ final: String?, idx: Int) {
        let id = chunks[idx].id
        // COMPLETION
    }
    var visibleStatus: CaptionBanner? { desktopErrorStatus ?? offlineStatus }
}
struct DisplayState { var running = true; var starting = false; var finishingCaptions = false; var translationPaused = false; var showTranslation = true, showSource = false, compactCaptions = true }
