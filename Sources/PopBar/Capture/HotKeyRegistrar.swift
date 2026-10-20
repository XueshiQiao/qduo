import Foundation

/// A hotkey that can be turned off. A Carbon `GlobalHotKey` and a double-tap
/// registration both are: the popup and Screenshot Text keep one of these and
/// call `invalidate` when the setting changes.
protocol HotKeyRegistration: AnyObject {
    func invalidate()
}

/// Turns a `HotKeyTrigger` into the listener that can actually hear it.
/// A combo goes to Carbon (`RegisterEventHotKey`), which swallows the key. A
/// double tap goes to `ModifierDoubleTapMonitor`, which does not. Nil when the
/// combo is taken by another app, or that modifier is already registered here.
enum HotKeyRegistrar {
    static func register(_ trigger: HotKeyTrigger, onFired: @escaping () -> Void) -> HotKeyRegistration? {
        switch trigger {
        case .combo(let combo):
            return GlobalHotKey(combo: combo, onPressed: onFired)
        case .doubleTap(let modifier):
            return ModifierDoubleTapMonitor.shared.add(modifier, onFired: onFired)
        }
    }
}
