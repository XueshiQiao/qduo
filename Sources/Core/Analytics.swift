import Foundation
import Aptabase

/// Thin facade over the Aptabase SDK. All call sites go through this enum so the
/// rest of the codebase never imports `Aptabase` directly and the opt-out gate
/// lives in exactly one place.
///
/// `appKey` is the project's real Aptabase key. `start()` still refuses a
/// placeholder key ("A-XX-…"), so a fork that blanks it goes inert rather than
/// sending events somewhere else. Debug builds report too, on purpose: Aptabase
/// marks their events as debug and shows them apart from release data, and a
/// debug run is how a key change gets checked end to end.
///
/// Privacy contract:
/// - No bundle IDs, process names, or paths ever leave the device.
/// - Actions are reported by KIND only (`ai`, `transform`, …) — never a title,
///   prompt, script, URL, Shortcut name, language or the selected text.
/// - All events are gated on `Preferences.Key.analyticsEnabled` (default true)
///   EXCEPT the meta-event recording the toggle itself, so an OFF→ON re-enable
///   stays observable.
enum Analytics {

    private static let log = FileLog("Analytics")

    /// The Aptabase app key (US region).
    private static let appKey = "A-US-7811464121"

    private static var started = false

    /// True only once a real (non-placeholder) key has been configured.
    private static var isConfigured: Bool {
        !appKey.isEmpty && !appKey.hasPrefix("A-XX-")
    }

    // MARK: - Lifecycle

    /// `launchProps`: fixed values describing the setup, sent with
    /// `app_launched` (e.g. the popup style) — never anything the user typed.
    static func start(launchProps: [String: String] = [:]) {
        guard !started else { return }
        guard isConfigured else {
            log.info("analytics inert — placeholder appKey; events are no-ops")
            return
        }
        started = true
        Aptabase.shared.initialize(appKey: appKey)
        startSending()
        if launchProps.isEmpty { track("app_launched") } else { track("app_launched", with: launchProps) }
        trackUpdateInstalledIfNeeded()
    }

    /// The SDK only starts its send timer when the app becomes active
    /// (`NSApplication.didBecomeActiveNotification`). A menu-bar app almost never
    /// does, so events sat in memory until quit — and the flush at quit is an
    /// async task the process rarely outlives. Start the SDK's own timer now.
    ///
    /// It has to be the SDK's timer, not one of ours calling `flush()`: the SDK's
    /// queue dequeues without a barrier, so two flushes running at once race, and
    /// only its own timer guards against overlapping itself. `startPolling` is
    /// private but `@objc`; if a future SDK drops it, we log and carry on (events
    /// then go out once the app is brought to the front, as before).
    private static func startSending() {
        let startPolling = NSSelectorFromString("startPolling")
        if Aptabase.shared.responds(to: startPolling) {
            Aptabase.shared.perform(startPolling)
        } else {
            log.error("Aptabase has no startPolling — events wait until the app is activated")
        }
    }

    static func flush() {
        guard started else { return }
        Aptabase.shared.flush()
    }

    // MARK: - Events

    /// Which settings page was opened. The page id is a fixed, non-localized
    /// string from `SettingsPage` — never anything the user typed.
    static func trackPageOpened(_ pageID: String) {
        track("page_opened", with: ["page": pageID])
    }

    static func trackPreferenceChanged(key: String, value: String) {
        if key == "analytics_enabled" {
            sendDirect("preference_changed", props: ["key": key, "value": value])
            return
        }
        track("preference_changed", with: ["key": key, "value": value])
    }

    /// Where an added action came from.
    enum ActionSource: String {
        /// Picked from the templates (the Actions page menu, or onboarding).
        case template
        /// Made from scratch with Add Action / Add Group.
        case custom
        /// An existing action saved with a different kind.
        case changed
    }

    /// An action was added, or saved as a different kind. Only its kind — a
    /// fixed identifier from `PopBarActionConfig.Kind` — and where it came from.
    static func trackActionAdded(kind: String, from source: ActionSource) {
        track("action_added", with: ["kind": kind, "from": source.rawValue])
    }

    // MARK: - Update detection

    private static func trackUpdateInstalledIfNeeded() {
        let d = UserDefaults.standard
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let last = d.string(forKey: Preferences.Key.lastSeenVersion)
        if let last, !last.isEmpty, last != current {
            track("update_installed", with: ["from_version": last, "to_version": current])
        }
        if !current.isEmpty { d.set(current, forKey: Preferences.Key.lastSeenVersion) }
    }

    // MARK: - Internals

    private static func track(_ name: String) {
        guard started, Preferences.analyticsEnabled else { return }
        Aptabase.shared.trackEvent(name)
    }

    private static func track(_ name: String, with props: [String: String]) {
        guard started, Preferences.analyticsEnabled else { return }
        Aptabase.shared.trackEvent(name, with: props)
    }

    /// Gate-bypassing send (used only for the analytics_enabled toggle event so
    /// both directions of the toggle reach the server).
    private static func sendDirect(_ name: String, props: [String: String]) {
        guard started else { return }
        Aptabase.shared.trackEvent(name, with: props)
    }
}
