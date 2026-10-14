import SwiftUI

struct OnboardingWelcome: View {
    let privacy: String
    private static let icon = NSImage(size: NSSize(width: 96, height: 96), flipped: false) { rect in
        BrandIcons.drawAppIcon(in: rect)
        return true
    }
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: Self.icon).resizable().frame(width: 96, height: 96).accessibilityHidden(true)
            Text("Kikishima").font(.system(size: 30, weight: .bold))
            Text(tr("给你参加的每一场线上会议加上实时翻译字幕。\nZoom、Google Meet、Teams，任何出声的应用都可以。"))
                .font(.system(size: 14)).foregroundStyle(.secondary)
            Text(privacy).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(32)
    }
}

struct SignInTile: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
    }
}

struct LanguageChoiceTile: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 56)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(selected ? 0 : 0.1), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
