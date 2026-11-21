import Foundation
import AIModelKit

/// One resolved model to call: provider, key, address, model and thinking level.
///
/// Everything that differs between services — the three wire standards
/// (OpenAI-compatible, Anthropic, Gemini), the address each one wants, how the
/// model list is read, each provider's thinking knob — lives in the shared
/// `AIModelKit` package, which Flowy and PastePaw can embed too. This type is
/// QDuo's handle on it: what the settings store resolves and what history records.
struct LLMConfig: Equatable {
    var provider: String      // a `Provider.id`: "deepseek", "openai", …, "custom"
    /// The standard the provider is called through: the provider's own, except
    /// for "custom", where the user picks it.
    var format: APIFormat
    var apiKey: String
    var apiURL: String
    var model: String
    /// "" (provider default) | "none" (off) | "minimal" | "low" | "medium" | "high" | "max"
    var reasoningEffort: String

    init(provider: String, format: APIFormat? = nil, apiKey: String, apiURL: String, model: String,
         reasoningEffort: String) {
        self.provider = provider
        self.format = format ?? (Provider.named(provider) ?? .custom).format
        self.apiKey = apiKey
        self.apiURL = apiURL
        self.model = model
        self.reasoningEffort = reasoningEffort
    }

    /// What `AIModelKit` calls the model with.
    var connection: ModelConnection {
        ModelConnection(providerID: provider, format: format, url: apiURL, apiKey: apiKey,
                        model: model, effort: reasoningEffort)
    }

    // MARK: - The provider table (from AIModelKit)

    static let custom = Provider.custom.id

    /// Every provider id, in picker order.
    static var providers: [String] { Provider.all.map(\.id) }

    static func preset(_ provider: String) -> Provider { Provider.named(provider) ?? .custom }

    /// Display name for the provider picker.
    static func displayName(_ provider: String) -> String {
        if provider == custom { return L("models.custom") }
        return Provider.named(provider)?.displayName ?? provider
    }

    /// Default base URL + model per provider.
    static func providerDefaults(_ provider: String) -> (apiURL: String, model: String) {
        let p = preset(provider)
        return (p.defaultURL, p.defaultModel)
    }

    /// Whether the provider answers without a key (Ollama, and a custom service,
    /// which is often a gateway on this machine).
    static func needsKey(_ provider: String) -> Bool { preset(provider).needsKey }

    /// The 思考 picker's choices, per provider (and, for custom, per format).
    static func thinkingOptions(for provider: String, format: APIFormat? = nil) -> [(tag: String, label: String)] {
        preset(provider).thinkingOptions(for: format)
    }

    /// Clamp a stored effort into the provider's valid set: invalid → "none"
    /// where there is an off-switch, else "" (model default).
    static func clampThinking(_ effort: String, for provider: String, format: APIFormat? = nil) -> String {
        preset(provider).clampThinking(effort, for: format)
    }

    /// The level a newly picked provider starts at (off where possible, else fastest).
    static func initialEffort(for provider: String, format: APIFormat? = nil) -> String {
        preset(provider).initialEffort(for: format)
    }
}
