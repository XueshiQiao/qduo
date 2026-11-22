import SwiftUI
import AIModelKit

/// The thinking picker everywhere a thinking level is chosen. It offers what the
/// provider accepts, or, when the provider's model list says which levels each
/// model takes (Magpie does), exactly the chosen model's levels. When the
/// chosen model does not take the stored level, the stored level moves to the
/// nearest one it does take: Off where there is an Off, else Default.
struct ThinkingPicker<Label: View>: View {

    let provider: String
    let format: APIFormat
    let model: String
    @Binding var selection: String
    @ObservedObject var store: ModelListStore
    @ViewBuilder var label: () -> Label

    var body: some View {
        let levels = store.reasoningLevels(for: provider, model: model)
        let options = LLMConfig.thinkingOptions(for: provider, format: format, levels: levels)
        Picker(selection: $selection) {
            ForEach(options, id: \.tag) { opt in Text(opt.label).tag(opt.tag) }
        } label: { label() }
        .onAppear { clamp(to: levels) }
        // The choices changed (another model, provider or standard, or the
        // list arrived): keep the stored level among them.
        .onChange(of: options.map(\.tag)) { _ in clamp(to: store.reasoningLevels(for: provider, model: model)) }
    }

    private func clamp(to levels: [String]?) {
        let clamped = LLMConfig.clampThinking(selection, for: provider, format: format, levels: levels)
        if clamped != selection { selection = clamped }
    }
}
