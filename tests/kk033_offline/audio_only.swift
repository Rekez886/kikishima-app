import Foundation
@main struct AudioOnlyTest {
 @MainActor static func main() {
  precondition(ShootAudioOnly.requested)
  launchProbe()
  precondition(SystemAudioTap.starts == 1 && AudioMeter.ingested == 1)
  ShootAudioOnly.start()
  precondition(SystemAudioTap.starts == 1)
  ShootAudioOnly.stop()
  precondition(SystemAudioTap.stops == 1)
  print("PASS extracted audio-only startup: tap feeds meter; no engine/Translator/network dependencies; early return")
 }
}
