import AppKit
import SwiftUI
import CoreText

// Same NSHostingView + frame preference measurement as the status width gate.
@main struct MenuMeasure {
 @MainActor static func frames<V: View>(_ view: V, width: CGFloat = menuContentWidth) -> [Int:CGRect] {
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
   let state=MenuWidthState(uiLanguage:language)
   let picker=frames(MenuWidthView(state:state,header:false))
   let labels=[tr("双语"),captionDisplayText("仅译文"),captionDisplayText("仅原文")]
   let expectedLabels: [String:[String]] = ["zh-Hans": ["双语", "仅译文", "仅原文"], "zh-Hant": ["雙語", "僅譯文", "僅原文"], "ja": ["二言語", "訳文のみ", "原文のみ"], "en": ["Bilingual", "Translation", "Source"], "ko": ["이중 언어", "번역만", "원문만 표시"]]
   precondition(labels == expectedLabels[language]!, "Selector vocabulary changed")
   let budget=(menuContentWidth-4-4)/3-12 // outer padding, two gaps, three cells, cell padding
   for (index,text) in labels.enumerated() {
    let natural=(text as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:12)])
    let frame=picker[index+1]!
    let pass=natural.width<=budget && frame.height<=natural.height+1 && frame.width+1>=natural.width
    failed = failed || !pass
    rows.append(["kind":"segment","language":language,"text":text,"natural":natural.width,"available":budget,"renderedWidth":frame.width,"renderedHeight":frame.height,"pass":pass])
   }
   for (surface, measured) in [("settings", frames(SettingsWidthView(), width:settingsContentWidth)), ("preview", frames(PreviewWidthView(fallback:false), width:previewContentWidth))] {
    for (index,text) in labels.enumerated() {
     let natural=(text as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:12)])
     let frame=measured[index+1]!
     let pass=frame.width+0.1>=natural.width && frame.height<=natural.height+1 && frame.minX>=0 && frame.maxX <= (surface == "settings" ? settingsContentWidth : previewContentWidth)
     failed = failed || !pass
     rows.append(["kind":surface,"language":language,"text":text,"natural":natural.width,"surfaceWidth":surface == "settings" ? settingsContentWidth : previewContentWidth,"available":measured[index+101]!.width-12,"renderedWidth":frame.width,"renderedHeight":frame.height,"pass":pass])
    }
   }
   let header=frames(MenuWidthView(state:state,header:true)); let frame=header[1]!
   let text=tr("未登录，字幕只显示原文；登录后继续翻译")
   let font=NSFont.systemFont(ofSize:13,weight:.medium)
   // Text hugs its laid-out lines. Include unused trailing Spacer space, retaining
   // its system 8pt minimum and the production 8pt HStack gap.
   let available=language == "en" ? header[2]!.maxX - 8 - 8 - frame.minX : frame.width
   let attributed=NSAttributedString(string:text,attributes:[.font:font])
   let setter=CTTypesetterCreateWithAttributedString(attributed)
   var offset=0; var widths:[Double]=[]
   while offset<attributed.length {
    let count=CTTypesetterSuggestLineBreak(setter,offset,Double(frame.width))
    precondition(count>0)
    let line=CTTypesetterCreateLine(setter,CFRange(location:offset,length:count))
    widths.append(CTLineGetTypographicBounds(line,nil,nil,nil));offset+=count
   }
   if language == "en" {
    for candidate in ["Not signed in. Captions show source text only.", "Not signed in. Source text only."] {
     languageTable["未登录，字幕只显示原文；登录后继续翻译"] = candidate
     let candidateFrame = frames(MenuWidthView(state:state,header:true))[1]!
     let attr=NSAttributedString(string:candidate,attributes:[.font:font])
     let typesetter=CTTypesetterCreateWithAttributedString(attr)
     var start=0; var candidateWidths:[Double]=[]
     while start<attr.length {
      let count=CTTypesetterSuggestLineBreak(typesetter,start,Double(candidateFrame.width))
      let line=CTTypesetterCreateLine(typesetter,CFRange(location:start,length:count))
      candidateWidths.append(CTLineGetTypographicBounds(line,nil,nil,nil)); start+=count
     }
     rows.append(["kind":"candidate","language":language,"text":candidate,"available":available,"lines":candidateWidths.count,"lineWidths":candidateWidths,"margins":candidateWidths.map { Double(available)-$0 },"pass":candidateWidths.count<=2 && candidateWidths.allSatisfy { $0<=Double(available)-4 }])
    }
   }
   languageTable["未登录，字幕只显示原文；登录后继续翻译"] = text
   let natural=(text as NSString).size(withAttributes:[.font:font]).width
   let lineHeight=NSLayoutManager().defaultLineHeight(for:font)
   let pass=widths.count<=2 && widths.allSatisfy { $0<=Double(available)-(language == "en" ? 4 : 0)+(language == "en" ? 0 : 0.1) } && frame.height+1>=CGFloat(widths.count)*lineHeight
   failed = failed || !pass
   rows.append(["kind":"header","language":language,"text":text,"natural":natural,"available":available,"lines":widths.count,"lineWidths":widths,"renderedWidth":frame.width,"renderedHeight":frame.height,"pass":pass])
  }
  print("PASS r16 fixed 65ca337 status baseline: 155 localized rows")
  let data=try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys])
  try data.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
  for row in rows { print(row) }
  print("\(failed ? "FAIL" : "PASS") r16 selector/header width gate")
  if failed { exit(1) }
 }
}
