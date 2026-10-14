import SwiftUI

/// A bounded preview, independent of audio capture and window positioning.
struct HomeCaptionPreview: View {
    var source: String
    var translation: String
    var status: String
    var compact: Bool
    var display: String
    var desktop: Bool
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

    var body: some View {
        VStack(spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if display != "translation", !source.isEmpty {
                        Text(source)
                            .font(.system(size: display == "source" ? 16 : 12,
                                          weight: display == "source" ? .medium : .regular))
                            .foregroundStyle(display == "source" ? Color.white : Color(white: 0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if display != "source", !translation.isEmpty {
                        Text(translation)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if source.isEmpty && translation.isEmpty {
                        Text(status).font(.system(size: 13)).foregroundStyle(Color(white: 0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: compact ? 62 : 102)
            .padding(.horizontal, 20).padding(.vertical, 16)
            .background(Color(white: 0.045), in: RoundedRectangle(cornerRadius: desktop ? 12 : 24))
            .overlay {
                RoundedRectangle(cornerRadius: desktop ? 12 : 24)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }
            .frame(maxWidth: 400)

            Text(isExample ? tr("字幕预览 · 示例") : status)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(2).multilineTextAlignment(.center)
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
    }
    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Label(active ? tr("停止字幕") : tr("开始字幕"),
                      systemImage: active ? "stop.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(minWidth: 132).padding(.vertical, 5)
            }.buttonStyle(.borderedProminent).tint(active ? .red : .accentColor)
            if running {
                Button(action: pause) {
                    Image(systemName: paused ? "play.fill" : "pause.fill").padding(.vertical, 5)
                }
                .accessibilityLabel(paused ? tr("继续字幕") : tr("暂停字幕"))
                .help(paused ? tr("继续字幕") : tr("暂停字幕"))
                .disabled(transition)
            }
        }.fixedSize()
    }
    private var options: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle(tr("紧凑字幕"), isOn: $compact).toggleStyle(.switch).controlSize(.small)
                .help(tr("紧凑字幕（只显示最近两句）"))
            ViewThatFits(in: .horizontal) {
                displayPicker.pickerStyle(.segmented).labelsHidden().fixedSize()
                displayPicker.pickerStyle(.menu)
            }
        }
    }
    private var displayPicker: some View {
        Picker(tr("显示内容"), selection: $display) {
            Text(tr("原文 + 译文")).tag("both")
            Text(tr("仅译文")).tag("translation")
            Text(tr("仅原文")).tag("source")
        }
    }
}
