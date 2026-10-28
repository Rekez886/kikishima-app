import Foundation
import CoreFoundation
@main struct PriorityTest {
    static func main() {
        // Exhaustive truth table: no clock or state mutations inside selection.
        for bits in 0..<64 {
            let error = bits & 1 != 0, offline = bits & 2 != 0
            let silent = bits & 4 != 0, stalled = bits & 8 != 0
            let running = bits & 16 != 0, paused = bits & 32 != 0
            let expected: CaptionStatusPriority = error ? .error : offline ? .offline :
                running && stalled ? .audioStalled : running && silent ? .silent :
                running && !paused ? .listening : .idle
            let host = PriorityHost()
            host.errorBanner = error ? CaptionBanner(text: "action required", action: .retry) : nil
            if offline { for _ in 0..<3 { host.connectivity.failed(chunk: UUID(), enabled: true) } }
            host.silentTooLong = silent; host.audioStalled = stalled
            host.running = running; host.paused = paused
            precondition(host.captionDisplayStatus == expected)
            precondition(islandAccessibility(host) == desktopAccessibility(host))
            precondition(islandText(host) == desktopText(host) && appText(host) == host.captionStatusText)
            if expected.showsLabel {
                precondition(desktopBanner(host)?.shortText == islandText(host))
                precondition(islandColor(host) == desktopColor(host))
                precondition(islandColor(host) == (error ? .error : .warning))
            } else { precondition(desktopBanner(host) == nil) }
        }
        let clockHost = PriorityHost()
        clockHost.connectivity.advance(audioTime: 0, enabled: true)
        clockHost.connectivity.advance(audioTime: 14.9, enabled: true)
        clockHost.errorBanner = CaptionBanner(text: "action required", action: .retry)
        precondition(clockHost.captionDisplayStatus == .error)
        clockHost.errorBanner = nil
        _ = clockHost.captionDisplayStatus
        clockHost.connectivity.advance(audioTime: 15, enabled: true)
        precondition(clockHost.captionDisplayStatus == .offline) // Display changes preserve elapsed audible time.
        let host = PriorityHost()
        host.pollMeter() // Real 25-second lastLoudAt, not a simulated display timer.
        let originalLoudAt = host.meter.sample.lastLoudAt
        precondition(host.silentTooLong && host.captionDisplayStatus == .silent)
        for _ in 0..<3 { host.connectivity.failed(chunk: UUID(), enabled: true) }
        host.errorBanner = CaptionBanner(text: "action required", action: .retry)
        precondition(host.captionDisplayStatus == .error) // All three true.
        host.errorBanner = nil
        precondition(host.captionDisplayStatus == .offline) // Immediate fallback.
        precondition(host.connectivity.isOffline) // Selection did not reset policy.
        host.connectivity.succeeded(audioTime: 0)
        precondition(host.captionDisplayStatus == .silent)
        precondition(desktopText(host) == "没听到声音")
        precondition(host.meter.sample.lastLoudAt == originalLoudAt)
        host.pollMeter()
        precondition(host.silentTooLong && host.meter.sample.lastLoudAt == originalLoudAt)
        host.meter.sample.lastIOAt = CFAbsoluteTimeGetCurrent() - 6
        host.pollMeter()
        precondition(host.captionDisplayStatus == .audioStalled && host.silentTooLong)
        host.meter.sample.lastIOAt = CFAbsoluteTimeGetCurrent()
        host.pollMeter()
        precondition(host.captionDisplayStatus == .silent) // Input resumes without resetting silence.
        // Real menu getters must not wait for the final caption to finish.
        host.finishingCaptions = true
        for kind in [CaptionAudioInterruption.deviceMissing, .systemPermission, .recovering, .none] {
            host.audioInterruption = kind
            host.audioStalled = kind == .recovering
            host.silentTooLong = true
            precondition(menuHeader(host) == islandAccessibility(host))
            precondition(desktopBanner(host)?.text == menuHeader(host))
        }
        for pair in CaptionStatusCopy.shortForms {
            host.errorBanner = CaptionBanner(text: pair.0, action: .openSettings)
            precondition(islandText(host) == pair.1 && desktopText(host) == pair.1)
            precondition(menuHeader(host) == pair.0 && islandAccessibility(host) == pair.0)
            precondition(desktopBanner(host)?.shortText == pair.1)
            host.errorBanner = nil
        }
        host.finishingCaptions = false
        // Pure cause table includes unavailable/denied facts, not IO guesses.
        let causes: [(Bool, Bool, Bool, Bool, CaptionAudioInterruption)] = [
            (false,false,true,false,.none),
            (true,false,true,false,.recovering),
            (false,true,true,false,.recovering),
            (true,true,false,false,.deviceMissing),
            (true,false,true,true,.systemPermission),
            (true,true,false,true,.systemPermission)]
        for (io,rebuild,device,system,expected) in causes {
            precondition(CaptionAudioInterruption.resolve(ioStopped: io, rebuilding: rebuild, hasUsableDevice: device,
                systemPermissionFailed: system) == expected)
        }
        host.audioInterruption = .deviceMissing
        precondition(host.captionDisplayStatus == .error)
        precondition(desktopBanner(host)?.shortText == islandText(host))
        precondition(desktopBanner(host)?.action?.title == "修复")
        precondition(desktopBanner(host)?.settingsURL?.hasSuffix("com.apple.Sound-Settings.extension?output") == true)
        precondition(host.repairURL()?.absoluteString.hasSuffix("com.apple.Sound-Settings.extension?output") == true)
        host.errorBanner = CaptionBanner(text: "existing capture failure", action: .retry)
        precondition(desktopBanner(host)?.text == "existing capture failure")
        precondition(desktopBanner(host)?.action == .openSettings)
        host.errorBanner = nil
        host.audioInterruption = .systemPermission
        precondition(desktopBanner(host)?.settingsURL?.hasSuffix("Privacy_AudioCapture") == true)
        precondition(host.repairURL()?.absoluteString.hasSuffix("Privacy_AudioCapture") == true)
        host.dismissDesktopErrorStatus()
        precondition(host.captionDisplayStatus != .error)
        host.audioInterruption = .systemPermission
        precondition(host.captionDisplayStatus != .error)
        host.audioInterruption = .none
        host.audioInterruption = .systemPermission
        precondition(host.captionDisplayStatus == .error)
        host.audioInterruption = .none
        host.audioStalled = true; host.silentTooLong = true
        for _ in 0..<3 { host.connectivity.failed(chunk: UUID(), enabled: true) }
        host.errorBanner = CaptionBanner(text: "error", action: .retry)
        precondition(host.captionDisplayStatus == .error)
        host.errorBanner = nil
        precondition(host.captionDisplayStatus == .offline)
        host.connectivity.succeeded(audioTime: 0)
        precondition(host.captionDisplayStatus == .audioStalled && desktopBanner(host)?.action == nil)
        host.dismissDesktopErrorStatus()
        precondition(desktopBanner(host) == nil && host.captionDisplayStatus == .audioStalled)
        host.audioStalled = true // Repeated polling is the same occurrence.
        precondition(desktopBanner(host) == nil)
        host.audioStalled = false
        precondition(host.captionDisplayStatus == .silent && desktopBanner(host)?.action == nil)
        host.dismissDesktopErrorStatus()
        precondition(desktopBanner(host) == nil)
        host.audioStalled = true
        precondition(desktopBanner(host) != nil) // A new stopped occurrence.
        host.audioStalled = false
        precondition(desktopBanner(host) == nil) // Silence never ended behind stopped.
        host.silentTooLong = false; host.silentTooLong = true
        precondition(desktopBanner(host) != nil)
        precondition(host.meter.sample.lastLoudAt == originalLoudAt)
        let save = PriorityHost()
        save.status = "已停止 · 记录保存失败: example"
        precondition(save.captionDisplayStatus == .error)
        precondition(desktopBanner(save)?.action == nil && desktopBanner(save)?.severity == .error)
        precondition(islandText(save) == "保存失败" && menuHeader(save) == save.status)
        save.errorBanner = CaptionBanner(text: "unrepairable", action: nil)
        precondition(desktopBanner(save)?.text == "unrepairable" && desktopBanner(save)?.action == nil)
        precondition(CaptionStatusCopy.resolve(fullText: "离线，正在重连", translate: { $0 }).shortText ==
            CaptionStatusCopy.resolve(fullText: "转写重连中…", translate: { $0 }).shortText)
        print("PASS priority: 64 inputs, real surface equality, error/offline/silence fallback, unchanged 25s silence clock, stalled precedence")
    }
}
