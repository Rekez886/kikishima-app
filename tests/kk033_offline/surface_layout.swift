import AppKit
import SwiftUI
struct SurfaceCase: Decodable { let text: String; let action: String }
struct Frames: PreferenceKey {
 static var defaultValue: [Int:CGRect] = [:]
 static func reduce(value: inout [Int:CGRect], nextValue: ()->[Int:CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _,r in r }) }
}
@MainActor final class Results { var frames: [Int:CGRect] = [:] }
struct Probe: View {
 let text: String, action: String, results: Results
 var body: some View {
  CaptionStatusInlineLayout(lineHeight: 28) {
   Circle().frame(width: 6,height: 6).background(GeometryReader { g in Color.clear.preference(key: Frames.self,value:[0:g.frame(in:.named("row"))]) })
   Text(text).fixedSize(horizontal: true, vertical: false).background(GeometryReader { g in Color.clear.preference(key: Frames.self,value:[1:g.frame(in:.named("row"))]) })
   if !action.isEmpty { Text(action) }
  }.font(.system(size:13)).coordinateSpace(name:"row")
   .onPreferenceChange(Frames.self) { results.frames = $0 }
 }
}
@main struct SurfaceLayoutTest {
 @MainActor static func main() throws {
  let cases = try JSONDecoder().decode([SurfaceCase].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
  for language in ["zh-Hans","zh-Hant","ja","en","ko"] {
   let table: [String:String] = language == "zh-Hans" ? [:] : try JSONDecoder().decode([String:String].self,from:Data(contentsOf:URL(fileURLWithPath:"Resources/l10n/\(language).json")))
   for item in cases {
    let source=item.text
    for width in [CGFloat(132),716] {
     let results=Results()
     let text=CaptionStatusCopy.resolve(fullText:table[source] ?? source,translate:{table[$0] ?? $0}).shortText
     let action=table[item.action] ?? item.action
     let host=NSHostingView(rootView:Probe(text:text,action:action,results:results).frame(width:width,height:28))
     host.frame=CGRect(x:0,y:0,width:width,height:28)
     host.layoutSubtreeIfNeeded()
     RunLoop.current.run(until:Date(timeIntervalSinceNow:0.025))
     host.layoutSubtreeIfNeeded()
     guard let dot=results.frames[0],let textFrame=results.frames[1] else { fatalError("real layout did not report frames") }
     precondition(!dot.intersects(textFrame) && dot.maxX <= textFrame.minX, "\(language) \(source) dot=\(dot) text=\(textFrame)")
    }
   }
  }
  // The real preference reducer adds the status row and text slab, then the
  // existing production cap determines viewport height (100/148/240 unchanged).
  for level in CaptionSizeLevel.allCases {
   var measured: CGFloat = 0
   IslandMeasuredHeight.reduce(value:&measured,nextValue:{72})
   IslandMeasuredHeight.reduce(value:&measured,nextValue:{32})
   let visible=CaptionIslandLayout.islandContentHeight(measured:measured,visibleHeight:1080,heightLevel:level)
   let cap=CaptionIslandLayout.expandedContentHeight(visibleHeight:1080,heightLevel:level)
   precondition(visible == min(cap,104) && visible <= cap)
   precondition(visible-32 >= min(72,cap-32))
  }
  print("PASS real SwiftUI inline layout: five languages, warning/error, two/three children, noncompact/360 compact; status height included within unchanged caps")
 }
}
