import Foundation
// IDs, not NSScreen object identity, survive parameter notifications and reordering.
precondition(ScreenRetentionPolicy.targetID(currentID: 2, availableIDs: [1, 2], fallbackID: 1) == 2,
    "audit19: parameter change must preserve target instead of screens.first")
precondition(ScreenRetentionPolicy.targetID(currentID: 2, availableIDs: [2, 1], fallbackID: 1) == 2,
    "audit19: screen ordering must not change target")
precondition(ScreenRetentionPolicy.targetID(currentID: 2, availableIDs: [1, 3], fallbackID: 3) == 3,
    "audit19: disconnected target uses host-selected meeting display")
precondition(ScreenRetentionPolicy.targetID(currentID: 2, availableIDs: [1], fallbackID: 3) == 1,
    "audit19: unavailable fallback uses an available screen")
precondition(ScreenRetentionPolicy.targetID(currentID: 2, availableIDs: [], fallbackID: nil) == nil,
    "audit19: all displays unavailable is safe")
print("PASS audit19 vendor screen retention")
