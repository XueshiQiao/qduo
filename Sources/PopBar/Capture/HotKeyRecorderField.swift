import SwiftUI
import AppKit
import Carbon.HIToolbox   // cmdKey/shiftKey/optionKey/controlKey, kVK_Escape

/// A click-to-record keyboard-shortcut field. Tapping it enters "recording".
///
/// Two modes, because a hotkey and a keystroke are not the same thing:
///
/// - `.hotKey` (the popup and Screenshot Text): the next key-down that has ⌘,
///   ⌥ or ⌃ becomes a key combination, and Esc cancels. A modifier pressed
///   twice (`⌘⌘`, and `⇧⇧` too) is recorded as a double tap. While this is
///   recording, the app's own double-tap monitor is suspended so it does not
///   fire the shortcut the user is in the middle of changing.
/// - `.keystroke` (a keystroke action): any key is recorded — ⌫, the arrows,
///   Return, Tab, Esc, a letter, shift+letter — and recording ends by clicking
///   the field again or by the window losing key. A double tap is never recorded.
struct HotKeyRecorderField: View {
    private enum Mode {
        case hotKey(HotKeyTrigger?, (HotKeyTrigger) -> Void)
        case keystroke(KeyCombo?, (KeyCombo) -> Void)
    }

    private let mode: Mode

    /// The popup and Screenshot Text recorders. `nil` shows "click to record".
    init(hotKey: HotKeyTrigger?, onRecorded: @escaping (HotKeyTrigger) -> Void) {
        mode = .hotKey(hotKey, onRecorded)
    }

    /// A keystroke action. Any one key, modifiers included. No double tap.
    init(combo: KeyCombo?, onRecorded: @escaping (KeyCombo) -> Void) {
        mode = .keystroke(combo, onRecorded)
    }

    @State private var isRecording = false
    @State private var monitor: Any?
    /// Only fed in `.hotKey`. Same window as the real monitor, so the gesture
    /// recorded here is the gesture that will later fire.
    @State private var doubleTap = ModifierDoubleTapDetector()

    var body: some View {
        Button {
            if isRecording { stopRecording() } else { startRecording() }
        } label: {
            Text(isRecording ? recordingPrompt : idleText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(isRecording ? Color.accentColor : Color.primary)
                .frame(minWidth: 100)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .overlay(
                    Capsule().strokeBorder(isRecording ? Color.accentColor
                                                        : Color.primary.opacity(0.15))
                )
                // The whole capsule must hit-test, not just the text glyph.
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onDisappear { stopRecording() }
        // Cancel recording if the window loses key focus (app switch, a sheet opening,
        // etc.) so the key monitor never keeps swallowing keystrokes in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if isRecording { stopRecording() }
        }
    }

    // MARK: - Recording lifecycle

    private func startRecording() {
        guard !isRecording, monitor == nil else { return }
        isRecording = true
        // A modifier already held when recording starts is not the first tap.
        doubleTap = ModifierDoubleTapDetector(held: Set(modifierFlags: NSEvent.modifierFlags))
        // Key-downs are swallowed so the shortcut being recorded does not also
        // type into the window. A flagsChanged is only looked at. A double tap
        // this app is listening for must not fire while recording is in
        // progress. Cleared in `stopRecording`, which is every way recording ends.
        ModifierDoubleTapMonitor.shared.isSuspended = true
        let mask: NSEvent.EventTypeMask = isHotKey ? [.keyDown, .flagsChanged] : [.keyDown]
        // A local monitor works without the Accessibility permission because the
        // settings window is key. Returning nil from a key-down swallows it.
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            handle(event)
        }
    }

    /// Tears down the local monitor and leaves recording state. Safe to call repeatedly.
    private func stopRecording() {
        let wasRecording = isRecording
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        if wasRecording {
            // Also resets the double-tap detector, so a tap that started before
            // recording does not complete on the next press.
            ModifierDoubleTapMonitor.shared.isSuspended = false
        }
    }

    private var isHotKey: Bool {
        if case .hotKey = mode { return true }
        return false
    }

    private var idleText: String {
        switch mode {
        case .hotKey(let trigger, _):
            return trigger?.display ?? L("popbar.hotkey.record")
        case .keystroke(let combo, _):
            return combo?.display ?? L("popbar.hotkey.record")
        }
    }

    /// "Press keys… (Esc to cancel)" only describes the hotkey field.
    /// A keystroke action records Esc, so its prompt says to click again.
    private var recordingPrompt: String {
        switch mode {
        case .hotKey:    return L("popbar.ocr.hotkey.recording")
        case .keystroke: return L("popbar.editor.keys.recording")
        }
    }

    /// Handles one event while recording. A key-down returns nil so it is
    /// swallowed. A flagsChanged in hotkey mode returns the event: detection
    /// only looks, it does not take the event over.
    private func handle(_ event: NSEvent) -> NSEvent? {
        switch mode {
        case .hotKey(_, let onRecorded):
            return handleHotKey(event, onRecorded: onRecorded)
        case .keystroke(_, let onRecorded):
            return handleKeystroke(event, onRecorded: onRecorded)
        }
    }

    private func handleHotKey(_ event: NSEvent, onRecorded: (HotKeyTrigger) -> Void) -> NSEvent? {
        if event.type == .flagsChanged {
            // ⇧⇧ is a double tap of shift, recorded from these events. A
            // shift+letter keyDown is still refused below: shift alone is not
            // a modifier a key combination accepts, so plain typing is not
            // captured. The two gestures are different.
            if let modifier = takeDoubleTap(event) {
                stopRecording()
                onRecorded(.doubleTap(modifier))
            }
            // Look only, including after a double tap was just recorded.
            return event
        }

        // Any key-down breaks a double tap in progress, including one we then
        // ignore (a bare letter) or record (⌘S).
        cancelDoubleTap(at: event.timestamp)

        let mask = carbonModifiers(from: event.modifierFlags)
        // Esc with no modifiers cancels recording.
        if event.keyCode == UInt16(kVK_Escape) && mask == 0 {
            stopRecording()
            return nil
        }

        // Require a "real" modifier (⌘/⌥/⌃); ignore bare keys and shift-only so plain
        // typing isn't captured. Keep waiting (swallow) until one arrives.
        let flags = event.modifierFlags
        let hasRealModifier = flags.contains(.command)
            || flags.contains(.option)
            || flags.contains(.control)
        guard hasRealModifier else { return nil }

        let recorded = KeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: mask)
        stopRecording()
        onRecorded(.combo(recorded))
        return nil
    }

    /// A keystroke records the key itself, Esc included. No double tap.
    private func handleKeystroke(_ event: NSEvent, onRecorded: (KeyCombo) -> Void) -> NSEvent? {
        guard event.type == .keyDown else { return event }
        let recorded = KeyCombo(keyCode: UInt32(event.keyCode),
                                carbonModifiers: carbonModifiers(from: event.modifierFlags))
        stopRecording()
        onRecorded(recorded)
        return nil
    }

    /// Feed one `.flagsChanged` to the private detector. Fn and Caps Lock are
    /// not modifiers; they cancel, the same way the real monitor does.
    private func takeDoubleTap(_ event: NSEvent) -> ModifierKey? {
        var detector = doubleTap
        let fired: ModifierKey?
        if event.isFnOrCapsLockChange {
            detector.otherKey(time: event.timestamp)
            fired = nil
        } else {
            fired = detector.flagsChanged(held: Set(modifierFlags: event.modifierFlags),
                                          time: event.timestamp)
        }
        doubleTap = detector
        return fired
    }

    private func cancelDoubleTap(at time: TimeInterval) {
        var detector = doubleTap
        detector.otherKey(time: time)
        doubleTap = detector
    }

    /// Maps AppKit modifier flags to the Carbon mask used by `KeyCombo`.
    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.shift)   { mask |= UInt32(shiftKey) }
        if flags.contains(.option)  { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }
}
