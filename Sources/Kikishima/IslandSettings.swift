// 岛上就地调：字号 / 宽度 / 高度 / 字体 / 自动收回。全部是分档，点一下变一次；滑杆在播放时会闪。
import SwiftUI

struct CaptionSizeLevelPicker: View {
    let title: String
    @Binding var level: String
    let low: String
    let high: String

    var body: some View {
        Picker(title, selection: $level) {
            Text(tr(low)).tag(CaptionSizeLevel.small.rawValue)
            Text(tr("中")).tag(CaptionSizeLevel.medium.rawValue)
            Text(tr(high)).tag(CaptionSizeLevel.large.rawValue)
        }
        .pickerStyle(.segmented)
    }
}

struct IslandSettingsCard: View {
    @Bindable var state: CaptionState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("字幕设置")).font(.system(size: 13, weight: .semibold))

            row(tr("字号")) {
                CaptionSizeLevelPicker(title: tr("字号"), level: $state.captionFontLevel, low: "小", high: "大")
                    .labelsHidden()
            }
            row(tr("宽度")) {
                CaptionSizeLevelPicker(title: tr("宽度"), level: $state.captionWidthLevel, low: "窄", high: "宽")
                    .labelsHidden()
            }
            if state.supportsIslandSizing {
                row(tr("高度")) {
                    CaptionSizeLevelPicker(title: tr("高度"), level: $state.islandHeightLevel, low: "低", high: "高")
                        .labelsHidden()
                }
            }
            row(tr("字体")) {
                Picker("", selection: $state.captionFontFamily) {
                    Text(tr("系统")).tag("system")
                    Text(tr("圆体")).tag("rounded")
                    Text(tr("衬线")).tag("serif")
                    Text(tr("等宽")).tag("mono")
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            if state.supportsIslandSizing {
                Divider()

                row(tr("无人说话后收回")) {
                    Picker("", selection: $state.islandCollapseLevel) {
                        Text(tr("关")).tag(CaptionCollapseLevel.off.rawValue)
                        Text(tr("快")).tag(CaptionCollapseLevel.fast.rawValue)
                        Text(tr("中")).tag(CaptionCollapseLevel.medium.rawValue)
                        Text(tr("慢")).tag(CaptionCollapseLevel.slow.rawValue)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
            }
        }
        .padding(14)
        .frame(width: 300)
        .foregroundStyle(Color.primary)
        .tint(.accentColor)
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            content()
        }
    }
}
