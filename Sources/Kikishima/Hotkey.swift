// 全局快捷键：默认「双击左 ⌘」开关字幕（Wispr Flow 式）；需要「输入监控」权限
// 拒绝权限或用户改选组合键时，用 Carbon RegisterEventHotKey（无需任何权限）注册组合键，默认 ⌃⌥K
// 避免使用与 Zoom「共享屏幕」冲突的 ⌘⇧S
import Carbon.HIToolbox
import AppKit
import IOKit.hid

enum GlobalHotkey {
    enum Mode: String { case doubleCommand, combo }

    static var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: "hotkeyMode") ?? "") ?? .doubleCommand }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "hotkeyMode"); reinstall() }
    }
    /// 组合键（keyCode + Carbon 修饰键位），默认 ⌃⌥K
    static var comboKeyCode: UInt32 {
        get { UInt32(UserDefaults.standard.object(forKey: "hotkeyKeyCode") as? Int ?? Int(kVK_ANSI_K)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "hotkeyKeyCode"); reinstall() }
    }
    static var comboModifiers: UInt32 {
        get { UInt32(UserDefaults.standard.object(forKey: "hotkeyModifiers") as? Int ?? Int(controlKey | optionKey)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "hotkeyModifiers"); reinstall() }
    }

    /// 当前实际生效的方式（双击 ⌘ 需要权限，没拿到就退回组合键）
    private(set) static var effectiveMode: Mode = .combo
    /// 菜单/引导里显示用
    static var displayText: String {
        effectiveMode == .doubleCommand ? trAny("双击左 ⌘") : comboDisplay
    }
    static var comboDisplay: String {
        var s = ""
        if comboModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if comboModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if comboModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if comboModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName(comboKeyCode)
    }

    private static var hotKeyRef: EventHotKeyRef?
    /// 最近一次组合键注册的结果（0 = 成功）：设置页据此提示「被占用，换一个」
    private(set) static var lastRegisterError: OSStatus = 0
    private static var handlerInstalled = false
    private static var lastCmdUp: Date?
    private static var cmdDownAt: Date?
    private static var dirtyDuringPress = false   // ⌘ 按住期间有别的键 → 不是纯双击

    static func register() { reinstall(); watchActivation() }

    /// 输入监控权限：已授权 → true；未决定 → 弹系统提示（只弹一次）；拒绝 → false
    static var inputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }
    /// 已授权 → true；未决定 → 弹系统提示；已拒绝 → 系统不再弹，直接打开「输入监控」设置页
    static func requestInputMonitoring() -> Bool {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return true
        case kIOHIDAccessTypeDenied:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { NSWorkspace.shared.open(url) }
            return false
        default: return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }
    private static var activeObserver: Any?
    /// app 回到前台时重查权限（用户去系统设置里改完回来即生效）
    static func watchActivation() {
        guard activeObserver == nil else { return }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            let want: Mode = (mode == .doubleCommand && inputMonitoringGranted) ? .doubleCommand : .combo
            if want != effectiveMode { reinstall() }
        }
    }

    static func reinstall() {
        // 清旧
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        uninstallDoubleCommand()

        if mode == .doubleCommand, inputMonitoringGranted {
            installDoubleCommand()
            effectiveMode = .doubleCommand
        } else {
            installCombo()
            effectiveMode = .combo
        }
    }

    private static func installCombo() {
        if !handlerInstalled {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { CaptionState.shared.toggle() }
                return noErr
            }, 1, &eventType, nil, nil)
            handlerInstalled = true
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x4B494B49), id: 1) // 'KIKI'
        lastRegisterError = RegisterEventHotKey(comboKeyCode, comboModifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    // 双击 ⌘ 检测用 CGEventTap（listen-only）：只需要「输入监控」。
    // 不用 NSEvent 全局键盘监听：那条路会让 app 出现在「辅助功能（控制你的电脑）」列表里，权限过大且吓人。
    private static var eventTap: CFMachPort?
    private static var tapSource: CFRunLoopSource?

    private static func installDoubleCommand() {
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .flagsChanged {
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                GlobalHotkey.handleFlags(keyCode: keyCode, flags: event.flags)
            } else if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = GlobalHotkey.eventTap { CGEvent.tapEnable(tap: t, enable: true) }
            } else {
                GlobalHotkey.dirtyDuringPress = true   // ⌘ 按住期间敲键 / 点击 / 滚轮 → 不是纯双击
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil) else { return }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private static func uninstallDoubleCommand() {
        if let t = eventTap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        eventTap = nil; tapSource = nil
    }

    private static func handleFlags(keyCode: UInt16, flags: CGEventFlags) {
        guard keyCode == UInt16(kVK_Command) else {   // 55 = 左 ⌘（右 ⌘ 是 kVK_RightCommand）
            lastCmdUp = nil; cmdDownAt = nil; dirtyDuringPress = true
            return
        }
        // 只看四个真正的修饰键：Caps Lock / fn 亮着不影响
        let relevant: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        let f = flags.intersection(relevant)
        let cmdIsDown = f.contains(.maskCommand)
        let now = Date()
        if cmdIsDown {
            guard f.subtracting(.maskCommand).isEmpty else { lastCmdUp = nil; return }   // 只允许 ⌘ 单独按下
            cmdDownAt = now; dirtyDuringPress = false
        } else {
            guard let down = cmdDownAt else { return }
            cmdDownAt = nil
            // 纯按放（< 0.3s，期间无其他键）才算一击
            guard !dirtyDuringPress, now.timeIntervalSince(down) < 0.3 else { lastCmdUp = nil; return }
            if let last = lastCmdUp, now.timeIntervalSince(last) < 0.4 {
                lastCmdUp = nil
                DispatchQueue.main.async { CaptionState.shared.toggle() }
            } else {
                lastCmdUp = now
            }
        }
    }

    private static func keyName(_ code: UInt32) -> String {
        let map: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C", UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E",
            UInt32(kVK_ANSI_F): "F", UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I", UInt32(kVK_ANSI_J): "J",
            UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L", UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R", UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T",
            UInt32(kVK_ANSI_U): "U", UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X", UInt32(kVK_ANSI_Y): "Y",
            UInt32(kVK_ANSI_Z): "Z", UInt32(kVK_Space): "Space",
        ]
        return map[code] ?? "key\(code)"
    }
}
