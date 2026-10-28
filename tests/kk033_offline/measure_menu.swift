import AppKit
import SwiftUI

// Same NSHostingView + frame preference measurement as the status width gate.
@main struct MenuMeasure {
 @MainActor static func frames<V: View>(_ view: V, width: CGFloat) -> [Int:CGRect] {
  let captured=Frames()
  let host=NSHostingView(rootView:view.coordinateSpace(name:"width-row")
   .onPreferenceChange(FramePreference.self) { captured.values=$0 }
   .environment(\.colorScheme,.light).frame(width:width))
  host.appearance=NSAppearance(named:.aqua)
  host.frame=CGRect(x:0,y:0,width:width,height:500)
  host.layoutSubtreeIfNeeded()
  RunLoop.current.run(until:Date(timeIntervalSinceNow:0.025))
  host.layoutSubtreeIfNeeded()
  precondition(captured.values[1] != nil)
  return captured.values
 }
 @MainActor static func main() throws {
  var rows:[[String:Any]]=[]; var failed=false
  let baseline = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "tests/kk033_offline/r16_status_baseline.json"))) as! [[String:String]]
  for language in ["zh-Hans","zh-Hant","ja","en","ko"] {
   languageTable=language == "zh-Hans" ? [:] : try JSONDecoder().decode([String:String].self,from:Data(contentsOf:URL(fileURLWithPath:"Resources/l10n/\(language).json")))
   for expected in baseline where expected["language"] == language {
    let actual = CaptionStatusCopy.resolve(fullText: expected["full"]!, translate: tr)
    precondition(actual.shortText == expected["short"]!, "65ca337 status copy changed: \(language) \(expected)")
   }
   let labels=[tr("双语"),captionDisplayText("仅译文"),captionDisplayText("仅原文")]
   let expectedLabels: [String:[String]] = ["zh-Hans": ["双语", "仅译文", "仅原文"], "zh-Hant": ["雙語", "僅譯文", "僅原文"], "ja": ["二言語", "訳文のみ", "原文のみ"], "en": ["Bilingual", "Translation", "Source"], "ko": ["이중 언어", "번역만", "원문만 표시"]]
   precondition(labels == expectedLabels[language]!, "Selector vocabulary changed")
   for (surface, measured) in [("preview", frames(PreviewWidthView(fallback:false), width:previewContentWidth))] {
    for (index,text) in labels.enumerated() {
     let natural=(text as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:12)])
     let frame=measured[index+1]!
     let pass=frame.width+0.1>=natural.width && frame.height<=natural.height+1 && frame.minX>=0 && frame.maxX <= (surface == "settings" ? settingsContentWidth : previewContentWidth)
     failed = failed || !pass
     rows.append(["kind":surface,"language":language,"text":text,"natural":natural.width,"surfaceWidth":surface == "settings" ? settingsContentWidth : previewContentWidth,"available":measured[index+101]!.width-12,"renderedWidth":frame.width,"renderedHeight":frame.height,"pass":pass])
    }
   }
  }
  print("PASS r16 fixed 65ca337 status baseline: 110 localized rows")
  let data=try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys])
  try data.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
  for row in rows { print(row) }
  print("\(failed ? "FAIL" : "PASS") r16 preview selector width gate")
  if failed { exit(1) }
 }
}
