import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let log = FileLog("AppDelegate")

    private let updateController = UpdateController()
    private var appState: AppState?
    private var menuBarController: MenuBarController?

    /// Set the first time the app is launched, so the settings window opens once —
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

        let state = AppState(updateController: updateController)
        appState = state
        // Start the popup BEFORE any window exists: its whole job is to work while
        // you are in some other app.
        state.activate()

        menuBarController = MenuBarController(appState: state, updateController: updateController)

        let defaults = UserDefaults.standard
        let firstRun = !defaults.bool(forKey: Self.hasLaunchedKey)
        if firstRun { defaults.set(true, forKey: Self.hasLaunchedKey) }

        // `--settings` forces the window open; scripts/run.sh passes it so a rebuild
        // during development comes back with the window where you left it.
        if firstRun || CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.async { [weak self] in self?.menuBarController?.showMainWindow() }
        }
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
