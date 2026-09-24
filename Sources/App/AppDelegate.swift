import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let log = FileLog("AppDelegate")

    private let updateController = UpdateController()
    private var appState: AppState?
    private var menuBarController: MenuBarController?

    /// Set the first time the app is launched, so the onboarding guide opens once —
    /// on a fresh install there is nothing in the menu bar yet that tells you the
    /// app needs the Accessibility permission before it can do anything.
    private static let hasLaunchedKey = "hasLaunchedBefore"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon, not in Cmd-Tab. `Info.plist` already sets
        // LSUIElement; this makes it explicit and covers a direct-binary launch.
        NSApp.setActivationPolicy(.accessory)

        // Load the config file FIRST: every setting below is read out of it,
        // including the language override, which has to be installed before any
        // localized string is read.
        _ = ConfigStore.shared
        Preferences.applyLanguageOverride()

        // Inert until a real Aptabase key is configured.
        Analytics.start()

        Self.log.info("launch — \(Brand.name) v\(Brand.version) (\(Brand.build)), id \(Brand.bundleID)")

        // Read BEFORE `AppState` exists: building it seeds the default actions
        // into a config file that has none, and after that every install looks
        // like an existing one.
        let defaults = UserDefaults.standard
        let neverLaunched = !defaults.bool(forKey: Self.hasLaunchedKey)
        let configHasActions = ConfigStore.shared.value("actions") != nil
        if neverLaunched { defaults.set(true, forKey: Self.hasLaunchedKey) }

        // The onboarding guide opens on a genuinely new install only — never
        // launched here, and no actions in a config file brought from elsewhere —
        // or when it relaunched the app itself. See `OnboardingRules.openAtLaunch`.
        let progressStore = OnboardingProgressStore()
        var progress = progressStore.load()
        let onboarding = OnboardingRules.openAtLaunch(
            isFirstRun: neverLaunched && !configHasActions,
            relaunchRequested: CommandLine.arguments.contains(OnboardingProgressStore.relaunchArgument),
            progress: progress)
        if onboarding == nil, progress.windowOpen {
            progress.windowOpen = false
            progressStore.save(progress)
        }

        let state = AppState(updateController: updateController)
        appState = state
        // Start the popup BEFORE any window exists: its whole job is to work while
        // you are in some other app. On a first launch the system's Accessibility
        // dialog waits: the guide explains the permission, then asks for it.
        state.activate(promptForAccessibility: onboarding != .firstLaunch)

        menuBarController = MenuBarController(appState: state, updateController: updateController)

        // `--settings` forces the window open; scripts/run.sh passes it so a rebuild
        // during development comes back with the window where you left it.
        // A first launch that is not new to the app (a config file brought from
        // another Mac) gets what every first launch got before the guide existed.
        let showSettings = CommandLine.arguments.contains("--settings")
            || (neverLaunched && onboarding == nil)
        if showSettings {
            DispatchQueue.main.async { [weak self] in self?.menuBarController?.showMainWindow() }
        }
        if let onboarding {
            DispatchQueue.main.async { [weak self] in self?.menuBarController?.showOnboarding(reason: onboarding) }
        }
    }

    /// Set before AppKit starts tearing windows down on quit, so a window's close
    /// handler can tell "the user closed me" from "the app is quitting" — macOS's
    /// own "Quit & Reopen" after a Screen Recording grant must not count as the
    /// user closing the onboarding guide.
    static private(set) var isTerminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.isTerminating = true
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.shutdown()
        // Saves are debounced, so a change made in the last fraction of a second
        // would otherwise be lost on quit.
        ConfigStore.shared.flush()
        Analytics.flush()
    }

    /// There is no Dock icon to click, but a second launch of the app (e.g. opening
    /// it from Finder while it is already running) arrives here — treat it as
    /// "show me the settings" rather than doing nothing visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { menuBarController?.showMainWindow() }
        return true
    }
}
