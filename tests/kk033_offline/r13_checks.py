"""Review entry inventory and frame-transition wiring; never creates a window."""
from pathlib import Path
r=Path('Sources/Kikishima')
read=lambda name:(r/name).read_text()
def block(s,sig):
 a=s.index(sig);b=s.index('{',a);i=b+1;d=1
 while d:d+=(s[i]=='{')-(s[i]=='}');i+=1
 return s[a:i]
main=read('MainWindow.swift');panel=read('CaptionPanel.swift');app=read('App.swift');island=read('IslandNotch.swift')
menu=block(app,'struct MenuContent:')
assert menu.count('AccessibleMenuCommand(tr("打开 Kikishima"))') == 1
assert 'state.paused ? state.resume() : state.pause()' in menu
assert 'if state.paused { islandPauseRow }' in panel
assert 'if state.paused && !(isIsland || hostedInNotch)' in panel
# No second full error banner on either caption surface, collapsed/expanded exclusive.
body=panel[panel.index('    var body: some View',panel.index('struct CaptionFeedView:')):]
assert 'if let banner = state.errorBanner' not in body
assert 'if let banner = displayedErrorStatus' in body
assert 'if captionDisplayStatus == .sourceOnly { return CaptionBanner(text: captionStatusText, severity: .info) }' in read('CaptionState.swift')
assert 'if captionDisplayStatus == .error { return selectedCaptionError }' in read('CaptionState.swift')
assert 'if state.wantsIslandExpanded {' in island
# Both native hosts use the existing top-anchored 200ms transition on measured height.
shift=block(island,'enum IslandContentShift')
assert 'context.duration = 0.2' in shift and 'controlPoints: 0.2, 0, 0, 1' in shift
assert 'context.duration = 0.1' in shift and 'if reduceMotion' in shift
assert 'window.animator().setFrame(frame, display: true)' in shift
assert '.timingCurve(0.2, 0, 0, 1, duration: 0.2), value: size.height' in island
assert '.onChange(of: size) { CaptionPanelController.shared.resizeIslandToContent() }' in island
assert 'IslandContentShift.setFrame(islandFrame(expanded: revealed)' in panel
assert 'applyWindowPolicy(animateContent: true)' in block(island,'func resizeToContent()')
# Menu opening changes only our own binding, no click/system events.
assert 'if ShootSimulation.requestedOpenMenu { ShootOpenMenu.shared.start() }' in app
assert 'if ShootSimulation.requestedOpenMenu && !presented' not in app
assert 'ShootOpenMenu.shared.discovered(item, present: { menuPresented = true })' in app
shoot=read('ShootSimulation.swift')
assert 'seconds.isFinite, seconds > 0' in shoot
assert shoot.startswith('#if SHOOT || DEBUG') and shoot.rstrip().endswith('#endif')
render=read('ShootRender.swift');assert 'MenuContent(state: state' in render and 'MainWindowView()' in render
assert 'menuKeyboardPresented' in app and 'KIKISHIMA_SHOOT_RENDER' in block(app,'private var menuKeyboardPresented:')
print('PASS r13: caption status inventory, pause wiring, both island hosts transition curves, native menu binding')

# r16b: automatic opening must bypass the dependency's performClick path.
assert 'return Binding(get: { false }, set: { if !$0 { menuPresented = false } })' in app
assert '.menuBarExtraAccess(isPresented: menuAccessPresented,' in app
