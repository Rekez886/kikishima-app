from pathlib import Path
import sys
out=Path(sys.argv[1])
state=Path('Sources/Kikishima/CaptionState.swift').read_text()
main=Path('Sources/Kikishima/MainWindow.swift').read_text()
store=Path('Sources/Kikishima/MeetingSummaryStore.swift').read_text()
def block(s, sig):
    a=s.index(sig); b=s.index('{',a); end=b+1; depth=1
    while depth:
        depth+=(s[end]=='{')-(s[end]=='}'); end+=1
    return s[a:end]
resolver=block(state,'nonisolated static var transcriptDir:')
# Exactly one root resolver, all other operations consume selected record URLs.
roots=[str(p) for p in Path('Sources/Kikishima').glob('*.swift') if '.documentDirectory' in p.read_text()]
assert roots == ['Sources/Kikishima/CaptionState.swift'], roots
assert resolver.index('KIKISHIMA_RECORDS_DIR') < resolver.index('UserDefaults.standard') < resolver.index('.documentDirectory')
assert 'let url = Self.transcriptDir.appendingPathComponent(name + ".md")' in state
assert 'let dir = CaptionState.transcriptDir' in block(main,'func loadTranscripts()')
assert 'String(contentsOf: file.url' in main
assert 'state.retryTranscript(at: selected.url)' in main and '.disabled(!state.canRetryTranscript(at: selected.url))' in main
assert 'if let count = incompleteTranslations[selected.url], count > 0' in main
assert 'trashRecords(at: files.map(\\.url))' in main
assert 'try trashTranscript(at: url, fileManager: fileManager)' in store
assert '.documentDirectory' not in store
fixture='''import Foundation
// Dependencies of the real getter are spies: accessing Documents with the
// override active is an immediate test failure, not a real filesystem access.
enum FilesSpy {
 static let `default` = FilesSpyValue()
 static var calls = 0
}
struct FilesSpyValue {
 func urls(for directory: FileManager.SearchPathDirectory, in domain: FileManager.SearchPathDomainMask) -> [URL] {
  FilesSpy.calls += 1
  #if DEBUG || SHOOT
  precondition(ProcessInfo.processInfo.environment["KIKISHIMA_RECORDS_DIR"] == nil, "Documents touched under override")
  #endif
  return [URL(fileURLWithPath: "/fictional-default-documents", isDirectory: true)]
 }
}
enum DefaultsSpy { static let standard = DefaultsSpyValue(); static var saved: String? }
struct DefaultsSpyValue { func string(forKey: String) -> String? { DefaultsSpy.saved } }
enum CaptionState {
 static let FileManager = FilesSpy.self
 static let UserDefaults = DefaultsSpy.self
'''+resolver+'\n}\n'+block(main,'struct TranscriptFile:')+'\n'+block(main,'func loadTranscripts()')+'''
final class RetryHost {
 var retryingTranscriptURL: URL?, transcriptURL: URL?
 var finishingCaptions = false, running = false, starting = false
 var finalTranscriptTask: Int?, meetingSummaryFinalizationTask: Int?, meetingSummaryRetryTask: Int?
'''+block(state,'func canRetryTranscript(at')+'\n}\n'+'''
final class SummaryDirectoryHost {
 func directory(_ url: URL) -> URL { summaryDirectory(beside: url) }
'''+block(store,'private func summaryDirectory(')+'\n}\n'
(out/'RecordsWiring.swift').write_text(fixture)
# Actual SIM implementation is compiled whole. These are only external services.
(out/'SimulationFixtures.swift').write_text(Path('tests/kk033_offline/simulation_fixtures.swift').read_text())
print('PASS isolation wiring: sole root resolver, save/list/read/retry/trash URL chain, summary sibling directory')

sim=Path('Sources/Kikishima/ShootSimulation.swift').read_text()
assert sim.startswith('#if SHOOT || DEBUG') and sim.rstrip().endswith('#endif')
assert 'UserDefaults' not in sim
surface=block(state,'var captionSurface:')
assert surface.index('if ShootSimulation.requestedMode != nil') < surface.index('UserDefaults.standard.set')
assert 'CaptionPanelController.shared.switchSurface(); return' in surface

# The new SIM forces bilingual display without persisting preferences.
state = Path('Sources/Kikishima/CaptionState.swift').read_text()
for name in ['compactCaptions', 'captionDisplay']:
    setter = state.split('var '+name+':', 1)[1].split('UserDefaults.standard.set', 1)[0]
    assert '#if SHOOT || DEBUG' in setter and 'if ShootSimulation.requestedMode != nil {' in setter and 'return }' in setter

state = Path('Sources/Kikishima/CaptionState.swift').read_text()
a = state.index('    var wantsIslandExpanded: Bool {')
b = state.index('    var model:', a)
f = out/'SimulationFixtures.swift'
s = f.read_text().replace(' static let shared = CaptionState()', ' static let shared = CaptionState()\n var islandDormant = false\n var hasIslandContent: Bool { !chunks.isEmpty || errorBanner != nil || paused }\n'+state[a:b])
f.write_text(s)
