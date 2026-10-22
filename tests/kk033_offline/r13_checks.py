"""Review entry inventory and frame-transition wiring; never creates a window."""
from pathlib import Path
import ast
r=Path('Sources/Kikishima')
read=lambda name:(r/name).read_text()
def block(s,sig):
 a=s.index(sig);b=s.index('{',a);i=b+1;d=1
 while d:d+=(s[i]=='{')-(s[i]=='}');i+=1
 return s[a:i]
main=read('MainWindow.swift');card=read('SidebarAccountCard.swift');panel=read('CaptionPanel.swift');app=read('App.swift');island=read('IslandNotch.swift')
assert 'showsAccountAction: state.mainSection != .settings' in main
assert card.count('if showsAccountAction {') == 2
assert card.count('Button(tr("登录"), action: login)') == 1
assert card.count('Button(action: upgrade)') == 1
settings=block(main,'struct SettingsPane:')
assert settings.count('Button(tr("升级 Pro"))') == 1
assert 'if !state.sessionToken.isEmpty' in settings
# Each account tier has one action owner; settings has its actual auth form.
for section in ['captions','settings','history','glossary','languages','help',None]:
 for tier in ['signedOut','free','pro']:
  sidebar=(section != 'settings') and tier != 'pro'
  content=(section == 'settings') and tier != 'pro'
  assert int(sidebar)+int(content) <= 1
menu=block(app,'struct MenuContent:')
assert menu.count('Button(tr("升级 Pro"))') == 1
assert menu.count('AccessibleMenuCommand(tr("打开 Kikishima"))') == 1
assert '未登录 · 点「打开 Kikishima」登录' not in menu
assert 'Button(tr("登录"))' in menu
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
assert 'try await Task.sleep(for: .seconds(requestedIslandTransition ?? 3))' in shoot
assert 'applySourceOnlyTransition(state)' in shoot
assert shoot.startswith('#if SHOOT || DEBUG') and shoot.rstrip().endswith('#endif')
# Validate the review-only Cartesian product, without importing a renderer.
tree=ast.parse(Path('tools/screenshot_diff/review.py').read_text())
subset=ast.Module(body=[n for n in tree.body if isinstance(n,(ast.Assign,ast.FunctionDef)) and (isinstance(n,ast.Assign) or n.name=='review_entries')],type_ignores=[])
scope={};exec(compile(subset,'review-matrix','exec'),scope)
entries=scope['review_entries']();assert len(entries)==36 and len({e['id'] for e in entries})==36
assert {e['placement'] for e in entries}=={'menu','main'}
assert 'if mode == "source-only-transition": continue' in Path('tools/screenshot_diff/runner.py').read_text()
render=read('ShootRender.swift');assert 'MenuContent(state: state' in render and 'MainWindowView()' in render
assert 'menuKeyboardPresented' in app and 'KIKISHIMA_SHOOT_RENDER' in block(app,'private var menuKeyboardPresented:')
print('PASS r13: account entry ownership (21 cases), caption repair/source-only inventory, pause kept, both island hosts 200ms curve / reduce-motion 100ms fade, 36 review-only cells, own-menu binding')

# r16b: automatic opening must bypass the dependency's performClick path.
assert 'return Binding(get: { false }, set: { if !$0 { menuPresented = false } })' in app
assert '.menuBarExtraAccess(isPresented: menuAccessPresented,' in app
