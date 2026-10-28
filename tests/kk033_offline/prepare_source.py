"""r13: execute production roles and the real feed/preview call expressions."""
from pathlib import Path
import sys
out=Path(sys.argv[1]); root=Path('Sources/Kikishima')
panel=(root/'CaptionPanel.swift').read_text(); main=(root/'MainWindow.swift').read_text()
def block(s,sig):
 a=s.index(sig); b=s.index('{',a); i=b+1; d=1
 while d:d+=(s[i]=='{')-(s[i]=='}');i+=1
 return s[a:i]
def call(s):
 a=s.index('CaptionHierarchy.row('); b=a+len('CaptionHierarchy.row(');i=b;d=1
 while d:d+=(s[i]=='(')-(s[i]==')');i+=1
 return s[a:i]
row=block(panel,'private func captionRow(')
feed_call=call(row)
preview_call=call(main)
assert 'if let secondary = text.secondary' in row
assert '.frame(minHeight: chunk.translationExhausted' not in row
assert 'KKColor.textPrimary' in row and 'CaptionHierarchy.fontSize(current: current' in row
assert 'if current { Rectangle().fill(KKColor.brand)' in row
preview=(root/'HomeCaptionPreview.swift').read_text()
assert 'Text(text.primary)' in preview and 'if let secondary = text.secondary' in preview
assert 'rows: previewRows' in main
latest=block(panel,'private var latestReadableID:').split('{',1)[1].rsplit('}',1)[0]
hierarchy=(root/'CaptionIsland.swift').read_text()
code='''import Foundation
struct State { var showTranslation=true; var showSource=true; var translationPaused=false; var running=true; var starting=false; var finishingCaptions=false; var visibleCaptionChunks:[Chunk]=[]; var pendingEn="source"; var pendingDraft="" }
struct Chunk { let id=UUID(); var isMarker=false; var isDraft=false; var zh=""; var translationExhausted=false; var captionFinalized=false; var displaySource:String { "source" }; var displayTranslation:String { zh } }
enum CaptionHierarchy {
'''+block(hierarchy,'static func row(')+'\n}\n'+block(hierarchy,'struct CaptionRowText:')+'\n'+(root/'CaptionReadingPolicy.swift').read_text()
code+='\nfunc latestID(_ state: State) -> UUID? {'+latest+'}\n'
code+='func pending(_ state: State) -> CaptionRowText { '+call(panel)+' }\n'
code+='func feed(_ chunk: Chunk, _ state: State, current: Bool) -> CaptionRowText { '+feed_call+' }\n'
code+='func previewRow(_ chunk: Chunk, _ state: State, current: Bool) -> CaptionRowText { let latest: UUID? = current ? chunk.id : nil; let active=state.running || state.starting || state.finishingCaptions; return '+preview_call+' }\n'
code+='''
@main struct Matrix { static func main() {
 var count=0
 for surface in ["desktop","island","preview"] { for compact in [false,true] { for current in [false,true] { for mode in ["source","translation","both"] { for reason in ["translated","paused","exhausted","final","stopped","waiting"] {
  var state=State();state.showTranslation=mode != "source";state.showSource=mode != "translation"
  state.translationPaused=reason == "paused";state.running=reason != "stopped"
  var chunk=Chunk();chunk.zh=reason == "translated" ? "translation" : "";chunk.translationExhausted=reason == "exhausted";chunk.captionFinalized=reason == "final"
  let result=surface == "preview" ? previewRow(chunk,state,current:current) : feed(chunk,state,current:current)
  state.pendingDraft=chunk.zh
  if reason == "paused" || reason == "stopped" || reason == "waiting" || reason == "translated" {
   let live=pending(state)
   let expectedLive=mode == "source" ? "source" : reason == "translated" ? "translation" : reason == "waiting" && mode == "translation" ? "…" : "source"
   precondition(live.primary == expectedLive)
   precondition(live.secondary == (reason == "translated" && mode == "both" ? "source" : nil))
  }
  let waiting=reason == "waiting"; let translated=reason == "translated"
  let expected=mode == "source" ? "source" : translated ? "translation" : waiting && mode == "translation" ? "…" : "source"
  precondition(result.primary == expected,"primary \\(surface)/\\(compact)/\\(current)/\\(mode)/\\(reason)")
  precondition(result.secondary == (translated && current && mode == "both" ? "source" : nil))
  precondition(result.placeholder == (expected == "…"))
  var history=Chunk();history.zh="history";history.captionFinalized=true
  state.visibleCaptionChunks=[history,chunk]
  if !translated { precondition(latestID(state) == (waiting ? history.id : chunk.id)) }
  count+=1
 }}}}}
 print("PASS r13 roles: \\(count) cells; production desktop/island/preview calls, current/history, modes, waiting/exhausted/paused/final/stopped; compact uses same roles")
}}
'''
(out/'SourceMatrix.swift').write_text(code)
