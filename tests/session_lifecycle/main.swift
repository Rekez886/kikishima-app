import CoreGraphics
import Foundation

var count = 0
func check(_ value: Bool, _ message: String) {
    precondition(value, message)
    count += 1
}

// A quiet meeting must not dismiss the popover while the user adjusts captions.
for hasContent in [false, true] {
    for dormant in [false, true] {
        check(CaptionAppearance.wantsExpanded(hasContent: hasContent, dormant: dormant,
            settingsOpen: true, paused: false, hasBanner: false),
            "settings remain available even after silence or a transcript revision")
    }
}
check(!CaptionAppearance.wantsExpanded(hasContent: true, dormant: true,
    settingsOpen: false, paused: false, hasBanner: false), "quiet captions collapse after settings close and timeout")
check(CaptionAppearance.wantsExpanded(hasContent: true, dormant: false,
    settingsOpen: false, paused: false, hasBanner: false), "fresh activity expands captions")
check(CaptionAppearance.wantsExpanded(hasContent: true, dormant: true,
    settingsOpen: false, paused: true, hasBanner: false), "pause remains visible")
check(CaptionAppearance.wantsExpanded(hasContent: true, dormant: true,
    settingsOpen: false, paused: false, hasBanner: true), "error remains visible")
check(!CaptionAppearance.wantsExpanded(hasContent: false, dormant: false,
    settingsOpen: false, paused: false, hasBanner: false), "empty island remains a capsule")

var gate = ExclusiveEngineStart()
check(gate.begin(), "first resume claims the engine start")
check(gate.inFlight, "in-flight while resuming")
check(!gate.begin(), "second resume is ignored until the first finishes")
gate.end()
check(!gate.inFlight, "gate clears after resume finishes")
check(gate.begin(), "a later resume can start")
gate.end()

check(
    !ExclusiveEngineStart.shouldStopMeeting(cancelled: true, sessionStillCurrent: true),
    "cancelled overlapping start must not stop the meeting"
)
check(
    ExclusiveEngineStart.shouldStopMeeting(cancelled: false, sessionStillCurrent: true),
    "a real start failure on the current session stops the meeting"
)
check(
    !ExclusiveEngineStart.shouldStopMeeting(cancelled: false, sessionStillCurrent: false),
    "stale start failure after stop must not stop a newer session"
)
check(
    !ExclusiveEngineStart.shouldStopMeeting(cancelled: true, sessionStillCurrent: false),
    "cancelled start after stop is ignored"
)

check(SessionControls.canPause(switchingMeetingLanguage: false, resuming: false), "idle running session can pause")
check(!SessionControls.canPause(switchingMeetingLanguage: true, resuming: false), "pause during language switch is ignored")
check(!SessionControls.canPause(switchingMeetingLanguage: false, resuming: true), "pause during resume is ignored")
check(SessionControls.canChangeMeetingLanguage(starting: false, switchingMeetingLanguage: false, resuming: false), "idle running session can change language")
check(!SessionControls.canChangeMeetingLanguage(starting: false, switchingMeetingLanguage: false, resuming: true), "language change during resume is ignored")
check(!SessionControls.canChangeMeetingLanguage(starting: true, switchingMeetingLanguage: false, resuming: false), "language change during start is ignored")
check(SessionControls.hotkeyAction(running: true, starting: false, paused: true, resuming: false) == .resume, "paused hotkey continues")
check(SessionControls.hotkeyAction(running: true, starting: false, paused: true, resuming: true) == .stop, "hotkey stops a resume in flight")
check(SessionControls.hotkeyAction(running: true, starting: false, paused: false, resuming: false) == .stop, "running hotkey stops")
check(SessionControls.hotkeyAction(running: false, starting: false, paused: false, resuming: false) == .start, "idle hotkey starts")
check(SessionControls.shouldRunReconnect(paused: false, switchingMeetingLanguage: false, resuming: false), "reconnect runs while captions are live")
check(!SessionControls.shouldRunReconnect(paused: true, switchingMeetingLanguage: false, resuming: false), "reconnect after pause is dropped")
check(!SessionControls.shouldRunReconnect(paused: false, switchingMeetingLanguage: true, resuming: false), "reconnect during language switch is dropped")
check(SessionControls.shouldRebuildAudioTap(running: true, paused: false, resuming: false, switchingMeetingLanguage: false, tapAlreadyRunning: false), "live session rebuilds the tap")
check(!SessionControls.shouldRebuildAudioTap(running: true, paused: true, resuming: false, switchingMeetingLanguage: false, tapAlreadyRunning: false), "paused session does not rebuild the tap")
check(!SessionControls.shouldRebuildAudioTap(running: true, paused: false, resuming: true, switchingMeetingLanguage: false, tapAlreadyRunning: false), "resume in flight does not rebuild the tap")
check(!SessionControls.shouldRebuildAudioTap(running: true, paused: false, resuming: false, switchingMeetingLanguage: true, tapAlreadyRunning: false), "language switch does not rebuild the tap")
check(!SessionControls.shouldRebuildAudioTap(running: true, paused: false, resuming: false, switchingMeetingLanguage: false, tapAlreadyRunning: true), "already-running tap is left alone")
check(SessionControls.canRetryMeetingSummary(running: false, starting: false, recordBusy: false), "idle app can retry a failed summary")
check(!SessionControls.canRetryMeetingSummary(running: true, starting: false, recordBusy: false), "live meeting blocks summary retry")
check(!SessionControls.canRetryMeetingSummary(running: false, starting: true, recordBusy: false), "starting blocks summary retry")
check(!SessionControls.canRetryMeetingSummary(running: false, starting: false, recordBusy: true), "in-flight previous summary blocks retry of that record")
check(SessionControls.canStartNewMeeting(previousStartInFlight: false, previousTranscriptPending: false), "idle app can start")
check(!SessionControls.canStartNewMeeting(previousStartInFlight: true, previousTranscriptPending: false), "start waits for previous start task")
check(!SessionControls.canStartNewMeeting(previousStartInFlight: false, previousTranscriptPending: true), "start waits for previous transcript save")
check(SessionControls.shouldTickChunks(running: true, paused: false, switchingMeetingLanguage: false), "live session keeps chunking")
check(!SessionControls.shouldTickChunks(running: true, paused: true, switchingMeetingLanguage: false), "pause already froze chunking")
check(!SessionControls.shouldTickChunks(running: true, paused: false, switchingMeetingLanguage: true), "language switch must freeze chunking")
check(!SessionControls.resolvedBubbleMode(stored: true), "pre-0.30 bubbleMode must not start ScreenCapture")
check(!SessionControls.resolvedBubbleMode(stored: false), "bubble mode stays off")
let migrated = SessionTokenMigration.resolve(keychain: "", defaults: "legacy-session")
check(migrated.token == "legacy-session" && migrated.persistKeychain == "legacy-session" && migrated.clearDefaultsIfPersisted, "legacy UserDefaults session moves to Keychain")
let already = SessionTokenMigration.resolve(keychain: "keychain-session", defaults: "stale")
check(already.token == "keychain-session" && already.persistKeychain == nil && already.clearDefaultsIfPersisted, "Keychain wins and UserDefaults can be cleared")
let empty = SessionTokenMigration.resolve(keychain: "", defaults: "")
check(empty.token.isEmpty && empty.persistKeychain == nil && !empty.clearDefaultsIfPersisted, "signed-out stays empty")
check(!SessionTokenMigration.shouldClearDefaults(keychainWriteSucceeded: false, keychainAlreadyHeldToken: false), "failed Keychain write keeps UserDefaults")
check(SessionTokenMigration.shouldClearDefaults(keychainWriteSucceeded: true, keychainAlreadyHeldToken: false), "successful write drops plaintext")
check(SessionTokenMigration.shouldClearDefaults(keychainWriteSucceeded: false, keychainAlreadyHeldToken: true), "token already in Keychain can drop stale defaults")
check(SessionTokenMigration.fallbackToDefaults(token: "live-session", keychainWriteSucceeded: false) == "live-session", "failed save keeps a UserDefaults fallback")
check(SessionTokenMigration.fallbackToDefaults(token: "live-session", keychainWriteSucceeded: true) == nil, "successful save does not keep plaintext")
check(SessionTokenMigration.fallbackToDefaults(token: "", keychainWriteSucceeded: false) == nil, "sign-out does not write a fallback")
check(SessionControls.resolvedAPIBase("") == SessionControls.productionAPI, "empty API falls back to production")
check(SessionControls.resolvedAPIBase("https://api.kikishima.com/") == SessionControls.productionAPI, "production host stays pinned")
check(SessionControls.resolvedAPIBase("https://evil.example") == SessionControls.productionAPI, "non-loopback hosts cannot override the API")
check(SessionControls.resolvedAPIBase("http://127.0.0.1:9") == "http://127.0.0.1:9" || SessionControls.resolvedAPIBase("http://127.0.0.1:9") == SessionControls.productionAPI, "loopback override is debug-only")

let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
check(CaptionIslandLayout.notchWidth(auxiliaryTopLeft: .zero, auxiliaryTopRight: .zero) == 0, "no housing means no notch")
let left = CGRect(x: 0, y: 944, width: 640, height: 38)
let right = CGRect(x: 872, y: 944, width: 640, height: 38)
check(abs(CaptionIslandLayout.notchWidth(auxiliaryTopLeft: left, auxiliaryTopRight: right) - 232) < 0.5, "notch is the gap between menu-bar sides")
let cx = CaptionIslandLayout.centerX(visibleFrame: visible, auxiliaryTopLeft: left, auxiliaryTopRight: right)
check(abs(cx - 756) < 0.5, "island centers on the camera housing")
let idle = CaptionIslandLayout.idleRect(visibleFrame: visible, centerX: cx, notchWidth: 232)
let expanded = CaptionIslandLayout.expandedRect(visibleFrame: visible, centerX: cx, widthFraction: 0.85, compact: true)
check(abs(idle.maxY - expanded.maxY) < 0.5, "expanded island keeps the top edge on the camera line")
check(expanded.height > idle.height, "translation grows the island downward")
check(idle.midX > 700 && idle.midX < 812, "idle capsule stays under the camera")
let noNotch = CaptionIslandLayout.idleRect(
    visibleFrame: visible,
    centerX: CaptionIslandLayout.centerX(visibleFrame: visible, auxiliaryTopLeft: .zero, auxiliaryTopRight: .zero),
    notchWidth: 0
)
check(abs(noNotch.midX - visible.midX) < 0.5, "no-notch screens pin the idle island to the top center")

check(CaptionAppearance.storedFontLevel(fontLevel: "large", fontPoints: 16) == .large, "stored font level wins over old points")
check(CaptionAppearance.storedFontLevel(fontLevel: nil, fontPoints: 0) == .medium, "unset font is medium")
check(CaptionAppearance.storedFontLevel(fontLevel: nil, fontPoints: 15) == .small, "old 15pt snaps to small")
check(CaptionAppearance.storedFontLevel(fontLevel: nil, fontPoints: 28) == .large, "old 28pt snaps to large")
check(CaptionAppearance.storedWidthLevel(widthLevel: nil, fraction: nil) == .medium, "unset width is medium")
check(CaptionAppearance.storedWidthLevel(widthLevel: nil, fraction: 0.2) == .small, "old 20% snaps to narrow")
check(CaptionAppearance.storedWidthLevel(widthLevel: nil, fraction: 0.85) == .large, "old 85% snaps to wide")
check(CaptionAppearance.storedHeightLevel(heightLevel: nil, points: 0) == .medium, "unset height is medium")
check(CaptionAppearance.storedHeightLevel(heightLevel: nil, points: 96) == .small, "old short height snaps to low")
check(CaptionAppearance.storedHeightLevel(heightLevel: nil, points: 240) == .large, "old tall height snaps to high")
check(CaptionAppearance.storedCollapseLevel(collapseLevel: nil, seconds: nil) == .medium, "unset collapse is medium")
check(CaptionAppearance.storedCollapseLevel(collapseLevel: nil, seconds: 0) == .off, "0 seconds is off")
check(CaptionAppearance.fontSize(.medium) == 18, "medium translation size stays 18")
check(CaptionAppearance.widthFraction(.small) < CaptionAppearance.widthFraction(.medium), "narrow is smaller than medium")
check(CaptionAppearance.islandHeight(.large) > CaptionAppearance.islandHeight(.medium), "high is taller than medium")
check(CaptionAppearance.collapseSeconds(.off) == 0, "off does not auto-collapse")

let laptopCaptions = CaptionIslandLayout.notchContentSize(
    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), widthFraction: 0.5, height: 148)
let externalCaptions = CaptionIslandLayout.notchContentSize(
    visibleFrame: CGRect(x: 1440, y: 0, width: 2560, height: 1440), widthFraction: 0.5, height: 148)
check(laptopCaptions.width + 30 == 560, "laptop final capsule width is 560pt")
check(externalCaptions.width + 30 == 560, "external final capsule width is 560pt")
check(externalCaptions.height == laptopCaptions.height, "display changes preserve selected height")
check(CaptionIslandLayout.notchContentSize(visibleFrame: CGRect(x: 0, y: 0, width: 240, height: 400),
    widthFraction: 0.8, height: 100).width + 30 == 224, "minimum width never overflows a small host display")

let desktopVisible = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
let draggedDesktop = CGRect(x: 1700, y: 75, width: 1100, height: 286)
let selectedNarrow = CaptionIslandLayout.desktopFrame(selectingWidth: 0.26,
    current: draggedDesktop, visibleFrame: desktopVisible)
check(abs(selectedNarrow.width - 499.2) < 0.001, "explicit width replaces manually dragged width")
check(selectedNarrow.height == draggedDesktop.height, "width selection preserves dragged height")
check(selectedNarrow.origin == draggedDesktop.origin, "width selection preserves position when it fits")
let selectedWide = CaptionIslandLayout.desktopFrame(selectingWidth: 0.8,
    current: CGRect(x: 2900, y: 75, width: 480, height: 286), visibleFrame: desktopVisible)
check(selectedWide.maxX == desktopVisible.maxX, "growing near the edge stays on host display")
check(selectedWide.minY == 75, "horizontal clamp does not move the window vertically")

print("PASS: \(count) exclusive resume, cancellation and pause-gate checks")
