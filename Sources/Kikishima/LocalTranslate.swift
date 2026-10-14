// 本机翻译（Apple Translation）：只用于「网页视频听译」，优先降低翻译延迟
// 会议字幕仍然只走 GPT。Apple 的 TranslationSession 只能在 SwiftUI 的 .translationTask 里拿到，
// 所以挂一个屏幕外的 1×1 隐形窗托住那个视图；请求走 AsyncStream，结果按 id 回填。
import SwiftUI
import AppKit
import Translation

@MainActor
final class LocalTranslator {
    static let shared = LocalTranslator()

    private var window: NSWindow?
    private var continuation: AsyncStream<Job>.Continuation?
    private var pending: [UUID: CheckedContinuation<String?, Never>] = [:]
    private var configured: (src: String, dst: String)?
    /// 语言包没装 / 不支持这对语言时置位：之后直接回落 GPT，不再空等
    private(set) var unavailable = false

    struct Job: Sendable { let id: UUID; let text: String }

    /// 准备本机翻译。src/dst 用语言码（en、ja、zh-Hans…）。同一对语言重复调用不重建
    func prepare(source: String, target: String) {
        let s = Self.langCode(source), d = Self.langCode(target)
        guard !s.isEmpty, !d.isEmpty, s != d else { unavailable = true; return }
        if let c = configured, c.src == s, c.dst == d, window != nil { return }
        teardown()
        unavailable = false
        configured = (s, d)
        let cfg = TranslationSession.Configuration(source: Locale.Language(identifier: s), target: Locale.Language(identifier: d))
        let stream = AsyncStream<Job> { cont in self.continuation = cont }
        let view = LocalTranslateView(config: cfg, jobs: stream,
                                      onResult: { [weak self] id, text in self?.deliver(id, text) },
                                      onFailure: { [weak self] in self?.unavailable = true; self?.flushPending() })
        let w = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: view)
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        w.collectionBehavior = [.stationary, .ignoresCycle]
        w.orderFrontRegardless()   // 必须「可见」SwiftUI 的 task 才跑；放在屏幕外且全透明
        window = w
    }

    func teardown() {
        flushPending()
        continuation?.finish(); continuation = nil
        window?.orderOut(nil); window = nil
        configured = nil
    }

    /// 翻一句；本机翻译不可用或超时返回 nil，调用方回落 GPT
    func translate(_ text: String, timeout: TimeInterval = 3.0) async -> String? {
        guard !unavailable, let continuation else { return nil }
        let id = UUID()
        let result: String? = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            pending[id] = c
            continuation.yield(Job(id: id, text: text))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await MainActor.run { self?.deliver(id, nil) }   // 超时：当没翻出来
            }
        }
        return result
    }

    private func deliver(_ id: UUID, _ text: String?) {
        guard let c = pending.removeValue(forKey: id) else { return }
        c.resume(returning: text)
    }
    private func flushPending() {
        for (_, c) in pending { c.resume(returning: nil) }
        pending.removeAll()
    }

    /// 「Simplified Chinese」这类 prompt 名，或 zh_CN 这类 locale，统一成 Apple 要的语言码
    static func langCode(_ s: String) -> String {
        switch s {
        case "Simplified Chinese": return "zh-Hans"
        case "Traditional Chinese": return "zh-Hant"
        case "Japanese": return "ja"
        case "English": return "en"
        case "Korean": return "ko"
        case "Spanish": return "es"
        case "French": return "fr"
        case "German": return "de"
        case "Portuguese": return "pt"
        case "Italian": return "it"
        case "Hebrew": return "he"
        default: break
        }
        let base = s.split(whereSeparator: { $0 == "_" || $0 == "-" }).first.map(String.init)?.lowercased() ?? ""
        if base == "zh" { return s.lowercased().contains("tw") || s.lowercased().contains("hant") ? "zh-Hant" : "zh-Hans" }
        return base
    }
}

/// 只为拿到 TranslationSession 而存在的视图
private struct LocalTranslateView: View {
    let config: TranslationSession.Configuration
    let jobs: AsyncStream<LocalTranslator.Job>
    let onResult: (UUID, String?) -> Void
    let onFailure: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(config) { session in
                do {
                    try await session.prepareTranslation()   // 语言包没装会弹一次系统下载框
                } catch {
                    onFailure(); return
                }
                for await job in jobs {
                    if let r = try? await session.translate(job.text) { onResult(job.id, r.targetText) }
                    else { onResult(job.id, nil) }
                }
            }
    }
}
