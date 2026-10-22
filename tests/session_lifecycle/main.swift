import CoreGraphics
import Foundation

var count = 0
func check(_ value: Bool, _ message: String) {
    precondition(value, message)
    count += 1
}

// The menu panel is independent of island expansion and dormancy.
for hasContent in [false, true] {
    for dormant in [false, true] {
        check(CaptionAppearance.wantsExpanded(hasContent: hasContent, dormant: dormant,
            paused: false, hasBanner: false) == (hasContent && !dormant),
            "island expansion follows content and activity, without a settings popover override")
    }
}
check(!CaptionAppearance.wantsExpanded(hasContent: true, dormant: true,
    paused: false, hasBanner: false), "quiet captions collapse after timeout")
check(CaptionAppearance.wantsExpanded(hasContent: true, dormant: false,
    paused: false, hasBanner: false), "fresh activity expands captions")
check(CaptionAppearance.wantsExpanded(hasContent: true, dormant: true,
    paused: true, hasBanner: false), "pause remains visible")
check(CaptionAppearance.wantsExpanded(hasContent: true, dormant: true,
    paused: false, hasBanner: true), "error remains visible")
check(!CaptionAppearance.wantsExpanded(hasContent: false, dormant: false,
    paused: false, hasBanner: false), "empty island remains a capsule")

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
let expanded = CaptionIslandLayout.expandedRect(visibleFrame: visible, centerX: cx, widthLevel: .large, compact: true)
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
    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), widthLevel: .medium, heightLevel: .medium)
let externalCaptions = CaptionIslandLayout.notchContentSize(
    visibleFrame: CGRect(x: 1440, y: 0, width: 2560, height: 1440), widthLevel: .medium, heightLevel: .medium)
check(laptopCaptions.width + 30 == 560, "laptop capsule uses fixed medium width")
check(externalCaptions.width + 30 == 560, "external capsule uses fixed medium width")
check(externalCaptions.height == laptopCaptions.height, "display changes preserve selected height")
check(CaptionIslandLayout.notchContentSize(visibleFrame: CGRect(x: 0, y: 0, width: 240, height: 400),
    widthLevel: .large, heightLevel: .small).width + 30 == 216, "minimum width never overflows a small host display")
for screenWidth in [240.0, 600, 800, 1024, 1280, 1440, 1920, 2560] {
    let frame = CGRect(x: 100, y: 0, width: screenWidth, height: 900)
    let sizes = CaptionSizeLevel.allCases.map { level in
        CaptionIslandLayout.notchContentSize(visibleFrame: frame,
            widthLevel: level, heightLevel: level)
    }
    check(sizes[0].width < sizes[1].width && sizes[1].width < sizes[2].width, "three width choices produce distinct sizes")
    check(sizes.map(\.height) == [100, 148, 240], "normal visible height preserves all three height presets")
    check(sizes.allSatisfy { $0.width + 30 <= screenWidth - 24 }, "selected width stays inside display")
}

// The content plus host padding and the legacy rectangle share final widths.
for screenWidth in [1280.0, 1440, 1920, 2560] {
    let frame = CGRect(x: 100, y: 0, width: screenWidth, height: 900)
    let widths = CaptionSizeLevel.allCases.map { level in
        let content = CaptionIslandLayout.notchContentSize(visibleFrame: frame, widthLevel: level, heightLevel: .medium)
        let rect = CaptionIslandLayout.expandedRect(visibleFrame: frame, centerX: frame.midX,
                                                   widthLevel: level, compact: true)
        check(rect.width == content.width + 30, "rectangle and host agree on final capsule width")
        return content.width + 30
    }
    check(widths == [420, 560, 800], "large screens use exact fixed widths")
}
// A is visibleFrame.width minus 24pt. These test the pure policy without AppKit.
for (available, expected) in [(1416.0, [420.0, 560, 800]), (1256, [420, 560, 800]),
                               (1896, [420, 560, 800]), (2536, [420, 560, 800]),
                               (800, [420, 560, 800]), (780, [390, 546, 780]),
                               (600, [300, 420, 600]), (400, [200, 280, 400]),
                               (120, [40, 80, 120]), (781.9, [390, 547, 781])] {
    let frame = CGRect(x: 0, y: 0, width: available + 24, height: 900)
    let widths = CaptionSizeLevel.allCases.map {
        CaptionIslandLayout.expandedWidth(screenWidth: frame.width, widthLevel: $0)
    }
    check(widths == expected.map { CGFloat($0) }, "approved widths for A=\(available)")
    check(widths[1] - widths[0] >= 40 && widths[2] - widths[1] >= 40, "adjacent tiers are at least 40pt apart")
    check(widths[0] > 0 && widths[0] < widths[1] && widths[1] < widths[2], "all tiers are positive and strictly increasing")
    for (level, width) in zip(CaptionSizeLevel.allCases, widths) {
        check(CaptionIslandLayout.notchContentSize(visibleFrame: frame, widthLevel: level, heightLevel: .medium).width + 30 == width,
              "final black capsule includes 30pt host padding")
    }
}
for available in [0.0, 1, 2, 3, 32, 33, 40, 80, 81, 110, 111, 119, 120, 121, 399.9, 779.9, 799.9, 800] {
    let widths = CaptionSizeLevel.allCases.map {
        CaptionIslandLayout.expandedWidth(screenWidth: available + 24, widthLevel: $0)
    }
    check(widths[0] > 0 && widths[0] < widths[1] && widths[1] < widths[2], "extreme bounds retain positive distinct tiers")
    check(widths.allSatisfy { $0 == floor($0) }, "widths are rounded down to whole points")
    let contentWidths = CaptionSizeLevel.allCases.map {
        CaptionIslandLayout.notchContentSize(visibleFrame: CGRect(x: 0, y: 0, width: available + 24, height: 900),
                                            widthLevel: $0, heightLevel: .medium).width + 30
    }
    check(contentWidths == widths, "even extreme host widths match the pure final-width policy")
    if available >= 33 { check(widths[2] <= available, "tiers fit whenever three padded integer widths can fit") }
    if available >= 111 { check(widths[1] - widths[0] >= 40 && widths[2] - widths[1] >= 40, "40pt gaps whenever feasible") }
}
// Notch width only affects compact geometry, never the expanded selection.
check(CaptionIslandLayout.compactWidth(notchWidth: 185) == 425, "14-inch compact width remains notch plus 240")
check(CaptionIslandLayout.compactWidth(notchWidth: 200) == 440, "compact notch clearance is unchanged")
check(CaptionIslandLayout.notchContentSize(visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 900),
                                         widthLevel: .small, heightLevel: .medium).width + 30 == 420,
      "notched laptop narrow expanded capsule stays 420pt")
for raw: String? in [nil, "invalid"] {
    let level = CaptionAppearance.parseSize(raw) ?? .medium
    check(CaptionIslandLayout.expandedWidth(screenWidth: 1440, widthLevel: level) == 560,
          "unset or invalid island level defaults to 560pt")
}
check(CaptionIslandLayout.expandedWidth(screenWidth: 1920) == 560, "geometry defaults to medium")
// Exact caps include rounding boundaries and lower-value merged tiers.
for (screenHeight, expected) in [(1080.0, [100.0, 148, 240]), (900, [100, 148, 240]),
                                (1440, [100, 148, 240]), (720, [100, 148, 237]),
                                (600, [100, 148, 198]), (500, [100, 141, 165]),
                                (400, [84, 108, 132]), (340, [64, 88, 112]), (337, [64, 64, 111]),
                                (300, [64, 64, 99]), (267, [64, 64, 88]), (266, [64, 64, 64]),
                                (200, [64, 64, 64]), (149, [64, 64, 64]),
                                (148, [64, 64, 64]), (100, [64, 64, 64]),
                                (9, [64, 64, 64]), (5, [64, 64, 64]), (0, [64, 64, 64])] {
    let heights = CaptionSizeLevel.allCases.map {
        CaptionIslandLayout.expandedContentHeight(visibleHeight: screenHeight, heightLevel: $0)
    }
    check(heights == expected.map { CGFloat($0) }, "approved height caps for H=\(screenHeight)")
    check(heights.allSatisfy { $0 >= 64 && $0 == floor($0) }, "height caps are integer points >= 64")
    for gap in [heights[1] - heights[0], heights[2] - heights[1]] {
        check(gap == 0 || gap >= 24, "adjacent tiers merge or keep at least 24pt")
    }
    check((1...3).contains(Set(heights).count), "one to three distinct tiers")
    for (level, height) in zip(CaptionSizeLevel.allCases, heights) {
        check(height <= CGFloat(CaptionAppearance.islandHeight(level)), "height never exceeds its preset")
        if floor(screenHeight * 33 / 100) >= 64 {
            check(height <= floor(screenHeight * 33 / 100), "height stays within the visible-height cap")
        }
        // Fixed baseline widths, repeated across height and width selections.
        for (screenWidth, expectedWidths) in [(1440.0, [390.0, 530, 770]), (424, [170, 250, 370])] {
            for (widthLevel, expectedWidth) in zip(CaptionSizeLevel.allCases, expectedWidths) {
                let size = CaptionIslandLayout.notchContentSize(
                    visibleFrame: CGRect(x: 0, y: 0, width: screenWidth, height: screenHeight),
                    widthLevel: widthLevel, heightLevel: level)
                check(size.height == height, "content size uses the pure height policy")
                check(size.width == expectedWidth, "height changes preserve baseline content widths")
            }
        }
    }
}
// Art-director addendum: every 1pt, independently for all three selections.
var previousHeights = [CGFloat](repeating: 64, count: 3)
for screenHeight in 100...1200 {
    let heights = CaptionSizeLevel.allCases.map {
        CaptionIslandLayout.expandedContentHeight(visibleHeight: CGFloat(screenHeight), heightLevel: $0)
    }
    for (height, previous) in zip(heights, previousHeights) {
        check(height >= 64 && height >= previous && height == floor(height),
              "minimum and monotonic height at H=\(screenHeight)")
    }
    for gap in [heights[1] - heights[0], heights[2] - heights[1]] {
        check(gap == 0 || gap >= 24, "merged or separated tiers at H=\(screenHeight)")
    }
    check((1...3).contains(Set(heights).count), "distinct tier count")
    previousHeights = heights
}
for screenHeight in [900.0, 1080, 1440] {
    for raw: String? in [nil, "invalid"] {
        let level = CaptionAppearance.parseSize(raw) ?? .medium
        check(level == .medium, "unset or invalid height defaults to medium")
        check(CaptionIslandLayout.expandedContentHeight(visibleHeight: screenHeight, heightLevel: level) == 148,
              "default height on normal screens remains 148pt")
    }
}

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

// Segment A: final capsule margins and intrinsic content clamp.
for (width, column) in [(420.0, 380.0), (560, 520), (800, 760)] {
    check(CaptionIslandLayout.textColumnWidth(islandWidth: width) == column, "20pt margins")
}
for (visible, measured, expected) in [
    (900.0, 40.0, [64.0, 64, 64]), (900, 110, [100, 110, 110]),
    (900, 300, [100, 148, 240]), (400, 300, [84, 108, 132]),
    (400, 40, [64, 64, 64]), (100, 40, [64, 64, 64]),
    (900, 64.1, [65, 65, 65])
] {
    for (i, level) in CaptionSizeLevel.allCases.enumerated() {
        let height = CaptionIslandLayout.islandContentHeight(measured: measured,
            visibleHeight: visible, heightLevel: level)
        check(height == expected[i], "intrinsic clamp \(visible)/\(measured)/\(level)")
        check(height > 0 && height == floor(height), "positive integer height")
        check(CaptionIslandToolbarLayout.floatingWindowHeight(contentHeight: height, expanded: true) == expected[i] + 24 + 8 + 15, "floating toolbar is outside caption height")
    }
}
print("PASS segment A geometry")
