import SwiftUI
import Foundation
import Combine
import AIModelKit

/// The observable model behind the **AI Models** settings page and the app-wide
/// default LLM configuration. Owns the default provider / model / base URL /
/// thinking level (in the config file) and, via `LLMKeyStore`, one API key per
/// provider (in the Keychain). This is the app-level One Source of Truth for LLM
/// config — created once and shared by every tool through `LLMService`.
///
/// The custom provider (a service the provider table does not know — a gateway
/// such as OpenRouter, LM Studio, a company proxy) also keeps its own address and
/// wire standard, so switching to another provider and back does not lose them.
///
/// Main-thread only by convention (SwiftUI `@Published` + settings UI).
final class LLMSettingsStore: ObservableObject {

    private static let log = FileLog("LLM.Settings")
    private let keys = LLMKeyStore()

    /// Paths into the config file. The API KEY is deliberately not among them —
    /// it lives in the Keychain, so the config file stays safe to commit.
    private enum P {
        static let provider     = "models.provider"
        static let model        = "models.model"
        static let apiURL       = "models.apiURL"
        static let thinking     = "models.thinking"
        static let customURL    = "models.custom.apiURL"
        static let customModel  = "models.custom.model"
        static let customFormat = "models.custom.format"
    }

    private var config: ConfigStore { .shared }

    @Published private(set) var provider: String
    @Published private(set) var model: String
    @Published private(set) var apiURL: String
    @Published private(set) var reasoningEffort: String
    /// The custom provider's own address and standard.
    @Published private(set) var customURL: String
    @Published private(set) var customFormat: APIFormat
    /// The custom provider's model: it has no default to fall back on, so the
    /// one chosen is kept for when it is picked again.
    @Published private(set) var customModel: String
    /// Providers that currently have a key stored (drives the settings UI).
    @Published private(set) var keyedProviders: Set<String> = []
    /// Sends a provider's id when its key is saved or cleared, so a model list
    /// fetched with the old key is fetched again.
    let keyChanged = PassthroughSubject<String, Never>()

    init() {
        let config = ConfigStore.shared
        let provider = config.string(P.provider, default: "deepseek")
        let defaults = LLMConfig.providerDefaults(provider)
        let customFormat = APIFormat(rawValue: config.string(P.customFormat, default: "")) ?? .openAI
        let model = config.string(P.model, default: defaults.model)
        let apiURL = config.string(P.apiURL, default: defaults.apiURL)
        // A file that names custom as the provider but has no custom block
        // (written by hand): the top-level address and model are its own.
        let handWrittenCustom = provider == LLMConfig.custom && config.value(P.customURL) == nil
        self.provider = provider
        self.model = model
        self.apiURL = apiURL
        self.customURL = handWrittenCustom
            ? apiURL : config.string(P.customURL, default: LLMConfig.providerDefaults(LLMConfig.custom).apiURL)
        self.customFormat = customFormat
        self.customModel = handWrittenCustom ? model : config.string(P.customModel, default: "")
        // Clamped because the file is hand-editable: a thinking level a provider
        // does not support would otherwise be sent straight to its API.
        self.reasoningEffort = LLMConfig.clampThinking(config.string(P.thinking, default: "none"), for: provider,
                                                       format: provider == LLMConfig.custom ? customFormat : nil)
        refreshKeyedProviders()
    }

    // MARK: - Key state

    func hasKey(for provider: String) -> Bool { keyedProviders.contains(provider) }
    var hasKeyForCurrent: Bool { hasKey(for: provider) }

    /// Whether a resolved provider will reach a real model (has a key, or needs
    /// none: Ollama, and a custom service).
    func isConfigured(forProvider p: String) -> Bool {
        !LLMConfig.needsKey(p) || hasKey(for: p)
    }

    /// The standard a provider is called through: its own, or for custom the one
    /// the user picked.
    func format(for provider: String) -> APIFormat {
        provider == LLMConfig.custom ? customFormat : LLMConfig.preset(provider).format
    }

    var format: APIFormat { format(for: provider) }

    // MARK: - Edits (settings UI)

    func setProvider(_ p: String) {
        provider = p
        let defaults = LLMConfig.providerDefaults(p)
        model = p == LLMConfig.custom ? customModel : defaults.model
        apiURL = p == LLMConfig.custom ? customURL : defaults.apiURL
        reasoningEffort = LLMConfig.initialEffort(for: p, format: format(for: p))
        persist()
    }

    func setModel(_ m: String) {
        model = m
        if provider == LLMConfig.custom { customModel = m }
        persist()
    }

    func setAPIURL(_ u: String) {
        apiURL = u
        if provider == LLMConfig.custom { customURL = u }
        persist()
    }

    /// The custom provider's standard. Resets the thinking level, since what is
    /// valid differs per standard.
    func setCustomFormat(_ f: APIFormat) {
        customFormat = f
        if provider == LLMConfig.custom {
            reasoningEffort = LLMConfig.initialEffort(for: provider, format: f)
        }
        persist()
    }

    func setReasoningEffort(_ e: String) {
        reasoningEffort = LLMConfig.clampThinking(e, for: provider, format: format)
        persist()
    }

    @discardableResult
    func saveKey(_ key: String, for provider: String) -> String? {
        let error = keys.save(key, for: provider)
        if error == nil {
            refreshKeyedProviders()
            keyChanged.send(provider)
        }
        return error
    }

    func clearKey(for provider: String) {
        keys.clear(for: provider)
        refreshKeyedProviders()
        keyChanged.send(provider)
    }

    // MARK: - Read (resolve a config for a tool)

    /// The default config (default provider / model / URL / effort), or nil when
    /// the default provider needs a key and has none — the caller surfaces a
    /// "set a key" message instead of silently using another model.
    func defaultConfig() -> LLMConfig? {
        makeConfig(provider: provider, model: model, apiURL: apiURL, effort: reasoningEffort)
    }

    /// A config for an explicit provider/model/effort (e.g. a per-action override).
    /// The address is the one this provider is set up with: the edited Base URL
    /// when it is the default provider, the custom provider's own address, else
    /// the provider's default. nil when that provider needs a key and has none.
    func config(provider p: String, model m: String, effort e: String) -> LLMConfig? {
        makeConfig(provider: p, model: m, apiURL: apiURL(for: p), effort: e)
    }

    /// The address a provider is reached at, as set up on the AI Models page.
    func apiURL(for p: String) -> String {
        if p == provider { return apiURL }
        if p == LLMConfig.custom { return customURL }
        return LLMConfig.providerDefaults(p).apiURL
    }

    /// A config for listing a provider's models: the same as `config(provider:…)`
    /// but with no model, and the key that is stored (or none).
    func listingConfig(provider p: String) -> LLMConfig {
        LLMConfig(provider: p, format: format(for: p), apiKey: keys.key(for: p), apiURL: apiURL(for: p),
                  model: "", reasoningEffort: "")
    }

    private func makeConfig(provider: String, model: String, apiURL: String, effort: String) -> LLMConfig? {
        let key = keys.key(for: provider)
        guard !LLMConfig.needsKey(provider) || !key.isEmpty else { return nil }
        let format = format(for: provider)
        return LLMConfig(provider: provider, format: format, apiKey: key, apiURL: apiURL, model: model,
                         reasoningEffort: LLMConfig.clampThinking(effort, for: provider, format: format))
    }

    // MARK: - Internals

    private func refreshKeyedProviders() {
        keyedProviders = keys.keyedProviders()
    }

    private func persist() {
        config.set(P.provider, provider)
        config.set(P.model, model)
        config.set(P.apiURL, apiURL)
        config.set(P.thinking, reasoningEffort)
        // The custom provider's own settings are written once it has been used,
        // so a config file that never touched it does not grow two keys.
        if provider == LLMConfig.custom || config.value(P.customURL) != nil {
            config.set(P.customURL, customURL)
            config.set(P.customFormat, customFormat.rawValue)
            config.set(P.customModel, customModel)
        }
    }
}
