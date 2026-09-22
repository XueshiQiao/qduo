import SwiftUI

/// The Actions page: the list of things the popup offers, and the one setting
/// that belongs to an action kind rather than to the popup as a whole (what a
/// web-preview action does when the selection is not a link).
struct ActionsPage: View {

    @ObservedObject private var actions: ActionStore
    @ObservedObject private var llm: LLMService

    @State private var editingAction: PopBarActionConfig?
    @State private var previewFallback = PopBarPreferences.previewFallbackToSearch
    @State private var previewEngine = PopBarPreferences.previewSearchEngine

    init(actions: ActionStore, llm: LLMService) {
        _actions = ObservedObject(wrappedValue: actions)
        _llm = ObservedObject(wrappedValue: llm)
    }

    var body: some View {
        Form {
            actionsSection
            // Only shown once such an action exists — a setting for a feature you
            // are not using is noise.
            if hasWebPreviewAction { webPreviewSection }
        }
        .formStyle(.grouped)
        .navigationTitle(L("page.actions"))
        .sheet(item: $editingAction) { action in
            ActionEditorView(action: action, llm: llm) { saved in
                // Look in BOTH levels. `actions.actions` is only the top level, so
                // saving an action that lives inside a group used to fall through to
                // `add` and append a SECOND copy of it at the root, with the same id
                // — after which deletes and drags resolved whichever came first.
                if actions.action(id: saved.id) != nil {
                    actions.update(saved)
                } else {
                    actions.add(saved)
                }
                editingAction = nil
            } onCancel: {
                editingAction = nil
            }
        }
    }

    private var hasWebPreviewAction: Bool {
        actions.actions.contains {
            $0.kind == .webPreview || $0.children.contains { $0.kind == .webPreview }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        PopBarActionListSection(
            actions: actions,
            onEdit: { editingAction = $0 },
            rowContent: { AnyView(actionRow($0)) },
            footerRow: { AnyView(actionsFooterRow) }
        )
    }

    /// The last row of the actions section: add an action, add a group, reset.
    private var actionsFooterRow: some View {
        HStack(spacing: 14) {
            Button {
                editingAction = PopBarActionConfig(title: "", iconSymbol: "sparkles", kind: .ai)
            } label: {
                Label(L("popbar.actions.add"), systemImage: "plus")
            }
            // A group is made here rather than by dropping one action on another:
            // it gets a name and an icon of its own up front, and the gesture that
            // would otherwise create one is already spoken for (dropping onto a
            // group row means "put it in THAT group").
            Button {
                editingAction = PopBarActionConfig(title: "", iconSymbol: "square.grid.2x2", kind: .group)
            } label: {
                Label(L("popbar.actions.addGroup"), systemImage: "rectangle.stack.badge.plus")
            }
            Spacer()
            Button(L("popbar.actions.reset")) { actions.resetToDefaults() }
                .foregroundStyle(.secondary)
        }
    }

    private func actionRow(_ action: PopBarActionConfig) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: action.iconSymbol, color: .indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title.isEmpty ? L("popbar.action.untitled") : action.title)
                if action.kind == .group {
                    Text(String(format: L("popbar.group.count"), action.children.count))
                        .font(.caption).foregroundStyle(.secondary)
                } else if action.isAI {
                    Text(modelLabel(action)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            actionTag(action)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func modelLabel(_ action: PopBarActionConfig) -> String {
        if let o = action.modelOverride {
            return "\(LLMConfig.displayName(o.provider)) · \(o.model)"
        }
        return L("popbar.action.defaultModel")
    }

    @ViewBuilder
    private func actionTag(_ action: PopBarActionConfig) -> some View {
        if action.kind == .group {
            EmptyView()   // a group runs nothing, so both "REAL" and "AI" would be a lie
        } else if action.isLocal {
            tag(L("popbar.tag.real"), .green)
        } else if llm.isConfigured(forProvider: action.modelOverride?.provider ?? llm.settings.provider) {
            tag(L("popbar.tag.ai"), .indigo)
        } else {
            tag(L("popbar.tag.needsKey"), .orange)
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
    }

    // MARK: - Web preview (link fallback)

    private var webPreviewSection: some View {
        Section {
            Toggle(isOn: $previewFallback) {
                iconLabel("magnifyingglass", .indigo, L("popbar.webpreview.fallback"))
            }
            .onChange(of: previewFallback) { PopBarPreferences.previewFallbackToSearch = $0 }
            if previewFallback {
                Picker(selection: $previewEngine) {
                    ForEach(PreviewSearchEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                } label: {
                    iconLabel("globe", .indigo, L("popbar.webpreview.engine"))
                }
                .onChange(of: previewEngine) { PopBarPreferences.previewSearchEngine = $0 }
            }
        } header: {
            Text(L("popbar.webpreview.section"))
        } footer: {
            Text(L("popbar.webpreview.fallback.footer"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
