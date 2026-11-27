import SwiftUI
import AppKit

/// The AI Setup page ("AI 辅助配置"): hand the app's configuration to an AI
/// agent on this Mac (Claude Code, Codex, Cursor…).
///
/// The same layout as HyperCapslock's AI Setup page, so both apps keep one
/// design:
///
///     hero card
///         icon · title · AI-NATIVE badge · one line on what it does
///         1  copy the setup prompt                         [Copy Setup Prompt]
///         2  paste it into an AI agent and say what you want   (agent names)
///         3  it is checked, backed up and applied by a restart
///         ───────────────────────────────────────────────────────────
///         optional: install the skill for local agents   Install · Reveal in Finder
///     reference examples, two per row; clicking one copies its whole prompt
///
/// The prompt carries the path to the guide inside the app (the bundled Agent
/// Skill), the command line and the config file, so nothing has to be
/// installed first; it ends with "My request:" for the user to type after.
/// API keys never leave the Keychain — the prompt tells the agent so.
struct AISetupPage: View {

    @Environment(\.colorScheme) private var colorScheme

    @State private var copiedID: String?
    @State private var copyReset: DispatchWorkItem?
    @State private var installFeedback: InstallFeedback?

    private struct InstallFeedback: Equatable {
        let text: String
        let isError: Bool
    }

    /// Shown as "use any agent you like"; the same list as HyperCapslock's.
    private static let agentNames = ["Claude Code", "Codex", "Cursor", "Antigravity", "WorkBuddy"]

    private var language: AgentPrompt.Language { .current(configLanguage: LocalizationOverride.activeCode) }

    private var paths: AgentPrompt.Paths {
        AgentPrompt.Paths(skillFile: BundledSkill.skillFile().path,
                          cli: Bundle.main.executableURL?.path ?? "",
                          config: ConfigStore.shared.fileURL.path)
    }

    private var examplePairs: [[AgentPrompt.Example]] {
        let all = AgentPrompt.examples
        return stride(from: 0, to: all.count, by: 2).map { Array(all[$0..<min($0 + 2, all.count)]) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                heroCard
                examplesSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(L("page.aiSetup"))
        .toolbar {
            ToolbarItem {
                Button(action: revealSkillInFinder) { Image(systemName: "folder") }
                    .help(L("aisetup.reveal"))
                    .accessibilityIdentifier("aisetup.toolbarReveal")
            }
        }
    }

    // MARK: - Hero card

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroHeader
            Spacer(minLength: 18)
            steps
            Spacer(minLength: 18)
            heroFooter
        }
        .padding(.horizontal, 26)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, minHeight: 448, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(dark ? 0.09 : 0.075), lineWidth: 0.75))
        .shadow(color: .black.opacity(dark ? 0.20 : 0.035), radius: 10, x: 0, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("aisetup.hero")
    }

    private var dark: Bool { colorScheme == .dark }

    private var heroHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            heroIcon
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    Text(L("aisetup.hero.title"))
                        .font(.system(size: 17.5, weight: .semibold))
                    Text("AI-NATIVE")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.5)
                        .foregroundStyle(Color.teal.opacity(0.90))
                        .padding(.horizontal, 7.5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.teal.opacity(dark ? 0.14 : 0.09)))
                        .overlay(Capsule().strokeBorder(Color.teal.opacity(dark ? 0.30 : 0.22), lineWidth: 0.6))
                }
                Text(String(format: L("aisetup.hero.body"), Brand.name))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var heroIcon: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(LinearGradient(colors: [.teal, .accentColor], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 40, height: 40)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LinearGradient(colors: [Color.teal.opacity(dark ? 0.18 : 0.11), Color.accentColor.opacity(dark ? 0.18 : 0.11)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.teal.opacity(dark ? 0.28 : 0.18), lineWidth: 0.75))
    }

    // MARK: - Steps

    private var steps: some View {
        VStack(spacing: 11) {
            stepCard {
                HStack(alignment: .center, spacing: 16) {
                    stepText(1, L("aisetup.step1.title"), L("aisetup.step1.desc"))
                    Spacer(minLength: 12)
                    Button { copyPrompt(request: nil, id: "base") } label: {
                        HStack(spacing: 6) {
                            Image(systemName: copiedID == "base" ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 12.5, weight: .semibold))
                            Text(copiedID == "base" ? L("aisetup.copied") : L("aisetup.copyPrompt"))
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(copiedID == "base" ? .green : .accentColor)
                    .controlSize(.large)
                    .accessibilityIdentifier("aisetup.copyPrompt")
                }
            }

            stepCard {
                HStack(alignment: .top, spacing: 12) {
                    stepBadge(2)
                    VStack(alignment: .leading, spacing: 3) {
                        stepTitle(L("aisetup.step2.title"))
                        stepDesc(L("aisetup.step2.desc"))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("aisetup.step2.agents"))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                            AgentFlowLayout(spacing: 6, lineSpacing: 6) {
                                ForEach(Self.agentNames, id: \.self) { agentPill($0) }
                            }
                        }
                        .padding(.top, 6)
                    }
                    Spacer(minLength: 0)
                }
            }

            stepCard {
                HStack(alignment: .top, spacing: 12) {
                    stepText(3, L("aisetup.step3.title"), String(format: L("aisetup.step3.desc"), Brand.name))
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func stepText(_ number: Int, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            stepBadge(number)
            VStack(alignment: .leading, spacing: 3) {
                stepTitle(title)
                stepDesc(desc)
            }
        }
    }

    private func stepTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13.5, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func stepDesc(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The same badge on all three steps, so step 1 does not look like the
    /// selected tab of a wizard.
    private func stepBadge(_ number: Int) -> some View {
        Text("\(number)")
            .font(.system(size: 12.5, weight: .bold, design: .rounded))
            .foregroundStyle(Color.accentColor)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.accentColor.opacity(dark ? 0.16 : 0.10)))
            .overlay(Circle().strokeBorder(Color.accentColor.opacity(dark ? 0.28 : 0.18), lineWidth: 0.75))
            .padding(.top, 1)
    }

    private func stepCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(dark ? 0.045 : 0.028)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(dark ? 0.08 : 0.055), lineWidth: 0.75))
    }

    private func agentPill(_ name: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(Color.secondary.opacity(0.45)).frame(width: 4.5, height: 4.5)
            Text(name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8.5)
        .padding(.vertical, 3.5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(dark ? 0.06 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Color.primary.opacity(dark ? 0.10 : 0.065), lineWidth: 0.5))
    }

    // MARK: - Footer: the optional skill install

    private var heroFooter: some View {
        VStack(alignment: .leading, spacing: 11) {
            Rectangle()
                .fill(Color.primary.opacity(dark ? 0.075 : 0.055))
                .frame(height: 0.5)
            HStack(alignment: .center, spacing: 10) {
                if let feedback = installFeedback {
                    Label(feedback.text, systemImage: feedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(feedback.isError ? .red : .green)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(feedback.text)
                        .accessibilityIdentifier("aisetup.installStatus")
                } else {
                    Text(L("aisetup.install.hint"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 10)
                HStack(spacing: 6) {
                    QuietLinkButton(title: L("aisetup.install"), systemImage: "square.and.arrow.down", action: install)
                        .accessibilityIdentifier("aisetup.install")
                    Text("·").font(.system(size: 12)).foregroundStyle(.quaternary)
                    QuietLinkButton(title: L("aisetup.reveal"), systemImage: "folder", action: revealSkillInFinder)
                        .accessibilityIdentifier("aisetup.reveal")
                }
            }
        }
    }

    // MARK: - Examples

    private var examplesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("aisetup.examples.title"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(L("aisetup.examples.subtitle"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 2)

            VStack(spacing: 10) {
                ForEach(Array(examplePairs.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(row) { example in
                            QuietExampleCard(id: example.id,
                                             title: L("aisetup.ex.\(example.id).title"),
                                             symbol: example.symbol,
                                             preview: example.text(language),
                                             copyLabel: L("aisetup.copy"),
                                             copiedLabel: L("aisetup.copied"),
                                             isCopied: copiedID == example.id,
                                             onCopy: { copyPrompt(request: example.text(language), id: example.id) })
                        }
                        if row.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Actions

    private func copyPrompt(request: String?, id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgentPrompt.build(language, paths: paths, request: request), forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) { copiedID = id }
        copyReset?.cancel()
        let reset = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.15)) { if copiedID == id { copiedID = nil } }
        }
        copyReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: reset)
        Analytics.trackAISetup(id == "base" ? "copy_main" : "copy_example")
    }

    private func install() {
        let feedback: InstallFeedback
        do {
            let result = try SkillInstaller.install()
            feedback = InstallFeedback(text: String(format: L("aisetup.install.done"), result.linkedAgents.count), isError: false)
            Analytics.trackAISetup("install_skill")
        } catch {
            feedback = InstallFeedback(text: String(format: L("aisetup.install.failed"), error.localizedDescription), isError: true)
        }
        withAnimation(.easeInOut(duration: 0.15)) { installFeedback = feedback }
    }

    private func revealSkillInFinder() {
        let file = BundledSkill.skillFile()
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            withAnimation { installFeedback = InstallFeedback(text: L("aisetup.skillMissing"), isError: true) }
        }
    }
}

// MARK: - Pieces

/// A small text button that turns the accent color on hover.
private struct QuietLinkButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 10.5, weight: .medium))
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(hovered ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hovered ? Color.accentColor.opacity(0.08) : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { hovered = hovering } }
    }
}

/// One reference example: title, the request in quotes, and Copy. Clicking
/// anywhere on the card copies too.
private struct QuietExampleCard: View {
    let id: String
    let title: String
    let symbol: String
    let preview: String
    let copyLabel: String
    let copiedLabel: String
    let isCopied: Bool
    let onCopy: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false

    private var border: Color {
        if isCopied { return Color.green.opacity(0.45) }
        if hovered { return Color.accentColor.opacity(0.30) }
        return Color.primary.opacity(colorScheme == .dark ? 0.075 : 0.06)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Button(action: onCopy) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc").font(.system(size: 10, weight: .semibold))
                        Text(isCopied ? copiedLabel : copyLabel)
                            .font(.system(size: 11, weight: isCopied || hovered ? .semibold : .medium))
                    }
                    .foregroundStyle(isCopied ? Color.green : (hovered ? Color.accentColor : Color.secondary.opacity(0.65)))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isCopied ? Color.green.opacity(0.12) : (hovered ? Color.accentColor.opacity(0.10) : Color.clear)))
                    .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("aisetup.example.\(id).copy")
            }
            Text("“\(preview)”")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary.opacity(0.82))
                .lineSpacing(2)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.72 : 0.84)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(border, lineWidth: 0.75))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onTapGesture(perform: onCopy)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { hovered = hovering } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("aisetup.example.\(id)")
    }
}

/// Lays the agent names out in rows, wrapping when a row is full.
private struct AgentFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                usedWidth = max(usedWidth, x - spacing)
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        if x > 0 { usedWidth = max(usedWidth, x - spacing) }
        return CGSize(width: usedWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
