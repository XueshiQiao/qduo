import Foundation
import Combine
import AIModelKit

/// The model lists fetched from each provider, kept in memory and shared by
/// every model picker (the AI Models page, the action editor), so opening the
/// editor does not ask the service again.
///
/// A list belongs to one provider at one address through one standard. Change
/// any of the three and it is a different list; save or clear the provider's
/// key and its lists are dropped, so the next picker fetches with the new key.
///
/// Main-thread only by convention, like the settings store it reads.
final class ModelListStore: ObservableObject {

    enum State: Equatable {
        case idle
        case loading
        case loaded([ModelInfo])
        /// The provider needs a key and has none, so nothing was asked.
        case needsKey
        case failed(String)
    }

    private static let log = FileLog("LLM.Models")

    @Published private(set) var states: [String: State] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Bumped each time a provider's key is saved or cleared. Part of the cache
    /// key, so a picker on screen sees a new key and fetches with it at once.
    @Published private var keyVersions: [String: Int] = [:]
    private let settings: LLMSettingsStore
    private var keyObserver: AnyCancellable?

    init(settings: LLMSettingsStore) {
        self.settings = settings
        keyObserver = settings.keyChanged.sink { [weak self] provider in
            self?.forget(provider)
        }
    }

    /// What identifies one list: provider, standard, the address's root (so
    /// `…/v1` and `…/v1/chat/completions` share a list) and which key it was
    /// fetched with.
    func cacheKey(for provider: String) -> String {
        let format = settings.format(for: provider)
        let url = settings.apiURL(for: provider)
        let base = Endpoint(format: format, url: url)?.base ?? url
        return "\(provider)|\(format.rawValue)|\(base)|key\(keyVersions[provider, default: 0])"
    }

    func state(for provider: String) -> State { states[cacheKey(for: provider)] ?? .idle }

    /// The thinking levels `model` takes, when the provider's loaded list says
    /// (Magpie does); nil when unknown.
    func reasoningLevels(for provider: String, model: String) -> [String]? {
        guard case .loaded(let models) = state(for: provider) else { return nil }
        return models.first { $0.id == model }?.reasoningLevels
    }

    /// Fetches the provider's list unless it is already loaded or loading.
    /// `force` fetches again whatever the state (the Refresh / Retry button).
    func load(_ provider: String, force: Bool = false) {
        let key = cacheKey(for: provider)
        switch states[key] ?? .idle {
        case .loaded, .loading, .failed, .needsKey:
            if !force { return }
        case .idle:
            break
        }
        let config = settings.listingConfig(provider: provider)
        if LLMConfig.needsKey(provider) && config.apiKey.isEmpty {
            states[key] = .needsKey
            return
        }
        states[key] = .loading
        tasks[key]?.cancel()
        tasks[key] = Task { [weak self] in
            let result: State
            do {
                let models = try await ModelClient(config.connection).listModels()
                result = .loaded(models)
                Self.log.info("\(provider): \(models.count) model(s) listed: \(models.prefix(30).map(\.id).joined(separator: ", "))")
            } catch {
                if Task.isCancelled { return }
                result = .failed(error.localizedDescription)
                Self.log.warn("\(provider): model list failed: \(error.localizedDescription)")
            }
            await MainActor.run {
                // A newer fetch (Refresh) replaced this one: its answer wins.
                guard let self, !Task.isCancelled else { return }
                self.states[key] = result
                self.tasks[key] = nil
            }
        }
    }

    /// Drops every list of `provider`, at any address, and moves its cache key
    /// on so the picker showing it fetches again with the new key.
    private func forget(_ provider: String) {
        for key in Set(states.keys).union(tasks.keys) where key.hasPrefix("\(provider)|") {
            tasks[key]?.cancel()
            tasks[key] = nil
            states[key] = nil
        }
        keyVersions[provider, default: 0] += 1
    }
}
