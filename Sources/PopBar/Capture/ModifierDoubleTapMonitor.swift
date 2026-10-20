import AppKit
import Carbon.HIToolbox   // kVK_Function, kVK_CapsLock

/// The AppKit bit for one modifier. Left and right set the same flag, which is
/// why a double tap cannot tell them apart. Kept off `ModifierKey` so that type
/// (and the tests) do not import AppKit.
extension ModifierKey {
    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .control: return .control
        case .option:  return .option
        case .shift:   return .shift
        case .command: return .command
        }
    }
}

extension Set where Element == ModifierKey {
    /// ctrl / opt / shift / cmd that are down. Fn and Caps Lock are not in here.
    init(modifierFlags flags: NSEvent.ModifierFlags) {
        self = Set(ModifierKey.allCases.filter { flags.contains($0.modifierFlag) })
    }
}

extension NSEvent {
    /// Fn (key code 63) and Caps Lock (57) are delivered as `.flagsChanged`,
    /// and they are not one of the four modifiers. The detector treats them as
    /// an ordinary key, so they cancel a tap that was in progress.
    var isFnOrCapsLockChange: Bool {
        type == .flagsChanged &&
            (keyCode == UInt16(kVK_Function) || keyCode == UInt16(kVK_CapsLock))
    }
}

/// Hears "the same modifier pressed twice" in every app.
///
/// Not part of `GlobalInputMonitor`. That monitor only runs while the popup is
/// on, or the popup hotkey is on. Screenshot Text has its own life cycle, and
/// its hotkey has to work while the popup is off. One shared monitor serves
/// both: each modifier can be registered once.
///
/// A global monitor plus a local one. The global one hears events sent to other
/// apps (it is not a `CGEventTap`); the local one hears events sent to this app,
/// including while the settings window is key. One event never arrives on both.
/// Without authorization, key events sent to other apps are not delivered; after
/// authorization an already installed monitor is not guaranteed to start
/// receiving events, so we re-install. Neither swallows the event, so the app
/// in front still sees the two presses. Dictation set to press Control twice,
/// and Shift-Shift in a JetBrains IDE, fire at the same time.
///
/// Main thread only. `NSEvent` monitors call back on the main thread, and the
/// hotkey registrars run there too.
final class ModifierDoubleTapMonitor {

    static let shared = ModifierDoubleTapMonitor()

    private static let log = FileLog("PopBar.DoubleTap")

    private static let mask: NSEvent.EventTypeMask = [
        .flagsChanged, .keyDown,
        .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .scrollWheel,
    ]

    private struct Handler {
        let token: UUID
        let onFired: () -> Void
    }

    private var handlers: [ModifierKey: Handler] = [:]
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var detector = ModifierDoubleTapDetector()

    /// True while `HotKeyRecorderField` is recording. Events are ignored, and
    /// clearing this resets the detector, so a half-finished tap from before
    /// the recording does not complete afterwards.
    var isSuspended = false {
        didSet {
            guard isSuspended != oldValue, !isSuspended else { return }
            detector.reset(held: Set(modifierFlags: NSEvent.modifierFlags))
        }
    }

    private init() {}

    /// Register `modifier`. Nil when that modifier is already taken — the popup
    /// hotkey and Screenshot Text cannot both listen for ⌘⌘.
    /// The first registration installs both monitors.
    func add(_ modifier: ModifierKey, onFired: @escaping () -> Void) -> HotKeyRegistration? {
        guard handlers[modifier] == nil else {
            Self.log.warn("double-tap \(modifier.glyph)\(modifier.glyph) is already registered")
            return nil
        }
        let token = UUID()
        let first = handlers.isEmpty
        handlers[modifier] = Handler(token: token, onFired: onFired)
        if first { installMonitors() }
        Self.log.info("registered double-tap \(modifier.glyph)\(modifier.glyph)")
        return DoubleTapRegistration(modifier: modifier, token: token)
    }

    /// Put the global monitor back in place.
    ///
    /// Without authorization, key events sent to other apps are not delivered.
    /// After authorization an already installed monitor is not guaranteed to
    /// start receiving events, so we re-install. Called when the grant goes
    /// from missing to present.
    ///
    /// No registered handlers: do nothing. Otherwise remove the global monitor
    /// if one is installed, call `addGlobalMonitorForEvents` again, reset the
    /// detector to the modifiers held right now, and write a log line.
    func reinstallGlobalMonitor() {
        guard !handlers.isEmpty else { return }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mask) { [weak self] event in
            self?.handle(event)
        }
        detector.reset(held: Set(modifierFlags: NSEvent.modifierFlags))
        Self.log.info("reinstalled double-tap global monitor")
        if globalMonitor == nil {
            Self.log.warn("global double-tap monitor was not installed")
        }
    }

    fileprivate func remove(_ modifier: ModifierKey, token: UUID) {
        guard handlers[modifier]?.token == token else { return }
        handlers[modifier] = nil
        Self.log.info("unregistered double-tap \(modifier.glyph)\(modifier.glyph)")
        if handlers.isEmpty { removeMonitors() }
    }

    // MARK: - Monitors

    private func installMonitors() {
        // A modifier already held when we start listening is not a press.
        detector.reset(held: Set(modifierFlags: NSEvent.modifierFlags))
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mask) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.mask) { [weak self] event in
            self?.handle(event)
            return event   // never swallow: the front app keeps the key
        }
        Self.log.info("installed double-tap monitors")
        if globalMonitor == nil {
            Self.log.warn("global double-tap monitor was not installed")
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        detector.reset(held: [])
        Self.log.info("removed double-tap monitors")
    }

    // MARK: - Events (main thread)

    private func handle(_ event: NSEvent) {
        // The synthetic ⌘C / keystroke we post ourselves. Same check as
        // `GlobalInputMonitor`: that key is ours, not the user's, so it must
        // not cancel a tap or count as one.
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == KeySender.syntheticUserData {
            return
        }
        if isSuspended { return }

        let time = event.timestamp
        let fired: ModifierKey?
        switch event.type {
        case .flagsChanged where event.isFnOrCapsLockChange:
            detector.otherKey(time: time)
            fired = nil
        case .flagsChanged:
            fired = detector.flagsChanged(held: Set(modifierFlags: event.modifierFlags), time: time)
        case .keyDown:
            detector.otherKey(time: time)
            fired = nil
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            detector.mouseDown(time: time)
            fired = nil
        case .scrollWheel:
            detector.scroll(time: time)
            fired = nil
        default:
            return
        }
        if let fired, let onFired = handlers[fired]?.onFired {
            // Run the action after this event finishes dispatching. Screenshot
            // Text's full-screen selection window must not be created while
            // this flagsChanged is still being dispatched.
            DispatchQueue.main.async { onFired() }
        }
    }
}

/// One `add` call. `invalidate` drops it; dropping the last one removes both
/// monitors. A second `invalidate` (the `deinit`) does nothing, and a stale
/// one does not remove a newer registration of the same modifier — the token
/// has to match.
private final class DoubleTapRegistration: HotKeyRegistration {
    private let modifier: ModifierKey
    private var token: UUID?

    init(modifier: ModifierKey, token: UUID) {
        self.modifier = modifier
        self.token = token
    }

    func invalidate() {
        guard let token else { return }
        self.token = nil
        ModifierDoubleTapMonitor.shared.remove(modifier, token: token)
    }

    deinit { invalidate() }
}
