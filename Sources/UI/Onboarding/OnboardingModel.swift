import AppKit
import AIModelKit
import Combine
import SwiftUI

/// The first-run guide's view model. Owns the remembered progress and every
/// button's behaviour; the views only draw it.
///
/// Everything the guide changes takes effect on the spot — the permission, the
/// key, the actions added — so closing the window never loses anything and never
/// needs a "are you sure?".
///
/// Main-thread only (SwiftUI + timers + notifications on `.main`).
final class OnboardingModel: ObservableObject {

    private static let log = FileLog("Onboarding")

    let appState: AppState
    var store: PopBarStore { appState.store }
    var settings: LLMSettingsStore { appState.llm.settings }

    private let progressStore: OnboardingProgressStore

    @Published private(set) var progress: OnboardingProgress {
        didSet { if progress != oldValue { progressStore.save(progress) } }
    }

    /// Asks the window to close (the "Later" button, and Done).
    var requestClose: () -> Void = {}

    // MARK: AI page (only lives while the window does)

    enum TestState: Equatable {
        case idle
        case testing
        case ok(model: String)
        case failed(String)
    }

    @Published var keyDraft = ""
    @Published private(set) var testState: TestState = .idle
    /// Ids of the ticked templates. Nothing is ticked up front: the popup should
    /// not fill up with actions nobody chose.
    @Published var picks: Set<String> = []
    /// The "AI" section of Settings → Actions → Add from Template, built once so
    /// the ids stay stable while boxes are ticked.
    let aiTemplates: [PopBarActionConfig] =
        ActionTemplates.sections().first { $0.id == "ai" }?.actions ?? []

    private var testTask: Task<Void, Never>?
    private var observers: [AnyCancellable] = []

    init(appState: AppState, progressStore: OnboardingProgressStore = OnboardingProgressStore()) {
        self.appState = appState
        self.progressStore = progressStore
        self.progress = progressStore.load()
        // The sidebar's ticks come from the permission and key state, which live
        // on other objects — republish them so the views redraw.
        observers.append(appState.store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.syncWithSystem() }
            self?.objectWillChange.send()
        })
        observers.append(appState.llm.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        })
        // An in-app language change bumps `languageRevision`; the view re-keys on it.
        observers.append(appState.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        })
    }

    // MARK: - State

    var step: OnboardingStep { progress.step }

    var env: OnboardingEnvironment {
        OnboardingEnvironment(accessibilityGranted: store.isTrusted,
                              screenRecordingGranted: store.isScreenRecordingAuthorized,
                              aiConfigured: settings.hasKeyForCurrent)
    }

    func status(of step: OnboardingStep) -> OnboardingStepStatus {
        OnboardingRules.status(of: step, progress: progress, env: env)
    }

    /// Called when the window opens.
    func opened(reason: OnboardingOpenReason) {
        progress.step = OnboardingRules.landingStep(for: reason, progress: progress,
                                                    accessibilityGranted: AccessibilityAuthorizer.isTrusted)
        progress.windowOpen = true
        Self.log.info("opened (\(String(describing: reason))) at step \(self.progress.step.rawValue)")
        refresh()
    }

    /// Called when the window closes, by any route.
    func closed() {
        // Closed by quitting (our relaunch, or macOS's "Quit & Reopen") is not
        // the user closing the guide: it has to be open again after the restart.
        if !AppDelegate.isTerminating { progress.windowOpen = false }
        testTask?.cancel()
        appState.controller.dismissPreview()
        Self.log.info("closed at step \(self.progress.step.rawValue)")
    }

    /// Re-read the permissions. Polled every second while the window is up, and
    /// on every return to the app.
    func refresh() {
        store.refreshTrust()
        syncWithSystem()
    }

    /// Screenshot Text is off by default. When the permission it needs arrives
    /// through this guide, turn the feature on as well — once — so "press ⌘⇧S" on
    /// the next line is true.
    private func syncWithSystem() {
        guard store.isScreenRecordingAuthorized, !progress.screenOCRTurnedOn,
              progress.screenRecordingRequested || progress.step == .screenRecording
        else { return }
        progress.screenOCRTurnedOn = true
        if !store.screenOCREnabled {
            store.setScreenOCREnabled(true)
            Self.log.info("Screen Recording granted — Screenshot Text switched on")
        }
    }

    // MARK: - Navigation

    func go(_ step: OnboardingStep) {
        guard step != progress.step else { return }
        if progress.step == .tryIt { appState.controller.dismissPreview() }
        progress.step = step
    }

    /// The primary "Continue" button.
    func next() {
        if progress.step == .ai { commitAIPage() }
        go(progress.step.next)
    }

    func later() { requestClose() }

    func finish() {
        progress.completed = true
        Self.log.info("finished")
        requestClose()
    }

    // MARK: - Accessibility

    func openAccessibility() {
        // The system shows its own prompt only the first time it is asked; after
        // that the call is silent, so System Settings is opened as well, always.
        AccessibilityAuthorizer.prompt()
        AccessibilityAuthorizer.openSettings()
    }

    // MARK: - Screen Recording

    func openScreenRecording() {
        progress.screenRecordingRequested = true
        progress.screenRecordingSkipped = false
        // Like the Accessibility prompt, `CGRequestScreenCaptureAccess` asks once
        // per app lifetime and is silent after that.
        _ = ScreenRecordingAuthorizer.request()
        ScreenRecordingAuthorizer.openSettings()
    }

    func skipScreenRecording() {
        progress.screenRecordingSkipped = true
        go(.ai)
    }

    /// Quit and start again, landing back on this page. The Screen Recording
    /// grant is often invisible to the process that asked for it until it
    /// restarts — that is macOS, not us.
    func relaunch() {
        var p = progress
        p.step = .screenRecording
        p.windowOpen = true
        progress = p
        progressStore.defaults.synchronize()

        Self.log.info("relaunching for Screen Recording")
        AppRelaunch.relaunch(arguments: [OnboardingProgressStore.relaunchArgument])
    }

    // MARK: - AI

    func selectProvider(_ provider: String) {
        guard provider != settings.provider else { return }
        // Same as the AI Models page: the provider picked here becomes the
        // default every AI action uses.
        settings.setProvider(provider)
        keyDraft = ""
        // A test of the provider left behind must not report into this one.
        testTask?.cancel()
        testState = .idle
    }

    func togglePick(_ id: String) {
        if picks.contains(id) { picks.remove(id) } else { picks.insert(id) }
    }

    /// Save the pasted key (if any), then send one tiny request to prove the
    /// provider, key and default model work together.
    func test() {
        // Whatever happens below, an earlier test's answer is no longer wanted.
        testTask?.cancel()
        if let error = saveDraftKey() {
            testState = .failed(error)
            return
        }
        let provider = settings.provider
        if provider == "doubao", settings.model.trimmingCharacters(in: .whitespaces).isEmpty {
            // Doubao has no default model: the endpoint id comes from the Ark console.
            testState = .failed(L("onboarding.ai.test.doubaoModel"))
            return
        }
        guard var config = settings.defaultConfig() else {
            testState = .failed(L("onboarding.ai.test.noKey"))
            return
        }
        testState = .testing
        testTask?.cancel()
        let llm = appState.llm
        let settings = settings
        testTask = Task { [weak self] in
            // Magpie has no default model, and the guide has no model picker:
            // the first model Magpie lists becomes the model. When Magpie cannot
            // be reached, the test below says so.
            if LLMConfig.picksFirstListedModel(provider), config.model.trimmingCharacters(in: .whitespaces).isEmpty {
                let failure: String?
                do {
                    let models = try await ModelClient(config.connection).listModels()
                    if let first = models.first {
                        failure = nil
                        config.model = first.id
                        // Off where the model has an Off; Default for one that does not reason.
                        config.reasoningEffort = LLMConfig.clampThinking(
                            config.reasoningEffort, for: provider, format: config.format, levels: first.reasoningLevels)
                    } else {
                        failure = L("onboarding.ai.test.magpieNoModel")
                    }
                } catch {
                    // Magpie not running, or not answering: said once, not
                    // again after a second wait in the test.
                    failure = ConnectionProblem(error).localizedText
                }
                let found = config
                let stop = await MainActor.run { () -> Bool in
                    guard let self, !Task.isCancelled else { return true }
                    if let failure {
                        self.testState = .failed(failure)
                        return true
                    }
                    settings.setModel(found.model)
                    settings.setReasoningEffort(found.reasoningEffort)
                    return false
                }
                if stop { return }
            }
            let result = await llm.testConnection(config)
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                if result.succeeded {
                    self.testState = .ok(model: config.model)
                    self.progress.aiConnected = true
                    self.progress.aiSkipped = false
                    Self.log.info("test request succeeded for \(provider)")
                } else {
                    let text = result.problem?.localizedText ?? L("models.problem.noModel")
                    self.testState = .failed(text)
                    Self.log.warn("test request failed for \(provider): \(result.problem?.description ?? "-")")
                }
            }
        }
    }

    func skipAI() {
        progress.aiSkipped = !env.aiConfigured && !progress.aiConnected
        if progress.aiSkipped { useFreeTranslate() }
        go(.tryIt)
    }

    /// No model: Translate goes to Bilibili's free translator instead, so it
    /// works on the next page already (the guide says so on the AI page).
    private func useFreeTranslate() {
        if appState.actions.useFreeTranslateForSeed() {
            Self.log.info("AI skipped: the seed's Translate now uses Bilibili's free translator")
        }
    }

    /// "Continue" / "Add N Actions & Continue" on the AI page.
    private func commitAIPage() {
        _ = saveDraftKey()
        let chosen = aiTemplates.filter { picks.contains($0.id) }
        for action in chosen {
            appState.actions.add(action)
            Analytics.trackActionAdded(kind: action.kind.rawValue, from: .template)
        }
        if !chosen.isEmpty {
            Self.log.info("added \(chosen.count) template action(s)")
            picks = []
        }
        // No model, whether or not templates were added: Translate would
        // only say "no key" on the next page.
        if !env.aiConfigured && !progress.aiConnected {
            useFreeTranslate()
            if chosen.isEmpty { progress.aiSkipped = true }
        }
    }

    /// Store whatever is in the key field. nil on success or when empty.
    private func saveDraftKey() -> String? {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, LLMConfig.needsKey(settings.provider) else { return nil }
        if let error = settings.saveKey(key, for: settings.provider) { return error }
        keyDraft = ""
        return nil
    }

    // MARK: - Try it

    /// The sample text on the last page was selected: show the real popup over it.
    func sampleSelected(_ text: String, at point: CGPoint) {
        guard store.isTrusted else { return }
        appState.controller.showForOnboardingSample(text: text, anchor: point)
        if !progress.tried { progress.tried = true }
    }

    func sampleClicked() { appState.controller.dismissPreview() }
}
