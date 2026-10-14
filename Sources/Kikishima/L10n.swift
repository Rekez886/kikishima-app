// 界面多语言：以简体中文源串为 key，运行时按 CaptionState.uiLanguage 查表（zh-Hant / ja / en / ko）
// 表文件：Resources/l10n/<code>.json（build.sh 拷进 Contents/Resources/l10n）。找不到的 key 原样显示中文，不会崩
import Foundation

@MainActor
enum L10n {
    private static var cache: [String: [String: String]] = [:]

    private static func table(_ code: String) -> [String: String] {
        if let t = cache[code] { return t }
        var t: [String: String] = [:]
        if let url = Bundle.main.url(forResource: code, withExtension: "json", subdirectory: "l10n"),
           let data = try? Data(contentsOf: url),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            t = dict
        }
        cache[code] = t
        return t
    }

    static func tr(_ key: String) -> String {
        let code = CaptionState.shared.uiLanguage   // @Observable：视图 body 里读到它，切语言即重绘
        if code.isEmpty || code == "zh-Hans" { return key }
        return L10nTables.table(code)[key] ?? key
    }
}

/// 非主线程（翻译层 / 静态属性）用：读 UserDefaults 里的语言码，不参与 SwiftUI 观察
nonisolated func trAny(_ key: String) -> String {
    let code = UserDefaults.standard.string(forKey: "uiLanguage") ?? ""
    if code.isEmpty || code == "zh-Hans" { return key }
    return L10nTables.table(code)[key] ?? key
}
nonisolated func trAny(_ key: String, _ args: Any...) -> String {
    var s = trAny(key)
    for a in args { if let r = s.range(of: "%@") { s.replaceSubrange(r, with: String(describing: a)) } }
    return s
}
/// 线程安全的表缓存（主线程 L10n 也用它）
enum L10nTables {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [String: String]] = [:]
    nonisolated static func table(_ code: String) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        if let t = cache[code] { return t }
        var t: [String: String] = [:]
        if let url = Bundle.main.url(forResource: code, withExtension: "json", subdirectory: "l10n"),
           let data = try? Data(contentsOf: url),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] { t = dict }
        cache[code] = t
        return t
    }
}

/// 视图里用：tr("开始字幕")；带参数：tr("本周剩余约 %@ 分钟", r)
@MainActor func tr(_ key: String) -> String { L10n.tr(key) }
@MainActor func tr(_ key: String, _ args: Any...) -> String {
    var s = L10n.tr(key)
    for a in args { if let r = s.range(of: "%@") { s.replaceSubrange(r, with: String(describing: a)) } }
    return s
}
