from pathlib import Path
import sys,re,json
out=Path(sys.argv[1]); read=lambda n:Path('Sources/Kikishima/'+n).read_text()
def block(s,sig):
 a=s.index(sig);b=s.index('{',a);i=b+1;d=1
 while d:
  d+=(s[i]=='{')-(s[i]=='}');i+=1
 return s[a:i]
state=read('CaptionState.swift');panel=read('CaptionPanel.swift');island=read('IslandNotch.swift');app=read('App.swift')
inline=block(panel,'private struct CaptionStatusInlineLayout:').replace('private ','')
(out/'SurfaceLayout.swift').write_text('import SwiftUI\nimport AppKit\n'+inline+'\n'+block(panel,'private struct IslandMeasuredHeight:').replace('private ',''))
content=block(panel,'private var content:')
assert 'islandErrorRow(banner)\n                            .background' in content
assert 'value: geometry.size.height' in content
assert '.onPreferenceChange(IslandMeasuredHeight.self)' in content
assert 'onIslandHeight(height)' in content
assert 'value: geometry.size.height' in block(panel,'private var captionRows:')
# Extract timer code without replacing the clock or production guard.
timer=block(island,'func noteActivity()')
(out/'CollapseWiring.swift').write_text('''import Foundation
@MainActor final class CaptionState {
 static let shared = CaptionState()
 var islandDormant = false
 var level = CaptionCollapseLevel.medium
 var islandAutoCollapseSeconds: Double { CaptionAppearance.collapseSeconds(level) }
 var offline = true
 var wantsIslandExpanded: Bool { CaptionAppearance.wantsExpanded(hasContent: true, dormant: islandDormant, paused: false, hasBanner: false) }
}
@MainActor final class CollapseProbe {
 var surfaceVisible = false
 var dormancyTask: Task<Void, Never>?
 var syncCount = 0
 func sync() { syncCount += 1 }
'''+timer+'\n}\n')
# Enumerate literal banner producers plus all source state/fallback strings.
cases={}
action_titles={}
for names,title in re.findall(r'case ([^:]+): return trAny\("([^"]+)"\)',block(state,'enum Action:')):
 for name in re.findall(r'\.(\w+)',names):action_titles[name]=title
for text,action in re.findall(r'CaptionBanner\(text: tr\("([^"\n]+)"[^\n]*?action: \.(\w+)',state):
 cases[text]={'text':text,'action': action_titles[action]}
policy=read('CaptionStatusPriority.swift')
for text in re.findall(r'case \.\w+: return "([^"\n]+)"',policy):
 if text.startswith('x-apple'):continue
 cases.setdefault(text,{'text':text,'action':'修复' if text in [x[0] for x in re.findall(r'\("([^"\n]+)", "([^"\n]+)"\)',policy)] and '音频中断' not in text else ''})
for text in re.findall(r'\bstatus = tr\("([^"\n]+)"',state)+['已暂停','已暂停 · 声音不再记录','启动中…','翻译已暂停','字幕']:
 cases.setdefault(text,{'text':text,'action':''})
for text in ['就绪']:
 cases.setdefault(text, {'text':text,'action':''})
(out/'status-cases.json').write_text(json.dumps(list(cases.values()),ensure_ascii=False))
# Compile the actual SHOOT-only probe with hardware boundary fakes. Unknown
# engine/Translator/network symbols cannot compile in this fixture.
audio=block(state,'enum ShootAudioOnly {')
assert 'Translator' not in audio and 'engine' not in audio and 'URLSession' not in audio
launch=block(app,'func applicationDidFinishLaunching(')
for sig in ['static func hostReady()', 'init()', 'func applicationShouldTerminate(']:
 assert 'ShootAudioOnly.requested' in block(app,sig)
(out/'AudioOnlyWiring.swift').write_text('''import Foundation
struct Description {}
struct AVAudioFormat { init?(streamDescription: inout Description) {} }
final class AudioMeter { static var ingested = 0; func ingest(_ input: Int, format: AVAudioFormat) { Self.ingested += 1 } }
final class SystemAudioTap {
 static var starts = 0, stops = 0
 var streamDescription: Description? { Description() }
 func start(_ callback: (Int,Int,Int,Int,Int)->Void) throws { Self.starts += 1; callback(0,1,0,0,0) }
 func stop() { Self.stops += 1 }
}
@MainActor
'''+audio+'\n')
# Strip only the known call into the guard: all code before return is real.
start=launch.split('#if SHOOT',1)[1].split('#endif',1)[0]
(out/'AudioOnlyWiring.swift').write_text((out/'AudioOnlyWiring.swift').read_text()+'\n@MainActor func launchProbe() {\n'+start+'\nfatalError("audio-only entered normal network startup")\n}\n')
print('PASS surface/timer/audio-only extraction: production code, hardware boundary only mocked')

assert 'width: .custom(304)' in app
assert '.padding(.horizontal, 12).padding(.vertical, 10)' in app
assert 'HStack(spacing: 8)' in block(app, 'private var statusBlock:')

scene = block(app, 'var body: some Scene')
assert 'if !ShootAudioOnly.requested {\n                MenuContent' in scene
assert 'if !ShootAudioOnly.requested { MainWindowView() }' in scene
assert '.defaultLaunchBehavior(.suppressed)' in scene
