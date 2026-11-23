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
    @State private var testing = false
    @State private var testResult: ConnectionTestResult?
    /// What the shown result was for: a result for another provider, model or
    /// address is not shown.
    @State private var testedIdentity: String?
    @State private var testedModel = ""
    @State private var testTask: Task<Void, Never>?
    private let llm: LLMService

    init(llm: LLMService) {
        _settings = ObservedObject(wrappedValue: llm.settings)
        self.models = llm.models
        self.llm = llm
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
                                      set: { settings.setProvider($0); keyDraft = ""; keyError = nil; resetTest() })) {
                ForEach(LLMConfig.providers, id: \.self) { p in
                    ProviderLabel(provider: p).tag(p)
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

            ThinkingPicker(provider: settings.provider, format: settings.format, model: settings.model,
                           selection: Binding(get: { settings.reasoningEffort },
                                              set: { settings.setReasoningEffort($0) }),
                           store: models) {
                iconLabel("brain", .indigo, L("models.thinking"))
            }

            testRow
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

    // MARK: - Test

    private var testRow: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 8) {
                    if testing { ProgressView().controlSize(.small) }
                    Button(testing ? L("models.test.testing") : L("models.test")) { runTest() }
                        .disabled(testing || !settings.isConfigured(forProvider: settings.provider))
                }
                if let result = testResult, testedIdentity == testIdentity {
                    ForEach(Array(testLines(result).enumerated()), id: \.offset) { _, line in
                        Text(line.text)
                            .font(.system(size: 11))
                            .foregroundStyle(line.color)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 360, alignment: .trailing)
                            .textSelection(.enabled)
                    }
                }
            }
        } label: { iconLabel("checkmark.seal", .indigo, L("models.test.label")) }
        .help(L("models.test.footer"))
    }

    /// What a test result belongs to, without reading the key: change any of
    /// these and the old result is hidden.
    private var testIdentity: String {
        "\(settings.provider)|\(settings.format.rawValue)|\(settings.apiURL)|\(settings.model)|\(settings.reasoningEffort)"
    }

    private func runTest() {
        guard let config = llm.defaultConfig() else { return }
        let identity = testIdentity
        testing = true
        testResult = nil
        testTask?.cancel()
        testTask = Task {
            let result = await llm.testConnection(config)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                testResult = result
                testedIdentity = identity
                testedModel = config.model
                testing = false
            }
        }
    }

    /// Drops the shown result and stops a test still running: after a key or
    /// provider change, a result from before would be about something else.
    private func resetTest() {
        testTask?.cancel()
        testTask = nil
        testing = false
        testResult = nil
    }

    /// The result in a line or two: the verdict, then any warning.
    private func testLines(_ r: ConnectionTestResult) -> [(text: String, color: Color)] {
        guard r.succeeded else {
            return [(r.problem?.localizedText ?? "", .red)]
        }
        let model = testedModel
        var lines: [(String, Color)] = [(String(format: L("models.test.ok"), model, r.latency ?? 0), .green)]
        if r.modelListed == false {
            lines.append((String(format: L("models.test.notListed"), model), .secondary))
        }
        if let p = r.listProblem {
            lines.append((String(format: L("models.test.listFailed"), p.localizedText), .secondary))
        }
        return lines
    }

    // MARK: - API key (per provider)

    private var keySection: some View {
        Section {
            LabeledContent {
                if settings.hasKeyForCurrent {
                    HStack(spacing: 8) {
                        Text(L("models.key.saved"))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
                        Button(L("models.key.clear")) { settings.clearKey(for: settings.provider); resetTest() }
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
                    resetTest()
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
