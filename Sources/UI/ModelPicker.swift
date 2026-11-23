import SwiftUI
import AppKit
import AIModelKit

/// The model field everywhere a model is chosen. It asks the provider for its
/// model list and offers it as a menu, so nobody has to know how a model's name
/// is spelled. Typing the name stays possible: from the menu's last item, and on
/// its own whenever the list cannot be had (no key yet, the service is down, it
/// has no list endpoint, it listed nothing).
///
/// Each model in the menu shows two lines: its name, and under it in grey the id
/// that goes in the request. Through a gateway such as Magpie the same model can
/// come from several services under one name ("DeepSeek-V4-Pro"); the id
/// ("deepseek/deepseek-v4-pro") says which service, and is unique. SwiftUI's
/// Picker shows one line per item, so the menu is an AppKit one (`ModelMenu`).
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

    /// The view the menu opens over, and what its items call back.
    @State private var menu = ModelMenu()

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
            Button {
                menu.show(models: models, selection: selection,
                          pick: { selection = $0 }, typeName: { typing = true })
            } label: { chosenLabel(models) }
            .buttonStyle(.plain)
            .background(MenuAnchor(menu: menu))
            .frame(maxWidth: width, alignment: .trailing)
        } else {
            TextField(L("models.model"), text: $selection)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: width, alignment: .trailing)
        }
    }

    /// What the closed control shows: the chosen model's name and, under it in
    /// grey, its id when that differs from the name.
    private func chosenLabel(_ models: [ModelInfo]) -> some View {
        let chosen = models.first { $0.id == selection }
        let title: String
        if selection.isEmpty {
            title = L("models.list.choose")
        } else if let chosen {
            title = chosen.displayName
        } else {
            title = String(format: L("models.list.notListed"), selection)
        }
        return HStack(spacing: 6) {
            VStack(alignment: .trailing, spacing: 1) {
                // The form draws a row's value in grey; the chosen model reads
                // like the other pickers' values.
                Text(title).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                if let chosen, chosen.id != chosen.displayName {
                    Text(chosen.id)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
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

/// The model menu: a native AppKit menu, each model as two lines (name, then the
/// id in grey), opened over the model button like a pop-up button's menu.
final class ModelMenu: NSObject {
    /// The view under the model button, set by `MenuAnchor`.
    weak var anchor: NSView?
    private var pick: (String) -> Void = { _ in }
    private var typeName: () -> Void = {}

    func show(models: [ModelInfo], selection: String,
              pick: @escaping (String) -> Void, typeName: @escaping () -> Void) {
        guard let anchor else { return }
        self.pick = pick
        self.typeName = typeName

        let menu = NSMenu()
        menu.autoenablesItems = false
        var chosen: NSMenuItem?
        // A model typed by hand that the list does not have: shown, checked, on top.
        if !selection.isEmpty, !models.contains(where: { $0.id == selection }) {
            let item = modelItem(title: String(format: L("models.list.notListed"), selection),
                                 subtitle: nil, id: selection)
            item.state = .on
            chosen = item
            menu.addItem(item)
            menu.addItem(.separator())
        }
        for model in models {
            let item = modelItem(title: model.displayName,
                                 subtitle: model.id == model.displayName ? nil : model.id, id: model.id)
            if model.id == selection {
                item.state = .on
                chosen = item
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let manual = NSMenuItem(title: L("models.list.manual"), action: #selector(typeAName), keyEquivalent: "")
        manual.target = self
        menu.addItem(manual)

        menu.minimumWidth = anchor.bounds.width
        // Like a pop-up button: the chosen model opens over the button.
        let top = NSPoint(x: 0, y: anchor.isFlipped ? 0 : anchor.bounds.height)
        menu.popUp(positioning: chosen, at: top, in: anchor)
    }

    /// One model: the name, and the id under it in grey. macOS 14.4 and later
    /// draw a menu item's subtitle that way; before that, a two-line attributed
    /// title does the same.
    private func modelItem(title: String, subtitle: String?, id: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = id
        guard let subtitle else { return item }
        if #available(macOS 14.4, *) {
            item.subtitle = subtitle
        } else {
            let text = NSMutableAttributedString(string: title, attributes: [
                .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.labelColor])
            text.append(NSAttributedString(string: "\n" + subtitle, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = text
        }
        return item
    }

    @objc private func choose(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { pick(id) }
    }

    @objc private func typeAName() { typeName() }
}

/// An empty view behind the model button that hands `ModelMenu` an AppKit view
/// to open the menu over.
private struct MenuAnchor: NSViewRepresentable {
    let menu: ModelMenu
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        menu.anchor = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { menu.anchor = view }
}
