import SwiftUI

// The ways into the AI Setup page from the Actions page, the same two as on
// HyperCapslock's mappings page:
//
//     a toolbar button "✨ AI Setup"            always there
//     a one-line tip at the top of the page    until the user closes it or follows it

/// Whether the tip on the Actions page was closed. In UserDefaults, not the
/// config file: it is bookkeeping about this install, not a setting anyone
/// would edit or carry to another Mac.
@MainActor
final class AISetupTipStore: ObservableObject {
    static let dismissedKey = "actions.aiSetupTipDismissed"
    static let shared = AISetupTipStore()

    @Published private(set) var isDismissed: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isDismissed = defaults.bool(forKey: Self.dismissedKey)
    }

    func dismiss() {
        guard !isDismissed else { return }
        isDismissed = true
        defaults.set(true, forKey: Self.dismissedKey)
    }
}

/// The toolbar button on the Actions page that opens the AI Setup page.
struct AISetupToolbarButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.teal)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(L("actions.aiSetup.toolbar"))
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 3)
        }
        .help(L("page.aiSetup"))
        .accessibilityIdentifier("actions.toolbar.aiSetup")
    }
}

/// One line at the top of the Actions page: "Rather not add them one by one?
/// … Try it →", and a close button. It sits inside a grouped Form section,
/// which is its card, so it draws no box of its own.
struct AISetupTipBanner: View {
    let onOpen: () -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var ctaHovered = false
    @State private var dismissHovered = false

    var body: some View {
        let dark = colorScheme == .dark
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(dark ? Color(red: 0.18, green: 0.83, blue: 0.75)
                                          : Color(red: 0.05, green: 0.58, blue: 0.53))
                (Text(L("actions.aiSetup.lead"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.primary)
                 + Text(" ").font(.system(size: 12.5))
                 + Text(L("actions.aiSetup.body"))
                    .font(.system(size: 12.5))
                    .foregroundColor(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("actions.aiSetupTip")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .center, spacing: 8) {
                Button(action: onOpen) {
                    Text(L("actions.aiSetup.cta"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .underline(ctaHovered)
                        .foregroundStyle(dark ? Color(red: 0.22, green: 0.74, blue: 0.97) : Color.accentColor)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { ctaHovered = hovering } }
                .accessibilityIdentifier("actions.aiSetupTip.open")

                Rectangle()
                    .fill(Color.primary.opacity(dark ? 0.12 : 0.09))
                    .frame(width: 1, height: 12)
                    .accessibilityHidden(true)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(dismissHovered ? Color.primary : Color.secondary)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(dismissHovered ? Color.primary.opacity(dark ? 0.12 : 0.07) : Color.clear))
                        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { dismissHovered = hovering } }
                .help(L("actions.aiSetup.dismiss"))
                .accessibilityLabel(L("actions.aiSetup.dismiss"))
                .accessibilityIdentifier("actions.aiSetupTip.dismiss")
            }
            .fixedSize()
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity)
    }
}
