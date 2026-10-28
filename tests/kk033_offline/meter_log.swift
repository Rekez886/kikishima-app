import Foundation
import AVFoundation
@main struct MeterLogTest {
 static func main() throws {
  let meter = AudioMeter()
  let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
  buffer.frameLength=480
  for i in 0..<480 { buffer.floatChannelData![0][i] = 0.01 }
  let start = ProcessInfo.processInfo.systemUptime
  while ProcessInfo.processInfo.systemUptime - start < 1.25 {
   meter.ingest(buffer.audioBufferList, format: format)
   Thread.sleep(forTimeInterval: 0.01)
  }
  Thread.sleep(forTimeInterval: 0.15)
  let path = ProcessInfo.processInfo.environment["KIKISHIMA_LEVEL_LOG"]!
  let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
  precondition((9...14).contains(lines.count), "10Hz throttle not preserved: \(lines.count)")
  precondition(lines.allSatisfy { $0.contains("voiceDetected=true") })
  print("PASS real AudioMeter.ingest: \(lines.count) log lines in 1.25s, no pollMeter calls")
 }
}
