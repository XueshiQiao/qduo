import SwiftUI
import AppKit

/// UI model for the PopBar settings page. Plain main-thread `ObservableObject`
/// (same shape as the other tools' stores). Bridges the settings UI to the
/// long-lived `PopBarController`.
final class PopBarStore: ObservableObject {

    @Published var autoExpandHeight: Bool
    @Published var resultFontSize: Double
    @Published var readingHighlight: ReadingHighlightStyle
    @Published var style: PopBarStyle
    @Published var wheelOuterRadius: Double
    @Published var wheelInnerRadius: Double
    @Published var wheelShowIcons: Bool
    @Published var wheelShowLabels: Bool
    @Published var wheelAutoHideOnExit: Bool
    @Published var wheelDonutDividers: Bool
    @Published var wheelLiquidDividers: Bool
    @Published var wheelSubSeam: Double
    @Published var wheelSubThickness: Double
    @Published private(set) var isTrusted: Bool
    /// False while paused. See `PopBarPreferences.popupEnabled`.
    @Published private(set) var popupEnabled: Bool
    @Published private(set) var simulateCopy: Bool
    @Published private(set) var ignoreAddressBars: Bool
    @Published private(set) var excludedApps: [String]
    @Published private(set) var terminalApps: [String]

    // Popup hotkey (issue #4)
    @Published private(set) var popupHotKeyEnabled: Bool
    /// Nil until one is recorded — there is no default combo.
    @Published private(set) var popupHotKey: KeyCombo?
    /// Whether the popup hotkey is actually registered right now (false while
    /// off, while none is recorded, or when the combo is taken).
    @Published private(set) var popupHotKeyRegistered: Bool

    // Screenshot OCR
    @Published var screenOCREnabled: Bool
    @Published var screenOCRAutoCopy: Bool
    @Published var screenOCRHotKey: KeyCombo
    @Published private(set) var isScreenRecordingAuthorized: Bool
    /// Whether the OCR hotkey is actually registered right now — can be false even when
    /// `screenOCREnabled` is true (e.g. the stored combo was taken at launch).
    @Published private(set) var screenOCRRegistered: Bool

    private let controller: PopBarController

    init(controller: PopBarController) {
        self.controller = controller
        self.autoExpandHeight = PopBarPreferences.autoExpandHeight
        self.resultFontSize = PopBarPreferences.resultFontSize
        self.readingHighlight = PopBarPreferences.readingHighlight
        self.style = PopBarPreferences.style
        self.wheelOuterRadius = PopBarPreferences.wheelOuterRadius
        self.wheelInnerRadius = PopBarPreferences.wheelInnerRadius
        self.wheelShowIcons = PopBarPreferences.wheelShowIcons
        self.wheelShowLabels = PopBarPreferences.wheelShowLabels
        self.wheelAutoHideOnExit = PopBarPreferences.wheelAutoHideOnExit
        self.wheelDonutDividers = PopBarPreferences.wheelDonutDividers
        self.wheelLiquidDividers = PopBarPreferences.wheelLiquidDividers
        self.wheelSubSeam = PopBarPreferences.wheelSubSeam
        self.wheelSubThickness = PopBarPreferences.wheelSubThickness
        self.isTrusted = AccessibilityAuthorizer.isTrusted
        self.popupEnabled = PopBarPreferences.popupEnabled
        self.simulateCopy = PopBarPreferences.simulateCopy
        self.ignoreAddressBars = PopBarPreferences.ignoreAddressBars
        self.excludedApps = PopBarPreferences.excludedApps
        self.terminalApps = PopBarPreferences.terminalApps
        self.popupHotKeyEnabled = PopBarPreferences.popupHotKeyEnabled
        self.popupHotKey = PopBarPreferences.popupHotKey
        self.popupHotKeyRegistered = controller.popupHotKeyIsRegistered
        self.screenOCREnabled = PopBarPreferences.screenOCREnabled
        self.screenOCRAutoCopy = PopBarPreferences.screenOCRAutoCopy
        self.screenOCRHotKey = PopBarPreferences.screenOCRHotKey
        self.isScreenRecordingAuthorized = ScreenRecordingAuthorizer.isAuthorized
        self.screenOCRRegistered = controller.screenOCRIsRegistered
        // Deferred a turn: pausing closes every popup window, and the request
        // arrives from inside one of them while it is still handling the tap.
        // Already paused is possible — the OCR popup and the settings preview
        // still open while paused — and then the tap must still close them.
        controller.onPauseRequested = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.popupEnabled { self.setPopupEnabled(false) } else { self.controller.stop() }
            }
        }
    }

    /// Toggle whether the result panel auto-grows its height to fit content.
    /// Persisted in PopBar's own prefs; the controller pushes it to a live panel
    /// so an already-open result honors the change immediately.
    func setAutoExpandHeight(_ on: Bool) {
        autoExpandHeight = on
        PopBarPreferences.autoExpandHeight = on
        controller.setAutoExpandHeight(on)
    }

    /// Set the result Markdown's base font size (issue #14). Persisted in PopBar's
    /// own prefs; the controller pushes it to every live panel so an already-open
    /// result re-renders at the new size immediately. Mirrors `setAutoExpandHeight`.
    func setReadingHighlight(_ style: ReadingHighlightStyle) {
        readingHighlight = style
        PopBarPreferences.readingHighlight = style
    }

    func setResultFontSize(_ size: Double) {
        resultFontSize = size
        PopBarPreferences.resultFontSize = size
        controller.setResultFontSize(size)
    }

    /// Re-check the Accessibility grant (the user may toggle it in System
    /// Settings while we run); start monitoring if it just became available.
    func refreshTrust() {
        let trusted = AccessibilityAuthorizer.isTrusted
        if trusted != isTrusted { isTrusted = trusted }
        // Granted while we were running: start straight away, so the app works
        // the moment the switch is flipped in System Settings rather than after a
        // relaunch. `start()` itself declines while paused.
        if trusted && !controller.isRunning {
            controller.start()
        }
        // The Screen Recording grant can also change in System Settings while we run;
        // reflect it so the OCR permission row auto-hides once it's granted.
        let screenRec = ScreenRecordingAuthorizer.isAuthorized
        if screenRec != isScreenRecordingAuthorized { isScreenRecordingAuthorized = screenRec }
        let reg = controller.screenOCRIsRegistered
        if reg != screenOCRRegistered { screenOCRRegistered = reg }
        let popupReg = controller.popupHotKeyIsRegistered
        if popupReg != popupHotKeyRegistered { popupHotKeyRegistered = popupReg }
    }

    /// Switch the popup's presentation style. Persisted in PopBar's own prefs and
    /// reflected live in the centered preview (so flipping capsule ↔ wheel ↔ liquid in
    /// settings shows the new style immediately).
    func setStyle(_ s: PopBarStyle) {
        if s != style { Analytics.trackPreferenceChanged(key: "popup_style", value: s.rawValue) }
        style = s
        PopBarPreferences.style = s
        controller.previewStyleLive()   // show/refresh the preview so the new style is visible live
    }

    /// Wheel geometry / content settings (wheel + liquid-glass styles). Persisted;
    /// the next popup / Preview reads them at show time. Inner is kept at least
    /// `wheelMinThickness` below outer so the ring stays valid.
    func setWheelOuterRadius(_ r: Double) {
        wheelOuterRadius = r
        PopBarPreferences.wheelOuterRadius = r
        if wheelInnerRadius > r - PopBarPreferences.wheelMinThickness {
            setWheelInnerRadius(r - PopBarPreferences.wheelMinThickness)
        }
        controller.previewWheelLive()
    }
    func setWheelInnerRadius(_ r: Double) {
        let capped = min(r, wheelOuterRadius - PopBarPreferences.wheelMinThickness)
        wheelInnerRadius = capped
        PopBarPreferences.wheelInnerRadius = capped
        controller.previewWheelLive()
    }
    func setWheelShowIcons(_ on: Bool) {
        // Don't let the user hide BOTH icon and label (a slice would be blank).
        if !on && !wheelShowLabels { setWheelShowLabels(true) }
        wheelShowIcons = on
        PopBarPreferences.wheelShowIcons = on
        controller.previewWheelLive()
    }
    func setWheelShowLabels(_ on: Bool) {
        if !on && !wheelShowIcons { setWheelShowIcons(true) }
        wheelShowLabels = on
        PopBarPreferences.wheelShowLabels = on
        controller.previewWheelLive()
    }
    /// Submenu ring (second level) geometry. Same live-preview treatment as the
    /// main ring's radii: the showing preview re-fits in place while the slider
    /// moves, so the two rings can be sized against each other by eye.
    func setWheelSubSeam(_ v: Double) {
        wheelSubSeam = v
        PopBarPreferences.wheelSubSeam = v
        controller.previewWheelLive()
    }
    func setWheelSubThickness(_ v: Double) {
        wheelSubThickness = v
        PopBarPreferences.wheelSubThickness = v
        controller.previewWheelLive()
    }
    /// Auto-hide the ring when the pointer leaves it (wheel + liquid-glass only).
    /// Persisted; the next popup / preview reads it at show time.
    func setWheelAutoHideOnExit(_ on: Bool) {
        wheelAutoHideOnExit = on
        PopBarPreferences.wheelAutoHideOnExit = on
    }
    /// Whether the liquid style shows dividers between slices. Shown live.
    func setWheelLiquidDividers(_ on: Bool) {
        wheelLiquidDividers = on
        PopBarPreferences.wheelLiquidDividers = on
        controller.previewStyleLive()
    }
    /// Whether the 3D style shows the grooves between slices. Shown live.
    func setWheelDonutDividers(_ on: Bool) {
        wheelDonutDividers = on
        PopBarPreferences.wheelDonutDividers = on
        controller.previewStyleLive()
    }

    // MARK: - Paused

    /// Pause or resume the popup. Takes effect at once: pausing closes anything
    /// showing and stops the popup opening on a selection (the popup hotkey, if
    /// on, still works); resuming starts again if permitted.
    func setPopupEnabled(_ on: Bool) {
        guard on != popupEnabled else { return }
        popupEnabled = on
        PopBarPreferences.popupEnabled = on
        if on { controller.start() } else { controller.stop() }
    }

    // MARK: - Popup hotkey (issue #4)

    /// Turn the popup hotkey on or off. Returns false when turning it on could not
    /// register a recorded combo because another app holds it.
    @discardableResult
    func setPopupHotKeyEnabled(_ on: Bool) -> Bool {
        let wasUsable = popupHotKeyRegistered
        popupHotKeyEnabled = on
        PopBarPreferences.popupHotKeyEnabled = on
        let ok = controller.setPopupHotKeyEnabled(on)
        popupHotKeyRegistered = controller.popupHotKeyIsRegistered
        pauseIfHotKeyJustBecameUsable(wasUsable: wasUsable)
        // No combo recorded yet is not a failure — the page asks for one.
        return ok || popupHotKey == nil
    }

    /// Record a new popup hotkey. Refused when it is the screenshot-OCR one (one
    /// combo cannot do two things) or when another app holds it.
    @discardableResult
    func setPopupHotKey(_ combo: KeyCombo) -> Bool {
        guard combo != screenOCRHotKey else { return false }
        let wasUsable = popupHotKeyRegistered
        let ok = controller.setPopupHotKey(combo)
        if ok { popupHotKey = combo }
        popupHotKeyRegistered = controller.popupHotKeyIsRegistered
        pauseIfHotKeyJustBecameUsable(wasUsable: wasUsable)
        return ok
    }

    /// Someone who turns the popup hotkey on almost always wants the popup to
    /// open ONLY when they press it — so the moment it starts working (switched
    /// on with a combo, or the first combo recorded) the popup is paused for
    /// them. Only on that transition: resuming afterwards, for "both", sticks,
    /// and re-recording a combo does not pause again. Not before it works
    /// either — pausing with no working hotkey would leave nothing that opens it.
    private func pauseIfHotKeyJustBecameUsable(wasUsable: Bool) {
        guard !wasUsable, popupHotKeyRegistered, popupEnabled else { return }
        setPopupEnabled(false)
    }

    // MARK: - Where the popup reads

    /// Read at trigger time, so the next selection honors it.
    func setSimulateCopy(_ on: Bool) {
        simulateCopy = on
        PopBarPreferences.simulateCopy = on
    }

    func setIgnoreAddressBars(_ on: Bool) {
        ignoreAddressBars = on
        PopBarPreferences.ignoreAddressBars = on
    }

    func excludeApp(_ bundleID: String) {
        guard !excludedApps.contains(bundleID) else { return }
        excludedApps.append(bundleID)
        PopBarPreferences.excludedApps = excludedApps
    }

    func includeApp(_ bundleID: String) {
        excludedApps.removeAll { $0 == bundleID }
        PopBarPreferences.excludedApps = excludedApps
    }

    /// Read at trigger time, so the next selection honors it.
    func addTerminalApp(_ bundleID: String) {
        guard !terminalApps.contains(bundleID) else { return }
        terminalApps.append(bundleID)
        PopBarPreferences.terminalApps = terminalApps
    }

    func removeTerminalApp(_ bundleID: String) {
        terminalApps.removeAll { $0 == bundleID }
        PopBarPreferences.terminalApps = terminalApps
    }

    func requestPermission() { AccessibilityAuthorizer.prompt() }
    func openAccessibilitySettings() { AccessibilityAuthorizer.openSettings() }
    func showPreview() { controller.showPreview() }
    /// Hide the live tuning preview when the user leaves the PopBar settings page.
    func dismissPreview() { controller.dismissPreview() }

    // MARK: - Screenshot OCR

    /// Enable/disable screenshot OCR. Persists the choice and registers/unregisters the
    /// global hotkey. Returns false if enabling failed because the combo is already
    /// taken system-wide (the settings UI surfaces that).
    @discardableResult
    func setScreenOCREnabled(_ on: Bool) -> Bool {
        screenOCREnabled = on
        PopBarPreferences.screenOCREnabled = on
        let ok: Bool
        if on {
            ok = controller.startScreenOCR()
        } else {
            controller.stopScreenOCR()
            ok = true
        }
        screenOCRRegistered = controller.screenOCRIsRegistered
        return ok
    }

    func setScreenOCRAutoCopy(_ on: Bool) {
        screenOCRAutoCopy = on
        PopBarPreferences.screenOCRAutoCopy = on
    }

    /// Record a new OCR hotkey. Returns false if it couldn't be registered (taken); on
    /// success the published combo is updated so the recorder field reflects it.
    @discardableResult
    func setScreenOCRHotKey(_ combo: KeyCombo) -> Bool {
        guard combo != popupHotKey else { return false }   // the popup hotkey has it
        let ok = controller.setScreenOCRHotKey(combo)
        if ok { screenOCRHotKey = combo }
        screenOCRRegistered = controller.screenOCRIsRegistered
        return ok
    }

    func requestScreenRecording() { _ = ScreenRecordingAuthorizer.request() }
    func openScreenRecordingSettings() { ScreenRecordingAuthorizer.openSettings() }
}
