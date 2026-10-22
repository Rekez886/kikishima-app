from pathlib import Path

root = Path(__file__).resolve().parents[2]
def read(path):
    return (root / path).read_text()

state = read('Sources/Kikishima/CaptionState.swift')
assert 'CaptionSurfacePreference.load(from: .standard)' in state
select = state.split('func selectCaptionSurface(', 1)[1].split('var supportsIslandSizing', 1)[0]
assert 'CaptionSurfacePreference.select(value, in: .standard)' in select
assert 'captionSurface = value' in select
for path in ['Sources/Kikishima/App.swift', 'Sources/Kikishima/MainWindow.swift']:
    source = read(path)
    assert 'selection: $state.captionSurface' not in source
    assert 'state.selectCaptionSurface($0)' in source

panel = read('Sources/Kikishima/CaptionPanel.swift')
notch = read('Sources/Kikishima/IslandNotch.swift')
for source in [panel, notch]:
    assert 'CaptionIslandScreen.selected()' in source
    screen = 'screen' if source == panel else 'scr'
    assert f'CaptionScreenPolicy.floatingFrame(screenFrame: {screen}.frame, visibleFrame: {screen}.visibleFrame, size: size)' in source
    assert 'CaptionScreenPolicy.selectedIndex(' not in source
assert 'private var usesIsland: Bool { CaptionState.shared.usesIslandCaptions }' in panel
placement = panel.split('func place(for ', 1)[1].split('private let islandDisplay', 1)[0]
engine, fallback, desktop = placement.split('if usesIsland', 2)
assert 'return\n        }' in fallback  # engine path terminates
assert fallback.index('return') < fallback.index('if panel == nil')
assert desktop.index('islandFrame(expanded:') < desktop.index('return') < desktop.index('if userAdjusted') < desktop.index('AudioSourceWindow.current()')
assert 'guard !usesIsland, !userAdjusted' in panel
assert 'if !island { p.setFrameAutosaveName(' in panel
assert 'if !placing && !usesIsland' in panel
assert 'IslandPanelView(state: s, display: islandDisplay)' in panel
assert 'IslandExpandedView(state: state, display: display)' in panel
assert 'IslandExpandedView(state: s, display: self.display)' in notch
assert 'KKColor.notchBackground' in panel
assert '.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)' in panel
floating = read('Vendor/DynamicNotchKit/Sources/DynamicNotchKit/Views/NotchlessView.swift')
assert 'private let ink = Color.black' in floating
assert 'topLeadingRadius: cornerRadius' in floating
adapter = read('Sources/Kikishima/CaptionIslandScreen.swift')
assert 'CGDisplayIsBuiltin' in adapter
assert 'screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil' in adapter
assert 'screen.safeAreaInsets.top > 0' in adapter
assert 'NSScreen.main' not in adapter
print('PASS notch default wiring: explicit UI intent, shared screen policy/content, meeting island never enters desktop placement')
