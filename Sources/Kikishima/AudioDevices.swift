// 输出设备：列出、读默认、切换默认（菜单栏「正在听：xxx」+ 切换）。tap 是全局进程 tap，跟随默认输出；切了设备上层会重建聚合设备
import Foundation
import AudioToolbox

enum AudioDevices {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
    }

    private static func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    nonisolated static func name(of id: AudioDeviceID) -> String? {
        var addr = address(kAudioObjectPropertyName)
        var cf: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let err = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
        guard err == noErr, let cf else { return nil }
        return cf as String
    }

    /// 有输出流的设备（扬声器 / 耳机 / HDMI / AirPods…），排除我们自己的聚合设备
    nonisolated static func outputDevices() -> [Device] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        var out: [Device] = []
        for id in ids {
            var sAddr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
            var sSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &sAddr, 0, nil, &sSize) == noErr, sSize > 0 else { continue }
            guard let n = name(of: id), !n.hasPrefix("Kikishima") else { continue }
            out.append(Device(id: id, name: n))
        }
        return out
    }

    nonisolated static func defaultOutput() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// 同时改「默认输出」与「系统声音输出」（和 系统设置 › 声音 里点一下等价）
    @discardableResult
    nonisolated static func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
        var dev = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a1 = address(kAudioHardwarePropertyDefaultOutputDevice)
        var a2 = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        let e1 = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a1, 0, nil, size, &dev)
        let e2 = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a2, 0, nil, size, &dev)
        return e1 == noErr && e2 == noErr
    }
}

/// Read before the first menu body, then refresh at each presentation. Offscreen
/// review has no appearance lifecycle guarantee and must not depend on host audio.
enum MenuOutputDevice {
    static func label(_ name: String?, none: String) -> String {
        guard let name, !name.isEmpty else { return none }
        return name
    }
    static func readName() -> String? {
#if SHOOT || DEBUG
        if ProcessInfo.processInfo.environment["KIKISHIMA_SHOOT_RENDER"] != nil {
            return ShootSimulation.requestedMode == .errorDevice ? nil : "Review Speakers"
        }
#endif
        return AudioDevices.defaultOutput().flatMap { AudioDevices.name(of: $0) }
    }
}
