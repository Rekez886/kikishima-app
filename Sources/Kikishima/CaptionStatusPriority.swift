import Foundation

/// Display selection only: this function never owns or resets condition timers.
enum CaptionStatusPriority: Equatable {
    case error, sourceOnly, offline, audioStalled, silent, listening, idle

    static func resolve(hasError: Bool, offline: Bool, silentTooLong: Bool,
                        audioStalled: Bool, running: Bool, paused: Bool, sourceOnly: Bool = false) -> Self {
        if hasError { return sourceOnly ? .sourceOnly : .error }
        if offline { return .offline }
        if running && audioStalled { return .audioStalled }
        if running && silentTooLong { return .silent }
        if sourceOnly { return .sourceOnly }
        return running && !paused ? .listening : .idle
    }

    var isWarning: Bool { self == .sourceOnly || self == .offline || self == .audioStalled || self == .silent }
    var showsLabel: Bool { self == .error || isWarning }
    var sourceText: String? {
        switch self {
        case .error, .sourceOnly, .idle: return nil
        case .offline: return "离线，正在重连"
        case .audioStalled: return "音频中断，正在恢复"
        case .silent: return "没听到声音"
        case .listening: return "正在听…"
        }
    }
}

/// Unknown IO loss is not proof of denied permission. Only explicit evidence
/// supplied by the capture path may select a permission error.
enum CaptionAudioInterruption: Equatable {
    case none, recovering, deviceMissing, systemPermission
    static func resolve(ioStopped: Bool, rebuilding: Bool, hasUsableDevice: Bool,
                        systemPermissionFailed: Bool) -> Self {
        if systemPermissionFailed { return .systemPermission }
        if !hasUsableDevice { return .deviceMissing }
        return ioStopped || rebuilding ? .recovering : .none
    }
    var requiresRepair: Bool { self == .deviceMissing || self == .systemPermission }
    var settingsURL: String? {
        switch self {
        case .deviceMissing: return "x-apple.systempreferences:com.apple.Sound-Settings.extension?output"
        case .systemPermission: return "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        default: return nil
        }
    }
    var sourceText: String? {
        switch self {
        case .deviceMissing: return "没有输出设备，听不到会议声音"
        case .systemPermission: return "没有「系统录音」权限，听不到会议声音。系统设置 › 隐私与安全性 › 屏幕录制与系统录音 里允许 Kikishima。"
        default: return nil
        }
    }
}

/// An occurrence ends only when its underlying condition ends, not when a
/// higher-priority state temporarily covers it.
struct CaptionNoticeVisibility {
    private var silentDismissed = false
    private var stoppedDismissed = false
    mutating func receive(silent: Bool, stopped: Bool) {
        if !silent { silentDismissed = false }
        if !stopped { stoppedDismissed = false }
    }
    mutating func dismiss(_ status: CaptionStatusPriority) {
        if status == .silent { silentDismissed = true }
        if status == .audioStalled { stoppedDismissed = true }
    }
    func isVisible(_ status: CaptionStatusPriority) -> Bool {
        if status == .silent { return !silentDismissed }
        if status == .audioStalled { return !stoppedDismissed }
        return true
    }
}

/// Display copy only: error precedence and full menu/AX explanations are retained.
struct CaptionStatusCopy {
    let shortText: String
    let fullText: String
    let isSourceOnly: Bool
    let isSaveFailure: Bool
    static let shortForms: [(String, String)] = [
        ("登录已过期，重新登录后继续翻译", "登录过期"),
        ("已退出登录，字幕只显示原文；登录后继续翻译", "仅原文"),
        ("音频仍无法捕获：%@", "采音失败"),
        ("无法继续：%@", "无法继续"),
        ("启动失败：%@", "启动失败"),
        ("输出设备切换后无法继续捕获音频：%@", "采音失败"),
        ("转写引擎反复中断：%@", "字幕中断"),
        ("转写引擎中断：%@", "字幕中断"),
        ("需要订阅 Pro 才能继续翻译", "仅原文"),
        ("今日免费额度已被用完，明天再来，或升级 Pro 不受影响", "仅原文"),
        ("本周免费额度已用完，%@ 重置", "仅原文"),
        ("邀请码已兑换，账号已升级 Pro", "Pro 已开通"),
        ("已停止采音，正在完成最后一句…", "收尾中"),
        ("上一次启动还在收尾，请稍后再试", "收尾中"),
        ("下载转写模型 %@%", "下载中 %@%"),
        ("输出设备已切换，继续字幕", "设备已切换"),
        ("已停止 · 记录已存 %@", "已保存"),
        ("已停止 · 记录保存失败: %@", "保存失败"),
        ("额度已用完 · 仅转写", "仅原文"),
        ("免费额度今日用尽 · 仅转写", "仅原文"),
        ("没有可存的帧（气泡模式开着且会议窗口在吗？）", "无可存画面"),
        ("已暂停 · 声音不再记录", "已暂停"),
        ("请求太频繁，稍等片刻", "请求过频"),
        ("离线，正在重连", "重连中"),
        ("没有「系统录音」权限，听不到会议声音。系统设置 › 隐私与安全性 › 屏幕录制与系统录音 里允许 Kikishima。", "缺录音权限"),
        ("开发令牌已启用", "开发令牌启用"),
        ("正在切换为%@…", "切换中"),
        ("转写重连中…", "重连中"),
        ("快照已存 %@", "已保存"),
        ("音频中断，正在恢复", "音频恢复中"),
        ("没有输出设备，听不到会议声音", "无输出设备")
    ]
    static let sourceOnlyForms: Set<String> = [
        "需要订阅 Pro 才能继续翻译",
        "已退出登录，字幕只显示原文；登录后继续翻译",
        "今日免费额度已被用完，明天再来，或升级 Pro 不受影响",
        "本周免费额度已用完，%@ 重置",
        "额度已用完 · 仅转写",
        "免费额度今日用尽 · 仅转写"
    ]
    static func resolve(fullText: String, translate: (String) -> String) -> Self {
        for (source, short) in shortForms {
            let template = translate(source)
            var argument: String?
            if template != fullText {
                let parts = template.components(separatedBy: "%@")
                guard parts.count == 2, fullText.hasPrefix(parts[0]), fullText.hasSuffix(parts[1]),
                      fullText.count >= parts[0].count + parts[1].count else { continue }
                argument = String(fullText.dropFirst(parts[0].count).dropLast(parts[1].count))
            }
            let rendered = translate(short).replacingOccurrences(of: "%@", with: argument ?? "%@")
            return Self(shortText: rendered, fullText: fullText,
                isSourceOnly: sourceOnlyForms.contains(source),
                isSaveFailure: source == "已停止 · 记录保存失败: %@")
        }
        return Self(shortText: fullText, fullText: fullText, isSourceOnly: false, isSaveFailure: false)
    }
}
