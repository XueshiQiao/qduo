import AppKit

/// The Screenshot-OCR front-step coordinator: a global hotkey puts up a drag-select
/// overlay, the chosen region is OCR'd, and the recognized text is (optionally) copied
/// to the clipboard and shown in the SAME PopBar capsule via `PopBarWindowManager` —
/// so every existing action runs on the OCR'd text exactly like a normal selection.
///
/// Deliberately INDEPENDENT of PopBar's text-selection monitor. A key combination
/// needs only Screen Recording (checked at capture time), not Accessibility, so it
/// works even when the selection popup is off. A double tap of one modifier is the
/// exception: hearing it in other apps needs Accessibility, because that path is an
/// `NSEvent` monitor rather than a Carbon hotkey. Main-thread only by convention
/// (hotkey callback + all UI).
final class ScreenOCRController {

    private static let log = FileLog("PopBar.OCR")

    private let windows: PopBarWindowManager
    private let actionStore: ActionStore
    private var hotKey: HotKeyRegistration?
    /// Guards against putting up a second overlay while one is already on screen.
    private var capturing = false
    /// Held for the duration of one capture so the overlay controller (which owns the
    /// per-screen overlay windows) isn't deallocated before its completion fires.
    private var regionSelector: RegionSelectionController?
    /// Bumped per capture so a slow OCR completion from an earlier capture can't
    /// overwrite the clipboard/capsule after a newer capture has superseded it.
    private var captureGeneration = 0

    /// A finished recognition (its capsule or "no text" toast) that arrived while the
    /// overlay of a newer capture was open. Showing it then would put it on the screen
    /// the user is about to grab. It is shown if that capture is cancelled, and dropped
    /// if the capture picks a region (the result is then out of date) or the tool stops.
    private var heldDelivery: (() -> Void)?
    /// The "recognizing…" label of the capture whose OCR is still running, so a new
    /// capture (or switching the feature off) can take it off the screen.
    private var progressHint: RegionProgressHint?

    init(windows: PopBarWindowManager, actionStore: ActionStore) {
        self.windows = windows
        self.actionStore = actionStore
    }

    /// Whether the global hotkey is currently registered.
    var isEnabled: Bool { hotKey != nil }

    // MARK: - Lifecycle (call on main)

    /// Register the hotkey only if the user opted in (used at app launch).
    func startIfEnabled() {
        guard PopBarPreferences.screenOCREnabled else {
            Self.log.info("OCR disabled — not registering hotkey")
            return
        }
        _ = start()
    }

    /// Register the global hotkey from prefs. Returns false if registration failed
    /// (a combo is already taken system-wide, or that double-tap modifier is
    /// already in use here) so the caller can surface it.
    @discardableResult
    func start() -> Bool {
        if hotKey != nil { return true }
        let trigger = PopBarPreferences.screenOCRHotKey
        hotKey = HotKeyRegistrar.register(trigger) { [weak self] in self?.triggerCapture() }
        guard hotKey != nil else {
            Self.log.warn("failed to register OCR hotkey \(trigger.display) — likely taken")
            return false
        }
        Self.log.info("OCR hotkey registered: \(trigger.display)")
        TextRecognizer.warmUp()
        return true
    }

    /// Unregister the hotkey (feature disabled / tool shutdown).
    func stop() {
        // A recognition still running must not copy or pop anything after the tool is off.
        captureGeneration &+= 1
        heldDelivery = nil
        progressHint?.dismiss()
        progressHint = nil
        hotKey?.invalidate()
        hotKey = nil
        Self.log.info("OCR hotkey unregistered")
    }

    /// Persist + (re)register a new hotkey. On a registration failure the PREVIOUS
    /// hotkey is kept registered (never leaves the user with no working hotkey) and
    /// the new one is NOT persisted. Returns false in that case.
    @discardableResult
    func setHotKey(_ trigger: HotKeyTrigger) -> Bool {
        guard PopBarPreferences.screenOCREnabled else {
            // Nothing registered yet — just store it; `start()` will use it when enabled.
            PopBarPreferences.screenOCRHotKey = trigger
            return true
        }
        hotKey?.invalidate()
        hotKey = HotKeyRegistrar.register(trigger) { [weak self] in self?.triggerCapture() }
        if hotKey == nil {
            Self.log.warn("failed to register new OCR hotkey \(trigger.display) — reverting to previous")
            let previous = PopBarPreferences.screenOCRHotKey
            hotKey = HotKeyRegistrar.register(previous) { [weak self] in self?.triggerCapture() }
            return false
        }
        PopBarPreferences.screenOCRHotKey = trigger
        Self.log.info("OCR hotkey re-registered: \(trigger.display)")
        TextRecognizer.warmUp()
        return true
    }

    // MARK: - Capture → OCR → capsule

    /// The full front-step flow, fired by the hotkey. Runs entirely on main except the
    /// Vision OCR (which hops back to main before touching any window).
    func triggerCapture() {
        guard !capturing else { return }
        // Also reached from the menu bar item, where the hotkey was never registered.
        // Does nothing when the warm-up already ran.
        TextRecognizer.warmUp()
        guard ScreenRecordingAuthorizer.isAuthorized else {
            // First press ever shows the system prompt; a previously-denied user is sent
            // to System Settings. Either way we don't put up the overlay yet.
            Self.log.warn("no Screen Recording permission — requesting / guiding to settings")
            if !ScreenRecordingAuthorizer.request() {
                ScreenRecordingAuthorizer.openSettings()
            }
            return
        }
        capturing = true
        // `stop()` bumps the generation, so a changed value after the overlay closes
        // means the tool was switched off while the user was still selecting.
        let generationAtTrigger = captureGeneration
        let selector = RegionSelectionController()
        regionSelector = selector
        // The app being looked at, read before the overlay takes the focus.
        let origin = HistoryOrigin(trigger: .ocr, app: NSWorkspace.shared.frontmostApplication)
        selector.begin { [weak self] selection in
            guard let self else { return }
            self.regionSelector = nil
            self.capturing = false
            let held = self.heldDelivery
            self.heldDelivery = nil
            guard let selection else {            // cancelled (Esc / right-click / too small)
                held?()                           // the earlier result is still current
                return
            }
            if held != nil { Self.log.info("dropping an OCR result that finished behind this capture's overlay") }
            guard generationAtTrigger == self.captureGeneration else {
                Self.log.info("capture finished after the tool was stopped — dropped")
                return
            }

            // Only a capture that really picked a region supersedes an earlier one. A
            // capture the user cancelled must not throw away the earlier capture's
            // OCR result that is still being worked out.
            self.captureGeneration &+= 1
            let generation = self.captureGeneration
            // The earlier capture's result is now discarded, so its "Recognizing…" label
            // goes too. Before this point (overlay up, or cancelled) it stays, because
            // that result will still be shown.
            self.progressHint?.dismiss()
            self.progressHint = nil
            // A capsule from an earlier capture may still be on the screen. Take it down
            // before the screen is grabbed, or it would end up in this capture.
            self.windows.dismissTransient()

            let rect = selection.globalCocoaRect
            // Anchor the capsule at the region's TOP-center, so it floats just above the
            // selection (matching the text-selection capsule which sits above its anchor).
            let anchor = CGPoint(x: rect.midX, y: rect.maxY)
            // The wheel (ring) is centred ON its anchor, so it must land on the mouse,
            // which is where the drag was released. The top-center point is only right
            // for the capsule, which sits above its anchor.
            let popupAnchor = PopBarPreferences.style.isWheel ? NSEvent.mouseLocation : anchor

            guard let image = ScreenCaptureService.capture(globalCocoaRect: rect, on: selection.screen) else {
                Self.log.warn("screen capture returned nil (permission revoked mid-session?)")
                RegionToast.show(L("popbar.ocr.captureFailed"), atGlobalCocoa: popupAnchor)
                return
            }

            // The first recognition after an install or update can take 10+ seconds
            // (see `TextRecognizer.warmUp`), so say so instead of showing nothing.
            let progress = RegionProgressHint(L("popbar.ocr.recognizing"), atGlobalCocoa: popupAnchor, delay: 0.4)
            self.progressHint = progress
            TextRecognizer.recognize(image) { [weak self] text in
                progress.dismiss()
                guard let self else { return }
                if self.progressHint === progress { self.progressHint = nil }
                // Discard a stale completion: a newer capture superseded this one while
                // Vision was running, so it must not overwrite the clipboard/capsule.
                guard generation == self.captureGeneration else {
                    Self.log.info("discarding stale OCR result (gen \(generation) ≠ \(self.captureGeneration))")
                    return
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let deliver = { [weak self] in
                    guard let self else { return }
                    guard !trimmed.isEmpty else {
                        Self.log.info("OCR found no text in the region")
                        RegionToast.show(L("popbar.ocr.noText"), atGlobalCocoa: popupAnchor)
                        return
                    }
                    if PopBarPreferences.screenOCRAutoCopy {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(trimmed, forType: .string)
                    }
                    Self.log.info("OCR recognized \(trimmed.count) chars → capsule")
                    self.windows.showTransient(text: trimmed, url: nil, source: .ocr, anchor: popupAnchor,
                                               actions: self.actionStore.actions, origin: origin)
                }
                // A newer capture's overlay is open: hold the result until it closes.
                if self.capturing { self.heldDelivery = deliver } else { deliver() }
            }
        }
    }
}
