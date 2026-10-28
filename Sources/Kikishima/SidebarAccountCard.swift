import SwiftUI

struct SidebarBrandRow: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: BrandIcons.appImage)
                .resizable().frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text("Kikishima").font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 8)
    }
}

/// Local-first sidebar card: shows which translation engine is active and
/// whether it needs a key or a model download. No account, plan or quota.
struct SidebarEngineCard: View {
    let engine: TranslationEnginePolicy.Engine
    let hasOpenAIKey: Bool
    let keyHint: String
    var openSettings: () -> Void

    private var title: String {
        switch engine {
        case .apple: return tr("Apple 本机翻译")
        case .mlx: return tr("高质量本机模型")
        case .openAI: return tr("OpenAI Key")
        }
    }

    private var detail: String {
        switch engine {
        case .apple: return tr("不联网，不需要下载。")
        case .mlx: return tr("需要下载模型，质量更高但更慢。")
        case .openAI:
            return hasOpenAIKey ? tr("已保存 %@", keyHint) : tr("还没有填写 Key。")
        }
    }

    private var warning: Bool {
        engine == .openAI && !hasOpenAIKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("翻译引擎")).font(.system(size: 11)).foregroundStyle(KKColor.textSecondary)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(warning ? AnyShapeStyle(KKColor.warning) : AnyShapeStyle(KKColor.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
            Button(tr("设置…"), action: openSettings)
                .buttonStyle(KKLinkButtonStyle())
                .font(.system(size: 11))
        }
        .foregroundStyle(KKColor.textPrimary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KKColor.textPrimary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}
