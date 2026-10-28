import Foundation
import CoreGraphics

let state = CaptionState.shared
let controller = CaptionPanelController.shared
let notch = IslandNotchController.shared

// Exercise actual Swift routing for both engines, both scenes and both preferences.
for enabled in [true, false] {
    IslandNotchController.enabled = enabled
    for surface in ["island", "window"] {
        for mode in [EffectiveMode.video, .meeting] {
            state.captionSurface = surface
            state.effectiveMode = mode
            let island = surface == "island" && mode == .meeting
            precondition(state.usesIslandCaptions == island)
            precondition(state.supportsIslandSizing == island)
            for adjusted in [false, true] {
                controller.userAdjusted = adjusted
                controller.panel = FakePanel()
                controller.panel?.isVisible = true
                notch.visible = enabled && island
                controller.events = []
                controller.place(for: mode)
                let expected = island ? [enabled ? "notch" : "capsule"] : adjusted ? [] : ["desktop"]
                precondition(controller.events == expected, "placement \(surface) \(mode) \(enabled) \(adjusted)")
                controller.events = []
                controller.lastSourceFrame = nil
                state.poll()
                let polled = island ? [enabled ? "notch" : "capsule"] : mode == .video && !adjusted ? ["desktop"] : []
                precondition(controller.events == polled, "poll \(surface) \(mode) \(enabled) \(adjusted)")
            }
        }
    }
}

// The normal follow threshold and hidden-window behavior remain intact.
state.captionSurface = "island"
state.effectiveMode = .video
controller.userAdjusted = false
controller.panel = FakePanel()
controller.panel?.isVisible = true
controller.lastSourceFrame = AudioSourceWindow.frame
controller.events = []
state.poll()
precondition(controller.events.isEmpty, "unmoved video stays put")
AudioSourceWindow.frame?.origin.x += 100
state.poll()
precondition(controller.events == ["desktop"], "moved video is followed")
controller.panel?.isVisible = false
controller.events = []
state.poll()
precondition(controller.events.isEmpty, "hidden video stays hidden")

// A visible meeting host becomes a video panel and vice versa; hidden stays hidden.
for enabled in [true, false] {
    IslandNotchController.enabled = enabled
    for visible in [true, false] {
        state.effectiveMode = .meeting
        state.captionMode = .video
        controller.panel = enabled ? nil : FakePanel()
        controller.panel?.isVisible = visible
        notch.visible = enabled && visible
        state.applyPlacement()
        precondition(!notch.visible, "video must hide notch host")
        precondition(controller.panel?.isVisible == visible, "video preserves visibility")
        state.captionMode = .meeting
        state.applyPlacement()
        precondition(controller.isVisible == visible, "meeting preserves visibility")
        precondition(notch.visible == (enabled && visible))
        // Auto mode with no microphone must take the same video route.
        state.captionMode = .auto
        state.applyPlacement()
        precondition(state.effectiveMode == .video && !notch.visible)
    }
}
print("PASS video follow: island/video, island/meeting, window, both engines, manual placement, movement, hidden state and scene transitions")

// Automatic scene changes respect a manually placed desktop window.
state.captionSurface = "island"
state.effectiveMode = .meeting
state.captionMode = .auto
controller.userAdjusted = true
controller.panel = FakePanel()
controller.panel?.isVisible = true
controller.events = []
state.applyPlacement()
precondition(controller.events.isEmpty, "auto transition must respect manual placement")

// A window preference changes scenes without replacing its existing panel.
state.captionSurface = "window"
state.effectiveMode = .meeting
state.captionMode = .video
let existing = FakePanel()
existing.isVisible = true
controller.panel = existing
state.applyPlacement()
precondition(controller.panel === existing, "window scene switch preserves its panel")
print("PASS video follow: automatic changes respect manual placement; window scene changes preserve their host")
