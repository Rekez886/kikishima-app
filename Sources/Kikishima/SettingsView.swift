// 设置窗口（Cmd+, 或菜单「设置…」）
import SwiftUI
import Speech

// 旧的三标签设置窗已并入 MainWindow.swift（左侧栏式主窗口）；这里只留共享的小组件

// 常用目标语言（英文名进 prompt，显示本地名）
let targetLanguages: [(display: String, prompt: String)] = [
    ("简体中文", "Simplified Chinese"),
    ("繁體中文", "Traditional Chinese"),
    ("日本語", "Japanese"),
    ("English", "English"),
    ("한국어", "Korean"),
    ("Español", "Spanish"),
    ("Français", "French"),
    ("Deutsch", "German"),
    ("Português", "Portuguese"),
    ("עברית", "Hebrew"),
]

/// 目标语言英文名 → 短码（记录文件名用）
func targetCode(_ prompt: String) -> String {
    switch prompt {
    case "Simplified Chinese": return "zh"
    case "Traditional Chinese": return "zh-Hant"
    case "Japanese": return "ja"
    case "English": return "en"
    case "Korean": return "ko"
    case "Spanish": return "es"
    case "French": return "fr"
    case "German": return "de"
    case "Portuguese": return "pt"
    case "Hebrew": return "he"
    default: return prompt.lowercased().prefix(2).description
    }
}

struct GlossarySettings: View {
    @Bindable var state: CaptionState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("每行一条。纯词条 = 保留原文（人名、项目名）；「原词 → 译法」= 指定翻译。"))
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $state.glossary)
                .font(.system(size: 13, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
            // 服务器上限：80 条 / 4000 字，超出的部分不会发送
            let lines = state.glossary.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            let chars = state.glossary.count
            Text(tr("%@ / 80 条 · %@ / 4000 字", lines, chars))
                .font(.caption)
                .foregroundStyle(lines > 80 || chars > 4000 ? .orange : .secondary)
        }
        .padding(12)
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "captions.bubble.fill").font(.system(size: 40))
            Text("Kikishima").font(.title2.bold())
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "")) — \(tr("本地转写 + AI 翻译的会议实时字幕"))")
                .font(.caption).foregroundStyle(.secondary)
            Text(privacyStatement)
                .font(.caption2).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
