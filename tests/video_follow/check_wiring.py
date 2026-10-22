"""Execute production routing with inert windows; never initialize AppKit/defaults."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[2]
state = (root / 'Sources/Kikishima/CaptionState.swift').read_text()
panel = (root / 'Sources/Kikishima/CaptionPanel.swift').read_text()
notch = (root / 'Sources/Kikishima/IslandNotch.swift').read_text()


def block(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


assert 'private var usesIsland: Bool { CaptionState.shared.usesIslandCaptions }' in panel
assert 'private var isIsland: Bool { state.usesIslandCaptions }' in panel
assert '!Self.enabled && CaptionState.shared.usesIslandCaptions' in notch
assert 'let island = usesIsland' in block(panel, 'private func build()')
assert 'if notchEngine {' in block(panel, 'func show()')
assert 'IslandNotchController.shared.hide()' in block(panel, 'func hide()')
assert 'guard !usesIsland, !userAdjusted' in block(panel, 'func followSourceIfMoved()')
placement = block(panel, 'func place(for ')
# Execute the real engine + NSPanel-island branches, then record desktop entry.
# Desktop geometry itself must remain unchanged (covered by existing layout tests).
prefix = placement[:placement.index('        if userAdjusted && !force')]
assert placement.index('if usesIsland') < placement.index('islandFrame(expanded:') < placement.index('AudioSourceWindow.current()')
assert 'if !island { p.setFrameAutosaveName(' in panel
poll = state[state.index('                    if self.effectiveMode == .video'):]
poll = '\n'.join(poll.splitlines()[:2])
assert 'followSourceIfMoved()' in poll and 'else if self.usesIslandCaptions' in poll

harness = '''import Foundation
import CoreGraphics
// Test doubles record routing only; no AppKit, real defaults, audio or app lifecycle.
enum EffectiveMode { case meeting, video }
enum CaptionMode { case meeting, video, auto }
final class FakePanel {
    var isVisible = false
    var delegate: Int? = nil
    func orderOut(_ sender: Int?) { isVisible = false }
    func setFrame(_ frame: CGRect, display: Bool, animate: Bool) {
        CaptionPanelController.shared.events.append("capsule")
    }
}
enum AudioSourceWindow {
    static var frame: CGRect? = CGRect(x: 10, y: 30, width: 900, height: 600)
    static func current() -> CGRect? { frame }
}
final class IslandNotchController {
    static let shared = IslandNotchController()
    static var enabled = true
    var visible = false
    func hide() { visible = false }
    func sync(force: Bool = false) { CaptionPanelController.shared.events.append("notch") }
}
final class CaptionState {
    static let shared = CaptionState()
    var effectiveMode: EffectiveMode = .meeting
    var captionMode: CaptionMode = .meeting
    var captionSurface = "island"
    var running = true
    var wantsIslandExpanded = true
    var islandExpanded = false
    static func micInUse() -> Bool { false }
'''
for signature in ['var usesIslandCaptions:', 'var supportsIslandSizing:', 'func applyPlacement(']:
    harness += block(state, signature) + '\n'
harness += 'func poll() {\n' + poll + '\n}\n}\n'
harness += '''final class CaptionPanelController {
    static let shared = CaptionPanelController()
    var panel: FakePanel? = FakePanel()
    var events: [String] = []
    var userAdjusted = false
    var placing = false
    var revealed = false
    var lastSourceFrame: CGRect? = nil
    func refreshVisibility() {} // Observation is outside this routing-only fixture.
    func build() { panel = FakePanel() }
    func show() {
        if notchEngine { IslandNotchController.shared.visible = true }
        else { if panel == nil { build() }; panel?.isVisible = true }
    }
    func islandFrame(expanded: Bool) -> CGRect { .zero }
'''
for signature in ['private var usesIsland:', 'private var notchEngine:', 'var isVisible:',
                  'func switchSurface(', 'func followSourceIfMoved()']:
    harness += block(panel, signature) + '\n'
harness += prefix + '''        if userAdjusted && !force { return }
        events.append("desktop")
    }
}
'''
Path(sys.argv[1]).write_text(harness)
print('PASS video follow wiring: shared mode guard, polling, view/host routing, dormancy and surface transitions')
