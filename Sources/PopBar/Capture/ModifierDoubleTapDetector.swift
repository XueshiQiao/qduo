import Foundation

/// Decides when one modifier key has been pressed twice.
///
/// Pure state: the monitor translates `NSEvent` into the four inputs below, and
/// this struct only sees ctrl / opt / shift / cmd. Left and right are already
/// folded together by that translation, so a left ⌘ that is still held while
/// the right ⌘ goes down does not change the set and is not a second press.
///
/// The window is measured from the first key-down to the second key-down. The
/// first press has to be released before the second one counts, and the tap
/// fires on that second key-down. A key, a click or a scroll in between cancels
/// it. Foundation only, so the unit tests can feed it timestamps.
struct ModifierDoubleTapDetector {

    static let defaultWindow: TimeInterval = 0.3

    /// How long the second press may arrive after the first. `<=` this fires.
    let window: TimeInterval

    /// Modifiers that were down at the previous `flagsChanged`.
    private var heldBefore: Set<ModifierKey>
    /// The modifier that went down, and when, if a tap is in progress.
    private var pending: (key: ModifierKey, t0: TimeInterval)?
    /// The pending key has been released since it went down. The second press
    /// only counts after that, so holding the key does not fire.
    private var pendingReleased = false
    /// Timestamp of the last `flagsChanged` we applied. Only defensive: the
    /// global monitor only sees events sent to other apps, and the local
    /// monitor only events sent to this app, so one event never arrives on
    /// both. An event with the same timestamp is processed once. Nil until the
    /// first event, so a timestamp of 0 is a real event.
    private var lastTimestamp: TimeInterval?

    init(window: TimeInterval = defaultWindow, held: Set<ModifierKey> = []) {
        self.window = window
        self.heldBefore = held
    }

    /// Forget any tap in progress and treat `held` as what is down right now.
    /// The monitor does this when it starts, and again when recording ends, so
    /// a key that was already down is not read as a fresh press.
    mutating func reset(held: Set<ModifierKey>) {
        heldBefore = held
        pending = nil
        pendingReleased = false
        lastTimestamp = nil
    }

    /// The set of ctrl / opt / shift / cmd that are down now.
    /// Returns the modifier when this call is the second press of a tap.
    mutating func flagsChanged(held now: Set<ModifierKey>, time t: TimeInterval) -> ModifierKey? {
        if t == lastTimestamp { return nil }
        lastTimestamp = t

        let pressed = now.subtracting(heldBefore)
        let released = heldBefore.subtracting(now)
        heldBefore = now

        if !pressed.isEmpty {
            // Two modifiers down together is a chord, not a double tap.
            if now.count > 1 {
                pending = nil
                pendingReleased = false
                return nil
            }
            // `now` holds one modifier, and it is the one that just went down.
            guard let m = pressed.first else { return nil }
            if let pending, pending.key == m, pendingReleased, t - pending.t0 <= window {
                self.pending = nil
                pendingReleased = false
                return m
            } else {
                pending = (m, t)
                pendingReleased = false
                return nil
            }
        } else if let pending, released.contains(pending.key) {
            pendingReleased = true
        }
        return nil
    }

    /// A key that is not ctrl / opt / shift / cmd. Fn and Caps Lock arrive here
    /// too: the monitor turns those `.flagsChanged` events into this call.
    /// `time` is the event's timestamp; the tap is cancelled whatever it is.
    mutating func otherKey(time _: TimeInterval) {
        cancel()
    }

    mutating func mouseDown(time _: TimeInterval) {
        cancel()
    }

    mutating func scroll(time _: TimeInterval) {
        cancel()
    }

    private mutating func cancel() {
        pending = nil
        pendingReleased = false
    }
}
