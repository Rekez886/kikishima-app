import Foundation
import CoreGraphics
let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
               CGRect(x: 1440, y: 0, width: 2560, height: 1440)]
let meeting = CGRect(x: 1600, y: 200, width: 800, height: 600)
precondition(CaptionScreenPolicy.selectedIndex(meetingFrame: meeting, screenFrames: screens,
    fallbackIndex: 0) == 1, "audit18: select screen containing meeting center")
precondition(CaptionScreenPolicy.selectedIndex(meetingFrame: nil, screenFrames: screens,
    fallbackIndex: 0) == 0, "audit18: no meeting falls back to main display")
precondition(CaptionScreenPolicy.selectedIndex(meetingFrame: meeting, screenFrames: [],
    fallbackIndex: 0) == nil, "audit18: empty screen inventory is safe")
for expanded in [false, true] {
    precondition(CaptionScreenPolicy.shouldMigrate(shown: true, currentScreenID: 1,
        selectedScreenID: 2, force: false, expansionChanged: expanded),
        "audit18: screen change must migrate even without expansion change")
}
precondition(CaptionScreenPolicy.shouldMigrate(shown: true, currentScreenID: 1,
    selectedScreenID: 2, force: true, expansionChanged: false), "audit18: reset reselects and migrates")
precondition(!CaptionScreenPolicy.shouldMigrate(shown: true, currentScreenID: 2,
    selectedScreenID: 2, force: false, expansionChanged: false), "audit18: stable screen needs no migration")
print("PASS audit18 screen selection and migration")
