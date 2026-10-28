from pathlib import Path

panel = Path('Sources/Kikishima/CaptionPanel.swift').read_text()
geometry = Path('Sources/Kikishima/CaptionIsland.swift').read_text()
island_buttons = geometry.split('case .island:')[1].split('case .captionWindow:')[0]
assert '[.pause, .settings]' in island_buttons and '[.settings]' in island_buttons
assert all(action not in island_buttons for action in ['.stop', '.compact', '.review'])
assert 'ForEach(toolbarActions, id: \\.self)' in panel
assert 'CaptionToolbar.buttons(mode: toolbarMode, running: state.running, paused: state.paused)' in panel
assert 'isIsland || hostedInNotch ? .island : .captionWindow' in panel
assert '!toolbarActions.contains(focus)' in panel
content = panel.split('private var content: some View')[1].split('private var hasPending:')[0]
assert content.index('ScrollView(.vertical)') < content.index('.overlay(alignment: .topLeading)')
assert '.frame(width: islandToolbarLayout.toolbar.width, height: islandToolbarLayout.toolbar.height)' in content
assert '.padding(.top, toolbarMode == .island ? islandToolbarLayout.contentTop : 0)' in content
assert 'y: islandToolbarLayout.toolbar.minY' in content
assert 'islandToolbarLayout.toolbar.minX - hostSideInset' in content
assert 'onIslandHeight(height)' in content
assert 'onIslandHeight(height +' not in content
assert '.scrollClipDisabled' not in panel
helper = Path('Sources/Kikishima/CaptionErrorStatus.swift').read_text().split('enum CaptionTitlebarAccessory {', 1)[1]
assert 'CaptionTitlebarAccessory.install(on: p, view: titlebarHost, titlebarHeight: titlebarHeight)' in panel.split('if !compact {', 1)[1]
assert 'addTitlebarAccessoryViewController' not in panel
assert helper.index('view.frame = NSRect(') < helper.index('accessory.layoutAttribute = .right') < helper.index('window.addTitlebarAccessoryViewController(accessory)')
assert 'width: CaptionDesktopStatusLayout.toolbarWidth' in helper and 'height: titlebarHeight)' in helper
assert ('accessory.layoutAttribute = .right' in helper
        and 'CaptionTitlebarAccessory.install(on: p, view: titlebarHost, titlebarHeight: titlebarHeight)' in panel
        and '.fullSizeContentView' not in panel
        and '.overlay(alignment: .topTrailing)' not in panel
        and 'compactStatusHeader' in panel
        and '.frame(height: CaptionDesktopStatusLayout.compactHeaderHeight)' in panel
        and 'layout.status.minX' in panel and 'layout.toolbar.minX' in panel
        and '.opacity(desktopToolbarVisible ? 1 : 0)' in panel)
assert 'if state.paused { islandPauseRow }' in panel
settings = panel.split('case .settings:')[1].split('case .review:')[0]
assert 'if toolbarMode == .island {' in settings
island_settings, desktop_settings = settings.split('} else {')
assert 'Button { AppDelegate.openMenuPanel() }' in island_settings
assert '.focused($toolbarFocus, equals: .settings)' in island_settings
assert 'popover' not in island_settings and 'IslandSettingsCard' not in island_settings
assert 'showSettings' not in island_settings
assert 'Button { showSettings.toggle() }' in desktop_settings
assert '.popover(isPresented: $showSettings, arrowEdge: .bottom)' in desktop_settings
assert 'IslandSettingsCard(state: state)' in desktop_settings
assert '.focused($toolbarFocus, equals: .settings)' in desktop_settings
app = Path('Sources/Kikishima/App.swift').read_text()
assert 'static func openMenuPanel() { presentMenuPanel?() }' in app
assert 'AppDelegate.presentMenuPanel = { menuPresented = true }' in app
assert 'MenuContent(state: state, isPresented: $menuPresented)' in app
assert '.menuBarExtraAccess(isPresented: menuAccessPresented,' in app
assert 'return $menuPresented' in app
assert 'return Binding(get: { false }, set: { if !$0 { menuPresented = false } })' in app
assert '.defaultFocus($primaryFocused, true)' in app
assert 'primaryFocused = presented' in app
for name in ['CaptionPanel', 'CaptionState', 'IslandNotch']:
    assert 'islandSettingsOpen' not in Path(f'Sources/Kikishima/{name}.swift').read_text()
assert 'settingsOpen' not in geometry
print('PASS island gear opens menu binding; desktop popover and menu primary focus preserved')
print('PASS island toolbar wiring: shared controls, reserved header, clipped scroll, height reporting, focus filtering')
# Desktop chrome and focus bindings remain the pre-#13 values.
desktop = panel.split('private var toolbar: some View')[1].split('private var toolbarButtons:')[0].split('} else {')[1]
for modifier in [
    '.buttonStyle(KKPlainButtonStyle())', '.font(.system(size: 12))',
    '.foregroundStyle(KKColor.textSecondary)',
    '.padding(.horizontal, 8).padding(.vertical, 5)',
    '.background(Capsule().fill(KKColor.captionWindowBackground.opacity(0.55)))',
    '.padding(.horizontal, 8)',
]:
    assert modifier in desktop
for action in ['pause', 'stop', 'compact', 'settings', 'review']:
    assert f'.focused($toolbarFocus, equals: .{action})' in panel
assert 'HStack(spacing: 6)' in panel.split('private var toolbarButtons:')[1].split('private func toolbarButton')[0]
assert '.buttonStyle(IslandToolbarButtonArtwork())\n            .kkFocusRing(radius: 6)' in panel
print('PASS desktop toolbar chrome and all five focus bindings preserved')

host = Path('Sources/Kikishima/IslandNotch.swift').read_text()
assert 'toolbarNotchWidth: display.notchWidth, toolbarNotchHeight: display.toolbarNotchHeight' in host
assert 'notchWidth: toolbarNotchWidth, notchHeight: toolbarNotchHeight' in panel
assert 'display.toolbarNotchHeight = notchless ? 0 : scr.safeAreaInsets.top' in host
assert 'CaptionIslandToolbarLayout.extraHeight(notchHeight: display.toolbarNotchHeight)' in host
for source in [host, panel]:
    assert 'CaptionIslandToolbarLayout.floatingWindowHeight(contentHeight: content.height, expanded: expanded)' in source
print('PASS host wiring: shared floating height, real notch width and camera-row height')

assert 'notchHeight: islandDisplay.toolbarNotchHeight, contentSize: content' in panel
assert '.padding(.top, display.toolbarNotchHeight > 0 ? display.toolbarNotchHeight : 8)' in panel
print('PASS legacy panel wiring: notched row and floating strip use matching window geometry')
