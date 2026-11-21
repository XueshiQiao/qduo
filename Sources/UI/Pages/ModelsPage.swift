import SwiftUI
import AppKit
import AIModelKit

/// The **AI Models** settings page: the app-wide default model + an API key per
/// provider, shared by every tool through `LLMService`. Mirrors the visual language
/// of GeneralPage / AboutPage (grouped Form + AppChrome icon labels). The LLM
/// config used to live inside PopBar; it now lives here so any tool can use a model.
struct ModelsPage: View {

    @ObservedObject private var settings: LLMSettingsStore
    private let models: ModelListStore

    @State private var keyDraft = ""
    @State private var keyError: String?

    init(settings: LLMSettingsStore, models: ModelListStore) {
        _settings = ObservedObject(wrappedValue: settings)
        self.models = models
    }

    private var isCustom: Bool { settings.provider == LLMConfig.custom }

    var body: some View {
        Form {
            defaultModelSection
            keySection
        }
        .formStyle(.grouped)
        .navigationTitle(L("models.title"))
    }

    // MARK: - Default model

    private var defaultModelSection: some View {
        Section {
            Picker(selection: Binding(get: { settings.provider },
                                      set: { settings.setProvider($0); keyDraft = ""; keyError = nil })) {
                ForEach(LLMConfig.providers, id: \.self) { p in
                    Text(LLMConfig.displayName(p)).tag(p)
                }
            } label: { iconLabel("cpu", .indigo, L("models.provider")) }

            if isCustom {
                Picker(selection: Binding(get: { settings.customFormat },
                                          set: { settings.setCustomFormat($0) })) {
                    ForEach(APIFormat.allCases, id: \.self) { f in
                        Text(L("models.format.\(f.rawValue)")).tag(f)
                    }
                } label: { iconLabel("arrow.left.arrow.right", .indigo, L("models.format")) }
            }

            LabeledContent {
                TextField(L("models.baseURL"),
                          text: Binding(get: { settings.apiURL }, set: { settings.setAPIURL($0) }))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing).frame(maxWidth: 260)
                    .font(.system(size: 11, design: .monospaced))
            } label: { iconLabel("link", .indigo, L("models.baseURL")) }

            ModelPicker(provider: settings.provider,
                        selection: Binding(get: { settings.model }, set: { settings.setModel($0) }),
                        store: models) {
                iconLabel("shippingbox", .indigo, L("models.model"))
            }

            Picker(selection: Binding(get: { settings.reasoningEffort },
                                      set: { settings.setReasoningEffort($0) })) {
                ForEach(settings.thinkingOptions, id: \.tag) { opt in Text(opt.label).tag(opt.tag) }
            } label: { iconLabel("brain", .indigo, L("models.thinking")) }
        } header: {
            Text(L("models.default.header"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("models.default.footer"))
                if isCustom { Text(L("models.custom.footer")) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - API key (per provider)

    private var keySection: some View {
        Section {
            LabeledContent {
                if settings.hasKeyForCurrent {
                    HStack(spacing: 8) {
                        Text(L("models.key.saved"))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
                        Button(L("models.key.clear")) { settings.clearKey(for: settings.provider) }
                            .controlSize(.small)
                    }
                } else if isCustom {
                    Text(L("models.key.optional")).font(.system(size: 11)).foregroundStyle(.secondary)
                } else if !LLMConfig.needsKey(settings.provider) {
                    Text(L("models.key.notNeeded")).font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text(L("models.key.missing")).font(.system(size: 11)).foregroundStyle(.orange)
                }
            } label: {
                iconLabel("key", .indigo,
                          String(format: L("models.keyFor"), LLMConfig.displayName(settings.provider)))
            }

            HStack {
                SecureField(L("models.key.placeholder"), text: $keyDraft)
                Button(L("models.key.save")) {
                    keyError = settings.saveKey(keyDraft, for: settings.provider)
                    if keyError == nil { keyDraft = "" }
                }
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let keyError {
                Text(keyError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text(L("models.key.header"))
        } footer: {
            Text(L("models.key.footer")).fixedSize(horizontal: false, vertical: true)
        }
    }
}
