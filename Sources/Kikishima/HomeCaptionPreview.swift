import SwiftUI

/// A bounded preview, independent of audio capture and window positioning.
struct HomeCaptionPreview: View {
    var source: String
    var translation: String
    var rows: [CaptionRowText] = []
    var status: String
    var warning = false
    var compact: Bool
    var display: String
    var desktop: Bool
    var statusPresentedExternally = false
    var isExample: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func sampleTranslation(for language: String) -> String {
        switch language {
        case "Simplified Chinese": return "我们一起确认接下来的安排。"
        case "Traditional Chinese": return "我們一起確認接下來的安排。"
        case "Japanese": return "次の予定を一緒に確認しましょう。"
        case "Korean": return "다음 일정을 함께 확인해 봅시다."
        case "Spanish": return "Revisemos juntos los próximos pasos."
        case "French": return "Voyons ensemble les prochaines étapes."
        case "German": return "Gehen wir gemeinsam die nächsten Schritte durch."
        case "Portuguese": return "Vamos rever juntos os próximos passos."
        case "Hebrew": return "בואו נעבור יחד על הצעדים הבאים."
        default: return "Let's review the next steps together."
        }
    }

    private var previewRows: [CaptionRowText] {
        rows.isEmpty ? [CaptionHierarchy.row(source: source, translation: translation, waiting: false,
            current: true, showTranslation: display != "source", showSource: display != "translation")] : rows
    }

    var body: some View {
        VStack(spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: KKSpace.one) {
                    ForEach(Array(previewRows.enumerated()), id: \.offset) { _, text in
                        Text(text.primary)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(text.placeholder ? KKColor.textTertiary : KKColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let secondary = text.secondary {
                            Text(secondary)
                                .font(.system(size: 12))
                                .foregroundStyle(KKColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    if !source.isEmpty || !translation.isEmpty {
                        Rectangle().fill(KKColor.brand).frame(width: 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: compact ? 62 : 102)
            .padding(.horizontal, 20).padding(.vertical, 16)
            .background(desktop ? KKColor.captionWindowBackground : KKColor.notchBackground, in: RoundedRectangle(cornerRadius: desktop ? 12 : 24))
            .overlay {
                RoundedRectangle(cornerRadius: desktop ? 12 : 24)
                    .strokeBorder(KKColor.historyInk.opacity(0.08), lineWidth: 1)
            }
            .frame(maxWidth: 400)
            .environment(\.colorScheme, .dark)

            if isExample || !statusPresentedExternally {
                Text(isExample ? tr("字幕预览 · 示例") : status)
                    .font(.system(size: 11))
                    .foregroundStyle(warning && !isExample ? KKColor.warning : KKColor.textSecondary)
                    .accessibilityIdentifier("kk-preview-listening-status")
                    .lineLimit(2).multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: compact)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: desktop)
    }

}


struct HomeCaptionControls: View {
    var active: Bool
    var running: Bool
    var paused: Bool
    var transition: Bool
    @Binding var compact: Bool
    @Binding var display: String
    var toggle: () -> Void
    var pause: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                actions
                options.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 12) {
                actions
                options
            }
        }
        .kkNeutralControls()
    }
    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Label(active ? tr("停止字幕") : tr("开始字幕"),
                      systemImage: active ? "stop.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(minWidth: 132).padding(.vertical, 5)
            }.kkPrimaryButton(active: active)
            if running {
                Button(action: pause) {
                    Image(systemName: paused ? "play.fill" : "pause.fill").padding(.vertical, 5)
                }
                .buttonStyle(KKQuietButtonStyle())
                .accessibilityLabel(paused ? tr("继续字幕") : tr("暂停字幕"))
                .help(paused ? tr("继续字幕") : tr("暂停字幕"))
                .disabled(transition)
            }
        }.fixedSize()
    }
    private var options: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle(tr("紧凑字幕"), isOn: $compact).toggleStyle(KKSwitchToggleStyle()).controlSize(.small)
                .accessibilityLabel(tr("紧凑字幕"))
                .accessibilityIdentifier("kk-compact-captions")
                .help(tr("紧凑字幕（只显示最近两句）"))
            ViewThatFits(in: .horizontal) {
                KKSegmentedPicker(title: tr("显示内容"), selection: $display, options: [(tr("双语"), "both"), (captionDisplayText("仅译文"), "translation"), (captionDisplayText("仅原文"), "source")]).fixedSize()
                displayPicker.pickerStyle(.menu)
            }
        }
    }
    private var displayPicker: some View {
        Picker(tr("显示内容"), selection: $display) {
            Text(tr("双语")).tag("both")
            Text(captionDisplayText("仅译文")).tag("translation")
            Text(captionDisplayText("仅原文")).tag("source")
        }.buttonStyle(.automatic)
    }
}
