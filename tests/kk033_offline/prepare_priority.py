from pathlib import Path
import sys
out=Path(sys.argv[1])
state=Path('Sources/Kikishima/CaptionState.swift').read_text()
panel=Path('Sources/Kikishima/CaptionPanel.swift').read_text()
island=Path('Sources/Kikishima/IslandNotch.swift').read_text().split('struct IslandCompactLeading:',1)[1].split('/// 胶囊右',1)[0]
app=Path('Sources/Kikishima/App.swift').read_text()
def block(s, sig):
    a=s.index(sig); b=s.index('{',a); end=b+1; depth=1
    while depth:
        depth+=(s[end]=='{')-(s[end]=='}'); end+=1
    return s[a:end]
def body(s,sig): return block(s,sig).split('{',1)[1].rsplit('}',1)[0]
properties=state[state.index('    var errorBanner: CaptionBanner?'):state.index('    private var connectivityAvailable:')].replace('private ', '')
poll=block(state,'private func pollMeter()').replace('private ', '')
# Preserve the entire compilation guard as well as the actual logger body.
log=state[state.index('#if DEBUG || SHOOT\n/// Opt-in numerical diagnostics'):]
(out/'LevelLog.swift').write_text('import Foundation\n'+log)
fixture='''import Foundation
import CoreFoundation
func tr(_ s: String) -> String { s }
func trAny(_ s: String) -> String { s }
'''+block(state,'struct CaptionBanner:')+'''
struct Sample { var level = 0.0; var lastIOAt = CFAbsoluteTimeGetCurrent(); var lastLoudAt = CFAbsoluteTimeGetCurrent() - 25 }
struct Meter { var sample = Sample(); func snapshot() -> Sample { sample } }
final class PriorityHost {
 var connectivity: TranslationConnectivityPolicy {
  get { translationConnectivity }
  set { translationConnectivity = newValue }
 }
 var audioPermissionFailed = false, rebuildingAudioTap = false
 var running = true, paused = false
 var finishingCaptions = false, starting = false, translationPaused = false, resuming = false, switchingMeetingLanguage = false
 // AUDIO CONDITIONS
 var status = "idle", audioLevel = 0.0
 var meter = Meter()
'''+properties+'\n'+poll+'\n}\n'
fixture=fixture.replace('// AUDIO CONDITIONS', block(state, 'var silentTooLong =')+'\n'+block(state, 'var audioStalled ='))
fixture+='enum AudioDevices { static var available = true; static func defaultOutput() -> Int? { available ? 1 : nil }; static func outputDevices() -> [Int] { [] } }\n'
fixture+='enum KKColor { case error, warning, brand, textTertiary, historyInk, textSecondary }\n'
# Compile actual consumers, not duplicate priority decisions in the test.
fixture+='enum ToolbarMode { case island, desktop }; let toolbarMode = ToolbarMode.desktop\n'
fixture+='func desktopBanner(_ state: PriorityHost) -> CaptionBanner? {'+body(panel,'private var displayedErrorStatus:')+'}\n'
for name,source in [('island',island),('desktop',block(panel,'private var islandIdle:'))]:
    expr=source.split('.accessibilityLabel(state.captionDisplayStatus',1)[1].split('\n',1)[0][:-1]
    expr='state.captionDisplayStatus'+expr
    fixture+=f'func {name}Accessibility(_ state: PriorityHost) -> String {{ {expr} }}\n'
islandColor=island.split('.fill(',1)[1].split('\n',1)[0][:-1]
desktopColor=block(panel,'private var islandIdle:').split('.fill((',1)[1].split(').opacity',1)[0]
fixture+='func islandColor(_ state: PriorityHost) -> KKColor { '+islandColor+' }\n'
fixture+='func desktopColor(_ state: PriorityHost) -> KKColor { '+desktopColor+' }\n'
for name,expr in [('islandText',island.split('Text(',1)[1].split(').font',1)[0]),('desktopText',block(panel,'private var captionLines:').split('Text(',1)[1].split(')\n',1)[0]),('appText',app.split('case .running: ',1)[1].split('\n',1)[0])]:
    fixture+=f'func {name}(_ state: PriorityHost) -> String {{ {expr} }}\n'
assert app.count('case .running: state.captionStatusText') == 2
assert 'if state.captionDisplayStatus == .audioStalled' not in app
assert '} else if state.captionDisplayStatus == .silent' not in app
assert 'CaptionLevelLog' not in poll
ingest = block(state, 'func ingest(')
assert '#if DEBUG || SHOOT\n        CaptionLevelLog.append(level: level)' in ingest
assert ingest.index('guard now - lastCalc > 0.1') < ingest.index('CaptionLevelLog.append(level: level)')
assert ingest.index('level = Double(min(1, rms * 6))') < ingest.index('CaptionLevelLog.append(level: level)')
(out/'MeterLog.swift').write_text('import Foundation\nimport AVFoundation\nimport AudioToolbox\n'+block(state, 'final class AudioMeter:')+'\n'+log)
fixture += block(Path('Sources/Kikishima/BrandIcons.swift').read_text(), 'enum CaptionMenuStatus:')+'\n'
fixture += 'struct MenuStatusProbe { var state: PriorityHost; var menuStatus: CaptionMenuStatus { .running }\n' + block(app, 'private var menuStatusLabel:').replace('private ', '')+'\n'+block(app, 'private var statusLabel:').replace('private ', '')+'\n}\n'
fixture += 'func menuHeader(_ state: PriorityHost) -> String { MenuStatusProbe(state: state).statusLabel }\n'
repairBranch=block(state, 'func performBanner(').split('case .openSettings:',1)[1]
repairExpression=repairBranch.split('if let url = ',1)[1].split(' {',1)[0]
fixture += 'extension PriorityHost { func repairURL() -> URL? { '+repairExpression+' } }\n'
(out/'PriorityWiring.swift').write_text(fixture)
print('PASS priority extraction: real resolver calls, surface text/colors/accessibility, banner and pollMeter')

(out/'LevelLogRuntime.swift').write_text('import Foundation\n'+log+'\n'+Path('tests/kk033_offline/level_log.swift').read_text())

for signature in ['private var menuStatusLabel:', 'private var statusLabel:']:
    selection=block(app, signature)
    assert selection.index('state.captionDisplayStatus.showsLabel') < selection.index('state.finishingCaptions')
assert 'Button(tr(action.title)) { state.performBanner(action) }' in island
assert 'xmark' not in island
assert 'bannerActionButton(banner, island: true)' in block(panel, 'private func islandErrorRow(')
assert 'xmark' not in block(panel, 'private func islandErrorRow(')
assert 'bannerActionButton(banner, island: false)' in block(panel, 'private func desktopStatusLine(')
assert 'xmark' not in block(panel, 'private func desktopStatusLine(')
helper = block(panel, 'private func bannerActionButton(')
assert 'if let action = banner.action' in helper
assert 'Button(tr(action.title)) { state.performBanner(action) }' in helper
assert 'CaptionState.shared.canDismissDesktopCaptionStatus' in block(panel, 'override func sendEvent(')

assert ".accessibilityElement(children: .contain)" in island
for forbidden in [".lineLimit(", ".truncationMode(", ".minimumScaleFactor("]:
    assert forbidden not in island
assert ".help(state.captionStatusText)" in island

policy = Path('Sources/Kikishima/CaptionStatusPriority.swift').read_text()
assert 'microphonePermission' not in policy
assert 'microphoneRequired' not in policy and 'microphoneDenied' not in policy
assert 'case .deviceMissing: return "没有输出设备，听不到会议声音"' in policy
assert 'case .audioStalled: return "音频中断，正在恢复"' in policy
assert 'if state.captionDisplayStatus.showsLabel { return state.captionStatusText }' in app
assert all('音频输入停止了：检查输出设备是否被拔掉' not in p.read_text() for p in Path('Sources').rglob('*.swift'))
# Pin production geometry used by measure_copy.swift so layout changes cannot
# silently leave the width regression measuring obsolete constants.
layout = Path('Sources/Kikishima/CaptionIsland.swift').read_text()
full_island = Path('Sources/Kikishima/IslandNotch.swift').read_text()
tokens = Path('Sources/Kikishima/DesignTokens.swift').read_text()
assert 'max(0, notchWidth) + 240' in layout
assert 'baseSize.width + 30 - display.hostSideInset * 2' in full_island
assert 'display.hostSideInset = notchless ? 15 : 30' in full_island
assert 'HStack(spacing: 10)' in full_island and '.padding(.horizontal, 14)' in full_island
assert 'HStack(spacing: 6)' in island and '.frame(width: 7, height: 7)' in island
assert 'HStack(spacing: 3)' in full_island and '.frame(width: 3,' in full_island
assert '.padding(.horizontal, 10).padding(.vertical, 6)' in block(tokens, 'private struct KKQuietButtonArtwork:')
assert '.font(state.captionFont(13 * scale))' in panel
assert '.font(.system(size: 11))' in island

desktop_layout = Path('Sources/Kikishima/CaptionErrorStatus.swift').read_text()
assert 'minimumSize = CGSize(width: 360, height: 90)' in desktop_layout
assert 'toolbarWidth: CGFloat = 5 * 28 + 4 * 6 + 4 * 8' in desktop_layout
assert 'static let gap: CGFloat = 10' in desktop_layout
assert 'leadingInset: KKSpace.five + KKSpace.three' in panel
assert 'static let three: CGFloat = 12' in tokens and 'static let five: CGFloat = 20' in tokens

pause = block(state, 'private func pause(_ r:')
assert 'translationPaused = true' in pause and 'tap.stop' not in pause and 'engine.stop' not in pause
capture = block(state, 'private func startTapCapture()')
assert 'engine.feed(' in capture and 'translationPaused' not in capture
tick = block(state, 'private func tickChunks()')
assert tick.index('chunks.append(chunk)') < tick.index('if translationPaused')
row = block(panel, 'private func captionRow(')
assert 'CaptionHierarchy.row(source: chunk.displaySource, translation: chunk.displayTranslation' in row
assert 'waiting: !chunk.translationExhausted && !state.translationPaused && !chunk.captionFinalized && (state.running || state.starting || state.finishingCaptions)' in row
assert all(token not in row for token in ['pauseReason', 'state.compactCaptions'])
assert 'if let secondary = text.secondary' in row
print('PASS source-display audit: all pauses share primary-source fallback; capture/chunks continue')
