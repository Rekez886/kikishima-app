"""Compile real visibility guards; inventory every status emitter without rendering an app."""
from pathlib import Path
import sys,json
out=Path(sys.argv[1])
panel=Path('Sources/Kikishima/CaptionPanel.swift').read_text()
preview=Path('Sources/Kikishima/HomeCaptionPreview.swift').read_text()
main=Path('Sources/Kikishima/MainWindow.swift').read_text()
app=Path('Sources/Kikishima/App.swift').read_text()
island=Path('Sources/Kikishima/IslandNotch.swift').read_text()
def guard(source, prefix):
 return source.split('if '+prefix,1)[1].split(' {',1)[0].join([''+prefix,''])
empty=guard(panel,'displayedChunks.isEmpty')
# r12c: the entire original slab (including both padding layers) is conditional.
slab=panel.split('private var desktopCaptionRows: some View {',1)[1].split('private var captionLines:',1)[0]
slab_guard=guard(slab,'!displayedChunks.isEmpty')
expected_modifiers = 'captionLines\n            .fixedSize(horizontal: false, vertical: true)\n            .padding(.horizontal, KKSpace.three)\n            .padding(.vertical, KKSpace.two)\n            .background(KKColor.surfaceBase, in: RoundedRectangle(cornerRadius: KKRadius.md))\n            .accessibilityElement(children: .contain)\n            .accessibilityIdentifier("kk-caption-text-slab")\n            .padding(.horizontal, KKSpace.five)\n            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)'
assert slab.strip() == ('if '+slab_guard+' {\n'+expected_modifiers+'\n}\n}').strip() or \
       ''.join(slab.split()) == ''.join(('if '+slab_guard+' {'+expected_modifiers+'}}').split())
assert '@ViewBuilder\n    private var desktopCaptionRows' in panel

footer=guard(preview,'isExample ||')
secondary=guard(app,'!state.paused && !state.captionDisplayStatus.showsLabel')
# Exhaustive status-emitter inventory: captions are content, never counted as notices.
assert panel.count('Text(state.captionStatusShortText)') == 1
assert 'if let banner = displayedErrorStatus' in panel
assert 'if state.paused && !(isIsland || hostedInNotch)' in panel
assert 'if state.paused { islandPauseRow }' in panel
assert 'Text(status)' not in preview
assert preview.count('Text(isExample ? tr("字幕预览 · 示例") : status)') == 1
assert 'statusPresentedExternally: true' in main
assert main.count('Text(state.status)') == 1
assert app.count('Text(state.status)') == 1
assert 'if state.captionDisplayStatus == .audioStalled' not in app
assert '20 秒没听到声音：检查会议是否在播放、输出设备是否正确' not in app
assert 'CaptionFeedView(state: state, hostedInNotch: true' in island
assert 'CaptionHierarchy.row(source: chunk.displaySource' in panel # r13 source fallback is caption content.
cases=json.loads(Path('tests/kk033_offline/status_copy.json').read_text())
cases += [dict(id=k,full=v,category='状态') for k,v in [('silent','没听到声音'),('listening','正在听…'),('idle','准备好了'),('audio-stopped','音频中断，正在恢复')]]
wiring=(out/'PriorityWiring.swift').read_text().replace('func tr(_ s: String) -> String { s }', 'var oneStatusTable: [String:String] = [:]\nfunc tr(_ s: String) -> String { oneStatusTable[s] ?? s }')
(out/'OneStatusWiring.swift').write_text(wiring)
(out/'one-status-cases.json').write_text(json.dumps(cases,ensure_ascii=False))
code='''import Foundation
func captionEmpty(_ state: PriorityHost, empty: Bool, pending: Bool) -> Bool {
 let displayedChunks: [Int] = empty ? [] : [1]; let hasPending = pending
 return '''+empty+'''
}
func desktopSlab(_ state: PriorityHost, empty: Bool, pending: Bool) -> Bool {
 let displayedChunks: [Int] = empty ? [] : [1]; let hasPending = pending
 return '''+slab_guard+'''
}
func previewFooter(external: Bool, example: Bool) -> Bool {
 let statusPresentedExternally = external; let isExample = example
 return '''+footer+'''
}
func menuSecondary(_ state: PriorityHost, label: String) -> Bool {
 let statusLabel = label
 return '''+secondary+'''
}
@main struct OneStatus {
 static func main() throws {
 let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String:Any]]
 var cells=0
 for item in cases { for language in ["zh-Hans","zh-Hant","ja","en","ko"] {
  oneStatusTable = language == "zh-Hans" ? [:] : try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "Resources/l10n/"+language+".json"))) as! [String:String]
  let state=PriorityHost(); let id=item["id"] as! String
  state.status=tr(item["full"] as! String).replacingOccurrences(of:"%@",with:"100")
  state.paused=id == "paused"; state.running=id != "idle"
  state.silentTooLong=id == "silent"
  state.audioStalled=id == "audio-stopped" || id == "audio-recovering"
  if id == "offline" { for _ in 0..<3 { state.connectivity.failed(chunk: UUID(), enabled: true) } }
  if item["category"] as? String == "错误" || item["sourceOnly"] as? Bool == true {
   state.errorBanner=CaptionBanner(text:state.status,action:nil)
  }
  for compact in [false,true] { for empty in [false,true] { for pending in [false,true] {
   // Appearance cannot change this production guard; check both appearances explicitly.
   for appearance in ["light", "dark"] {
    precondition(desktopSlab(state,empty:empty,pending:pending) == (!empty || pending || captionEmpty(state,empty:empty,pending:pending)), "slab/padding visibility \\(id)/\\(appearance)")
    if id == "silent" && empty && !pending { precondition(!desktopSlab(state,empty:true,pending:false)) }
   }
   for surface in ["desktop","island-expanded"] {
    let status = surface == "desktop" ? state.desktopCaptionStatusBanner : state.captionStatusBanner
    let fallback=captionEmpty(state,empty:empty,pending:pending) ? 1 : 0
    // Pause row and the winning status can differ; only count the same semantic notice.
    let pause=state.paused && !state.captionDisplayStatus.showsLabel ? 1 : 0
    let occurrences=(status == nil ? 0 : 1)+pause+fallback
    precondition(occurrences <= 1,"duplicate \\(id)/\\(language)/\\(surface)/\\(compact)")
    if empty && !pending { precondition(occurrences == 1) }
    cells+=1
   }
   // Main header owns the status; standalone preview owns its footer.
   precondition(!previewFooter(external:true,example:false))
   precondition(previewFooter(external:false,example:false))
   // Example footer is a sample label, not a state message.
   let label=menuHeader(state)
   let headerCarriesState=state.captionDisplayStatus.showsLabel || state.paused || label == state.status
   let menuCount=(headerCarriesState ? 1 : 0)+(menuSecondary(state,label:label) ? 1 : 0)
   precondition(menuCount == 1,"menu \\(id)")
   cells+=3
  }}}
  state.dismissDesktopErrorStatus()
  if state.captionDisplayStatus.showsLabel { precondition(!captionEmpty(state,empty:true,pending:false),"Esc must not resurrect a notice in the text slab") }
 }}
 print("PASS one status: \\(cases.count) states × 5 languages × compact/content/pending × 5 surfaces = \\(cells) checks; no status resurrection after Esc; empty desktop slab/padding absent in light and dark, content modifiers unchanged")
 }
}
'''
(out/'OneStatus.swift').write_text(code)
