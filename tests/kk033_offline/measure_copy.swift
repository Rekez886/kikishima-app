import AppKit
import SwiftUI
struct CopyButton: Decodable { let action: String; let key: String }
struct CopyCase: Decodable { let id: String; let full: String; let short: [String:String]; let button: CopyButton?; let sourceOnly: Bool }
var languageTable: [String:String] = [:]
func tr(_ key: String) -> String { languageTable[key] ?? key }
func trAny(_ key: String) -> String { tr(key) }
struct FramePreference: PreferenceKey {
 static var defaultValue: [Int:CGRect] = [:]
 static func reduce(value: inout [Int:CGRect], nextValue: ()->[Int:CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _,new in new }) }
}
extension View {
 func captureFrame(_ id: Int) -> some View {
  background(GeometryReader { g in Color.clear.preference(key: FramePreference.self, value: [id:g.frame(in:.named("width-row"))]) })
 }
}
final class Frames { var values: [Int:CGRect] = [:] }
struct WidthResult: Codable {
 let id: String, language: String, text: String, full: String, color: String, button: String
 let island: Double, desktop: Double, right: Double, menu: Double
 let frames: [String: [Double]]
 let pass: Bool
}
@main struct CopyMeasure {
 @MainActor static func rendered<V: View>(_ view: V, width: CGFloat?) -> [Int:CGRect] {
  let frames=Frames()
  let host=NSHostingView(rootView:view.coordinateSpace(name:"width-row")
   .onPreferenceChange(FramePreference.self) { frames.values=$0 }
   .environment(\.colorScheme,.light).frame(width:width,alignment:.leading))
  host.appearance=NSAppearance(named:.aqua)
  host.frame=CGRect(x:0,y:0,width:width ?? 1200,height:40)
  host.layoutSubtreeIfNeeded()
  RunLoop.current.run(until:Date(timeIntervalSinceNow:0.025))
  host.layoutSubtreeIfNeeded()
  precondition(frames.values[0] != nil && frames.values[1] != nil,"missing production frames")
  return frames.values
 }
 @MainActor static func main() throws {
  let items=try JSONDecoder().decode([CopyCase].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
  let desktopBudget=CaptionDesktopStatusLayout(width:360,height:90,compact:true,titlebarHeight:0,statusHeight:28,hasStatus:true,leadingInset:32).status.width
  var results:[WidthResult]=[]
  for language in ["zh-Hans","zh-Hant","ja","en","ko"] {
   languageTable=language == "zh-Hans" ? [:] : try JSONDecoder().decode([String:String].self,from:Data(contentsOf:URL(fileURLWithPath:"Resources/l10n/\(language).json")))
   for item in items {
    let full=tr(item.full).replacingOccurrences(of:"%@",with:item.id == "model-download" ? "100" : "reason")
    let copy=CaptionStatusCopy.resolve(fullText:full,translate:tr)
    let expected=item.short[language]!.replacingOccurrences(of:"%@",with:item.id == "model-download" ? "100" : "reason")
    precondition(copy.shortText == expected,"\(item.id)/\(language) expected \(expected) actual \(copy.shortText)")
    precondition(copy.fullText == full && copy.isSourceOnly == item.sourceOnly)
    let state=CaptionState(); state.status=full
    var action:CaptionBanner.Action?
    switch item.button?.action.split(separator:".").last {
    case "login": action = .login
    case "upgrade": action = .upgrade
    case "retry": action = .retry
    case "openSettings": action = .openSettings
    default: action = nil
    }
    // Each catalog row exercises its production presentation, including status
    // fallbacks otherwise hidden by a higher-priority condition in a live call.
    let error = action != nil || item.id == "record-save-failed"
    if error || item.sourceOnly { state.errorBanner=CaptionBanner(text:full,severity:.error,action: item.id == "signed-out" ? .login : ["pro-required", "free-pool-exhausted", "weekly-quota-exhausted"].contains(item.id) ? .upgrade : action) }
    else { state.errorBanner=CaptionBanner(text:full,severity:.error) }
    let banner = error || item.sourceOnly ? state.captionStatusBanner! : CaptionBanner(text:full,severity:.info)
    let row = RowInput(captionDisplayStatus: error ? .error : item.sourceOnly ? .sourceOnly : .offline,
        captionStatusBanner: banner, captionStatusShortText: copy.shortText, captionStatusText: full)
    precondition(!item.sourceOnly || (banner.action == nil && banner.severity == .info))
    if item.id == "record-save-failed" { precondition(banner.action == nil && banner.severity == .error) }
    let islandFrames=rendered(IslandCompactLeading(state:row).fixedSize(),width:nil)
    let desktopFrames=rendered(DesktopRow(state:row,banner:banner),width:desktopBudget)
    let naturalDesktopFrames=rendered(DesktopRow(state:row,banner:banner).fixedSize(),width:nil)
    precondition((islandFrames[2] != nil) == (banner.action != nil))
    precondition((desktopFrames[2] != nil) == (banner.action != nil))
    func extent(_ frames:[Int:CGRect])->Double { Double(frames.values.map(\.maxX).max()! - frames[0]!.minX) }
    let iw=extent(islandFrames), dw=extent(naturalDesktopFrames), right=Double(desktopBudget)-dw
    var frameReport: [String:[Double]] = [:]
    for (surface,frames) in [("island",islandFrames),("desktop360",desktopFrames),("desktopNatural",naturalDesktopFrames)] {
     for (id,f) in frames { frameReport["\(surface).\(id)"] = [Double(f.minX),Double(f.minY),Double(f.width),Double(f.height)] }
    }
    let overlap=desktopFrames[0]!.intersects(desktopFrames[1]!) || (desktopFrames[2].map { $0.intersects(desktopFrames[1]!) } ?? false)
    let menu=Double((full as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:13,weight:.medium)]).width)
    results.append(WidthResult(id:item.id,language:language,text:copy.shortText,full:full,color:item.sourceOnly ? "warning" : error ? "error" : "warning",button:banner.action?.title ?? "无",island:iw,desktop:dw,right:right,menu:menu,frames:frameReport,pass:iw<=143 && right>=4 && !overlap))
   }
  }
  let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
  try encoder.encode(results).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
  let failed=results.filter { !$0.pass }
  for row in failed { print("OVERFLOW \(row.id)/\(row.language): \(row.text) island=\(row.island)/143 desktop=\(row.desktop) right=\(row.right)/4") }
  print("\(failed.isEmpty ? "PASS" : "FAIL") actual production rows: \(results.count) cells, \(failed.count) overflow")
  if !failed.isEmpty { exit(1) }
 }
}
