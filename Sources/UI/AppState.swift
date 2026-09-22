import SwiftUI
import Combine

/// The root model. Owns the popup's controller and stores, the shared LLM service
/// and the updater, and the sidebar selection.
///
/// Created once at launch in `AppDelegate` — NOT when the settings window opens —
/// because the popup has to work with the window closed. That is the app's whole
/// job; the window is only where you configure it.
///
/// Main-thread only (SwiftUI bindings + `.main` notification observers).
final class AppState: ObservableObject {

    let updateController: UpdateController

    /// The shared LLM service. One instance, backing both the AI Models page and
    /// every action that calls a model.
    let llm: LLMService

    /// The user's configurable actions.
    let actions: ActionStore

    /// App-lifetime popup controller: input monitoring, selection resolution, the
    /// panel itself. Started in `activate()`.
    let controller: PopBarController

    /// The settings-facing view model over `controller` + preferences.
    let store: PopBarStore

    @Published var selection: SettingsPage {
        didSet {
            guard oldValue != selection else { return }
            Analytics.trackPageOpened(selection.rawValue)
        }
    }

    /// Bumped on an in-app language change so the SwiftUI tree re-reads every
    /// `NSLocalizedString`. The selection survives the rebuild.
    @Published private(set) var languageRevision = 0

    private var languageObserver: NSObjectProtocol?

    init(updateController: UpdateController) {
        self.updateController = updateController
        let llm = LLMService()
        self.llm = llm
        let actions = ActionStore()
        self.actions = actions
        let controller = PopBarController(llm: llm, actionStore: actions)
        self.controller = controller
        self.store = PopBarStore(controller: controller)

        // A launch override can pre-select a page (dev/screenshot affordance, inert
        // in normal use), via `open <app> --args --page <id>`.
        let launchPage = Self.launchArgument("--page")
        self.selection = launchPage.flatMap(SettingsPage.init(rawValue:)) ?? .general

        languageObserver = NotificationCenter.default.addObserver(
            forName: .appLanguageChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.languageRevision &+= 1
        }
    }

    deinit {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }

    // MARK: - Lifecycle

    /// Start the app-lifetime background work. Called from `applicationDidFinishLaunching`.
    func activate() {
        controller.startIfEnabled()
        // The screenshot-OCR hotkey has its own lifecycle: it is registered even
        // when the selection popup is switched off, because they are separate
        // features that happen to live in one app.
        controller.startOCRIfEnabled()

        // Dev/screenshot affordance: pop a sample popup shortly after launch, so the
        // capsule or wheel can be looked at without selecting text by hand. Passed
        // as `open <app> --args --popbar-preview`, because `open` does not forward
        // the shell environment.
        if CommandLine.arguments.contains("--popbar-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [controller] in
                controller.showPreview()
            }
        }
    }

    /// Stop background work cleanly (from `applicationWillTerminate`).
    func shutdown() {
        controller.stop()
        controller.stopScreenOCR()   // not torn down by stop() — independent lifecycle
    }

    // MARK: - Launch arguments

    /// The value following a `--flag` in the launch arguments (as passed by
    /// `open … --args --flag <value>`), or nil if absent.
    private static func launchArgument(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        let value = args[i + 1]
        return value.hasPrefix("-") ? nil : value
    }
}
