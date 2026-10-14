// 找「正在发声的窗口」：Core Audio 进程对象里谁在输出音频 → 它最前面的窗口在哪（CGWindowList，无需屏幕录制权限）
// 视频模式下字幕贴这个窗口的底部，而不是屏幕底部
import Foundation
import AudioToolbox
import AppKit

enum AudioSourceWindow {
    /// 当前有音频输出的进程（排除自己）
    nonisolated static func audioOutputPIDs() -> [pid_t] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objs) == noErr else { return [] }
        let me = getpid()
        var pids: [pid_t] = []
        for o in objs {
            var outAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0; var rsz = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(o, &outAddr, 0, nil, &rsz, &running) == noErr, running != 0 else { continue }
            var pidAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0; var psz = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(o, &pidAddr, 0, nil, &psz, &pid) == noErr, pid != me, pid > 0 { pids.append(pid) }
        }
        return pids
    }

    /// 这些进程里最前面的一个正常窗口（AppKit 坐标：原点左下），没有则 nil
    /// 浏览器：播放页所在的窗口通常就是最前的浏览器窗口；多窗口时取最前
    static func frontWindowFrame(for pids: [pid_t]) -> NSRect? {
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let set = Set(pids.map { Int($0) })
        // CGWindowList 从前到后排列；跳过菜单栏/浮窗层（layer != 0）和太小的辅助窗
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? Int, set.contains(pid),
                  (w[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"], wd > 300, ht > 200 else { continue }
            // CG 坐标（原点左上，基于主屏）→ AppKit（原点左下）
            let primaryH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
                ?? NSScreen.screens.first?.frame.height ?? 0
            return NSRect(x: x, y: primaryH - y - ht, width: wd, height: ht)
        }
        return nil
    }

    /// 一步到位：正在发声窗口的位置
    static func current() -> NSRect? { frontWindowFrame(for: audioOutputPIDs()) }
}
