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
/// - All events are gated on `Preferences.Key.analyticsEnabled` (default true)
///   EXCEPT the meta-event recording the toggle itself, so an OFF→ON re-enable
///   stays observable.
enum Analytics {

    private static let log = FileLog("Analytics")

    /// The Aptabase app key (US region).
    private static let appKey = "A-US-7811464121"

    private static var started = false

    /// The SDK only starts its own send timer when the app becomes active
    /// (`NSApplication.didBecomeActiveNotification`). A menu-bar app almost never
    /// does, so events sat in memory until quit — and the flush at quit is an
    /// async task the process rarely outlives. This timer sends them regardless.
    private static var flushTimer: Timer?
    #if DEBUG
    private static let flushInterval: TimeInterval = 5
    #else
    private static let flushInterval: TimeInterval = 60
    #endif

    /// True only once a real (non-placeholder) key has been configured.
    private static var isConfigured: Bool {
        !appKey.isEmpty && !appKey.hasPrefix("A-XX-")
    }

    // MARK: - Lifecycle

    static func start() {
        guard !started else { return }
        guard isConfigured else {
            log.info("analytics inert — placeholder appKey; events are no-ops")
            return
        }
        started = true
        Aptabase.shared.initialize(appKey: appKey)
        flushTimer = Timer.scheduledTimer(withTimeInterval: flushInterval, repeats: true) { _ in
            Aptabase.shared.flush()
        }
        track("app_launched")
        trackUpdateInstalledIfNeeded()
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
