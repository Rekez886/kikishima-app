import Foundation
@main struct CollapseTest {
 @MainActor static func main() async throws {
  for level in [CaptionCollapseLevel.medium, .fast] {
   let s = CaptionState.shared, probe = CollapseProbe()
   s.level = level; s.islandDormant = false
   // Reproduce NSHostingView onAppear before surface visibility.
   probe.noteActivity()
   probe.surfaceVisible = true
   precondition(s.offline && s.wantsIslandExpanded)
   let secs = CaptionAppearance.collapseSeconds(level)
   // Not before the configured delay; then poll (Task.sleep timer leeway can fire late).
   try await Task.sleep(for: .seconds(secs - 0.5))
   precondition(!s.islandDormant && probe.syncCount == 0)
   let deadline = ContinuousClock.now + .seconds(2.5)
   while !s.islandDormant && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
   precondition(s.islandDormant && !s.wantsIslandExpanded && probe.syncCount == 1)
  }
  print("PASS offline collapses: default/fast, onAppear before visible, real timer")
 }
}
