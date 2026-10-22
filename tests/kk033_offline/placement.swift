import Foundation
import AppKit
@main struct PlacementTest {
 @MainActor static func main() {
  if CommandLine.arguments.contains("invalid") {
   _ = ShootSimulation.runIfRequested()
   fatalError("invalid placement did not exit before startup")
  }
  let scenarios = ShootSimulation.Mode.allCases.map(\.rawValue)
  for raw in scenarios {
   let mode = ShootSimulation.Mode(rawValue: raw)!
   let state = CaptionState()
   ShootSimulation.configure(state, mode: mode)
   let fallback = ["desktop", "error", "error-login", "error-quota"].contains(raw) ? "window" : "island"
   let expected: String
   switch ProcessInfo.processInfo.environment["KIKISHIMA_SHOOT_PLACEMENT"] {
   case "desktop": expected = "window"
   case "island": expected = "island"
   default: expected = fallback
   }
   precondition(state.captionSurface == expected, "placement failed for \(raw)")
   if raw.hasPrefix("source-only-") && mode != .sourceOnlyTransition {
    precondition(state.translationPaused && state.compactCaptions && state.captionDisplay == "both")
    precondition(state.chunks.count == 2 && !state.chunks[0].en.isEmpty && !state.chunks[0].zh.isEmpty && state.chunks[0].translationComplete && state.chunks[1].zh.isEmpty && !state.chunks[1].en.isEmpty)
    let full = state.errorBanner?.text ?? state.status
    precondition(CaptionStatusCopy.resolve(fullText: full, translate: { $0 }).isSourceOnly)
   }
   if mode == .sourceOnlyTransition {
    precondition(!state.chunks[0].zh.isEmpty)
    ShootSimulation.applySourceOnlyTransition(state)
    precondition(state.translationPaused && state.chunks[0].zh.isEmpty && !state.chunks[0].en.isEmpty)
   }
   _ = ShootSimulation.requestedOpenMenu
   _ = ShootSimulation.requestedIslandTransition
   if mode == .longSentence {
    let width = CaptionIslandLayout.textColumnWidth(islandWidth: CaptionIslandLayout.expandedWidth(screenWidth: 1512, widthLevel: .medium))
    let points = CaptionHierarchy.fontSize(current: true, userSize: CaptionAppearance.fontSize(.medium))
    let font = NSFont.systemFont(ofSize: points, weight: .medium)
    let text = state.chunks[0].zh as NSString
    let natural = text.size(withAttributes: [.font: font])
    let wrapped = text.boundingRect(with: NSSize(width: width, height: 1000), options: [.usesLineFragmentOrigin], attributes: [.font: font])
    precondition(natural.width > width && wrapped.height > natural.height && wrapped.height <= natural.height * 2 + 1, "long-sentence must occupy two medium-island lines")
    print("PASS long-sentence: font \(points)pt, column \(width)pt, natural \(natural.width)pt, wrapped height \(wrapped.height)pt, line \(natural.height)pt")
   }
   if mode == .silent {
    let forced = ProcessInfo.processInfo.environment["KIKISHIMA_SHOOT_ISLAND_EXPANDED"] == "1"
    precondition(state.wantsIslandExpanded == forced)
    state.islandDormant = true
    precondition(state.wantsIslandExpanded == forced)
   }
   ShootSimulation.stop(state)
  }
  print("PASS real SIM configure: placement for all nineteen scenes, override/default")
 }
}
