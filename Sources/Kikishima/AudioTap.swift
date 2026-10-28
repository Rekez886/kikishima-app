// 系统音频捕获：Core Audio process taps（macOS 14.4+）
// 改编自 AudioCap (c) 2024 Guilherme Rambo, BSD 许可 — 见 NOTICE.md
import Foundation
import AudioToolbox
import AVFoundation
import OSLog

private let logger = Logger(subsystem: "com.kikishima.mac", category: "AudioTap")

extension String: @retroactive LocalizedError {
    public var errorDescription: String? { self }
}

extension AudioObjectID {
    static let unknown = kAudioObjectUnknown
    var isValid: Bool { self != kAudioObjectUnknown }

    static func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID.unknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        guard err == noErr else { throw trAny("读默认输出设备失败：%@", err) }
        return id
    }

    func readDeviceUID() throws -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let err = withUnsafeMutablePointer(to: &uid) { p in
            AudioObjectGetPropertyData(self, &addr, 0, nil, &size, p)
        }
        guard err == noErr, let uid else { throw trAny("读设备 UID 失败：%@", err) }
        return uid as String
    }

    func readAudioTapStreamBasicDescription() throws -> AudioStreamBasicDescription {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var desc = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let err = AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &desc)
        guard err == noErr else { throw trAny("读 tap 音频格式失败：%@", err) }
        return desc
    }
}

/// tap 启动失败的分类：只有 tap 创建失败才对应「系统录音」权限，其他是设备问题
enum AudioTapError: LocalizedError {
    case permissionOrTapCreation(OSStatus)
    case device(String, OSStatus)
    var errorDescription: String? {
        switch self {
        case .permissionOrTapCreation(let e): return trAny("无法捕获系统音频（错误 %@）。可能还没允许「系统录音」权限。", e)
        case .device(let what, let e): return trAny("%@失败：%@", trAny(what), e)
        }
    }
    var isPermission: Bool { if case .permissionOrTapCreation = self { return true } else { return false } }
}

/// 全局系统音频 tap：所有进程的输出音频拷贝一份给我们，系统照常出声
final class SystemAudioTap {
    private var tapID: AudioObjectID = .unknown
    private var aggregateID: AudioObjectID = .unknown
    private var procID: AudioDeviceIOProcID?
    private(set) var streamDescription: AudioStreamBasicDescription?
    private let queue = DispatchQueue(label: "audio-tap", qos: .userInitiated)
    /// 默认输出设备变了（插拔耳机 / 切 HDMI / Zoom 自己切）：聚合设备钉在旧设备上会静音，由上层重建
    var onDefaultDeviceChanged: (() -> Void)?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var deviceAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    var isRunning: Bool { aggregateID.isValid }
    /// 是否监听默认输出设备变化（onboarding 探测用的临时 tap 不需要）
    private let watchesDevice: Bool
    init(watchesDevice: Bool = true) { self.watchesDevice = watchesDevice }

    /// Core Audio can return noErr even when TCC supplies only silence. A successful
    /// start alone is not authorization evidence. Never consult the cached grant.
    enum PermissionEvidence { case verified, unconfirmed, failed }

    static func probePermission() async -> PermissionEvidence {
        await Task.detached(priority: .userInitiated) { probePermissionBlocking() }.value
    }

    private static func probePermissionBlocking() -> PermissionEvidence {
        let probe = SystemAudioTap(watchesDevice: false)
        let signal = DispatchSemaphore(value: 0)
        defer { probe.stop() }
        do {
            try probe.start { _, data, _, _, _ in
                for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: data)) {
                    guard let bytes = buffer.mData else { continue }
                    let samples = bytes.assumingMemoryBound(to: Float.self)
                    for index in 0..<(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size) {
                        if samples[index].isFinite && abs(samples[index]) > 0.000001 {
                            signal.signal()
                            return
                        }
                    }
                }
            }
            return signal.wait(timeout: .now() + 2) == .success ? .verified : .unconfirmed
        } catch {
            return .failed
        }
    }

    func start(ioBlock: @escaping AudioDeviceIOBlock) throws {
        guard !aggregateID.isValid, !tapID.isValid else { return }   // 防重入
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        var newTapID = AudioObjectID.unknown
        var err = AudioHardwareCreateProcessTap(desc, &newTapID)
        guard err == noErr else { throw AudioTapError.permissionOrTapCreation(err) }
        tapID = newTapID
        // 中途任何一步失败都回滚已建对象，不留半成品
        var ok = false
        defer { if !ok { stop() } }

        streamDescription = try tapID.readAudioTapStreamBasicDescription()

        let outputUID = try AudioDeviceID.readDefaultSystemOutputDevice().readDeviceUID()
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Kikishima-Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString
            ]]
        ]
        err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateID)
        guard err == noErr else { throw AudioTapError.device("创建聚合设备", err) }

        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue, ioBlock)
        guard err == noErr else { throw AudioTapError.device("创建 IO proc", err) }
        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else { throw AudioTapError.device("启动聚合设备", err) }
        if watchesDevice { installDeviceListener() }
        ok = true
        logger.info("tap started")
    }

    /// 监听器整个对象生命周期只装一次（AudioObjectRemovePropertyListenerBlock 对 Swift 闭包不可靠，反复装会累积）
    private func installDeviceListener() {
        guard deviceListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { guard let self, self.isRunning else { return }; self.onDefaultDeviceChanged?() }
        }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &deviceAddr, DispatchQueue.main, block)
    }

    private func removeDeviceListener() {
        if let block = deviceListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &deviceAddr, DispatchQueue.main, block)
            deviceListener = nil
        }
    }

    func stop() {
        if aggregateID.isValid {
            AudioDeviceStop(aggregateID, procID)
            queue.sync {}   // 等正在跑的 IO 回调结束，再拆对象
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            procID = nil
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
        logger.info("tap stopped")
    }

    deinit { stop(); removeDeviceListener() }
}
