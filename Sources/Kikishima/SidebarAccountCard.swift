import SwiftUI

/// Presentation data only; the live window supplies account state and existing actions.
struct SidebarAccountSummary {
    enum Tier { case signedOut, free, pro }
    var tier: Tier
    var email = ""
    var remainingMinutes: Int?
    var remainingDescription = ""
    var paidTitle = "Pro"
    var usageDescription: String?
}

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

struct SidebarAccountCard: View {
    let summary: SidebarAccountSummary
    var login: () -> Void
    var upgrade: () -> Void
    var redeemInvite: () -> Void
    var signOut: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var isPaid: Bool { summary.tier == .pro }
    private var brand: Color { Color(red: 1, green: 59.0 / 255, blue: 31.0 / 255) }
    private var background: Color {
        if isPaid { return Color(red: 15.0 / 255, green: 15.0 / 255, blue: 15.0 / 255) }
        if summary.tier == .free { return Color(nsColor: .controlBackgroundColor) }
        return Color.primary.opacity(0.05)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch summary.tier {
            case .signedOut:
                Text(tr("未登录")).font(.system(size: 15, weight: .semibold))
                Text(tr("登录后每周 60 分钟免费翻译字幕。"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(tr("登录"), action: login)
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(.blue)
            case .free:
                if let minutes = summary.remainingMinutes {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(minutes < 1 ? "<1" : "≈\(minutes)")
                            .font(.system(size: 22, weight: .bold)).monospacedDigit()
                        Text(tr("分钟")).font(.system(size: 12))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(summary.remainingDescription)
                } else {
                    Text(tr("免费版")).font(.system(size: 15, weight: .semibold))
                }
                Text(tr("每周 60 分钟。升级 Pro 不限时长。"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: upgrade) {
                    Text(tr("升级 Pro")).font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        // Dark ink meets contrast on the approved bright vermilion.
                        .foregroundStyle(Color(red: 0.1, green: 0.1, blue: 0.1))
                        .background(brand, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                Text(tr("Pro：$9.99/月 或 $79/年 · 7 天免费试用 · 随时取消"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: redeemInvite) {
                    Text(tr("有邀请码？在这里兑换"))
                        .font(.system(size: 11)).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }.buttonStyle(.link).foregroundStyle(Color.accentColor)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        email
                        Spacer(minLength: 0)
                        logout
                    }
                    VStack(alignment: .leading, spacing: 6) { email; logout }
                }
            case .pro:
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(brand).frame(width: 5, height: 5).accessibilityHidden(true)
                    Text(summary.paidTitle).font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                email
                if let usage = summary.usageDescription {
                    Text(usage).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(action: signOut) {
                    Text(tr("退出登录")).font(.system(size: 11))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain)
            }
        }
        .foregroundStyle(isPaid ? Color.white : Color.primary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if summary.tier == .free {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.08), lineWidth: 1)
            }
        }
    }

    private var email: some View {
        Text(summary.email).font(.system(size: 11))
            .foregroundStyle(isPaid ? Color.white.opacity(0.68) : Color.secondary)
            .lineLimit(1).truncationMode(.middle).help(summary.email)
    }
    private var logout: some View {
        Button(tr("退出登录"), action: signOut).controlSize(.mini).fixedSize()
    }
}
