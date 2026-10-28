// 岛上就地调：字号 / 宽度 / 高度 / 字体 / 自动收回。全部是分档，点一下变一次；滑杆在播放时会闪。
import SwiftUI

struct CaptionSizeLevelPicker: View {
    let title: String
    @Binding var level: String
    let low: String
    let high: String

    var body: some View {
        KKSegmentedPicker(title: title, selection: $level, options: [(tr(low), CaptionSizeLevel.small.rawValue), (tr("中"), CaptionSizeLevel.medium.rawValue), (tr(high), CaptionSizeLevel.large.rawValue)])
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
                KKSegmentedPicker(title: tr("字体"), selection: $state.captionFontFamily, options: [(tr("系统"), "system"), (tr("圆体"), "rounded"), (tr("衬线"), "serif"), (tr("等宽"), "mono")]).labelsHidden()
            }

            if state.supportsIslandSizing {
                Divider()

                row(tr("无人说话后收回")) {
                    KKSegmentedPicker(title: tr("无人说话后收回"), selection: $state.islandCollapseLevel, options: [(tr("关"), CaptionCollapseLevel.off.rawValue), (tr("快"), CaptionCollapseLevel.fast.rawValue), (tr("中"), CaptionCollapseLevel.medium.rawValue), (tr("慢"), CaptionCollapseLevel.slow.rawValue)]).labelsHidden()
                }
            }
        }
        .padding(14)
        .frame(width: 300)
        .foregroundStyle(KKColor.textPrimary)
        .kkNeutralControls()
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(KKColor.textSecondary)
            content()
        }
    }
}
