import SwiftUI
import AIModelKit

/// The model field everywhere a model is chosen. It asks the provider for its
/// model list and offers it as a menu, so nobody has to know how a model's name
/// is spelled. Typing the name stays possible: from the menu's last item, and on
/// its own whenever the list cannot be had (no key yet, the service is down, it
/// has no list endpoint, it listed nothing).
///
///     list loaded  → menu of the provider's models (+ "Type a name…")
///     loading      → the text field, with a spinner
///     no key       → the text field, and "save a key to choose from the list"
///     failed       → the text field, the service's own error, and Retry
struct ModelPicker<Label: View>: View {

    let provider: String
    @Binding var selection: String
    @ObservedObject var store: ModelListStore
    var width: CGFloat = 260
    @ViewBuilder var label: () -> Label

    /// The user chose "Type a name…": show the text field even with a list.
    @State private var typing = false

    /// The menu item that switches to typing. Not a model id any service uses.
    private static var typeTag: String { "\u{1}type-a-name" }

    var body: some View {
        let state = store.state(for: provider)
        LabeledContent {
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 6) {
                    control(state)
                    trailingButton(state)
                }
                caption(state)
            }
        } label: { label() }
        // Fetch when the picker appears and whenever the provider, its standard
        // or its address changes. The pause lets typing in the address settle
        // before anything is asked: a newer change cancels the wait.
        .task(id: store.cacheKey(for: provider)) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            store.load(provider)
        }
        // A different list (provider, standard, address or key): offer it.
        .onChange(of: store.cacheKey(for: provider)) { _ in typing = false }
        .onAppear { pickFirstIfNone(state) }
        .onChange(of: state) { pickFirstIfNone($0) }
        // Switching to Magpie with its list already fetched: the state may not change.
        .onChange(of: provider) { _ in pickFirstIfNone(store.state(for: provider)) }
    }

    /// Magpie has no default model: while none is set, the first one its list
    /// offers becomes the model (see `LLMConfig.picksFirstListedModel`).
    private func pickFirstIfNone(_ state: ModelListStore.State) {
        guard LLMConfig.picksFirstListedModel(provider), !typing,
              selection.trimmingCharacters(in: .whitespaces).isEmpty,
              case .loaded(let models) = state, let first = models.first else { return }
        selection = first.id
    }

    // MARK: - Pieces

    @ViewBuilder
    private func control(_ state: ModelListStore.State) -> some View {
        if case .loaded(let models) = state, !models.isEmpty, !typing {
            Picker("", selection: Binding(
                get: { selection },
                set: { value in
                    if value == Self.typeTag { typing = true } else { selection = value }
                })) {
                if selection.isEmpty {
                    Text(L("models.list.choose")).tag("")
                } else if !models.contains(where: { $0.id == selection }) {
                    Text(String(format: L("models.list.notListed"), selection)).tag(selection)
                }
                ForEach(models) { model in Text(model.displayName).tag(model.id) }
                Divider()
                Text(L("models.list.manual")).tag(Self.typeTag)
            }
            .labelsHidden()
            .frame(maxWidth: width, alignment: .trailing)
        } else {
            TextField(L("models.model"), text: $selection)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: width, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func trailingButton(_ state: ModelListStore.State) -> some View {
        switch state {
        case .loading:
            ProgressView().controlSize(.small).frame(width: 16)
        case .loaded(let models) where typing && !models.isEmpty:
            Button { typing = false } label: { Image(systemName: "list.bullet") }
                .buttonStyle(.borderless)
                .help(L("models.list.backToList"))
        case .needsKey:
            EmptyView()
        default:
            Button { store.load(provider, force: true) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help(L("models.list.refresh"))
        }
    }

    @ViewBuilder
    private func caption(_ state: ModelListStore.State) -> some View {
        switch state {
        case .failed(let message):
            note(String(format: L("models.list.failed"), message), color: .orange)
        case .needsKey:
            note(L("models.list.needsKey"), color: .secondary)
        case .loaded(let models) where models.isEmpty:
            note(L("models.list.empty"), color: .secondary)
        default:
            EmptyView()
        }
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .multilineTextAlignment(.trailing)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 320, alignment: .trailing)
            .textSelection(.enabled)
    }
}
