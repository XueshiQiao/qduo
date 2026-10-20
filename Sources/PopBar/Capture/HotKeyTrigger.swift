import Foundation

/// One modifier key. Left and right are the same case: a double tap does not
/// care which side went down.
///
/// The AppKit flag (`NSEvent.ModifierFlags`) lives in an extension beside
/// `ModifierDoubleTapMonitor`, so this file stays free of AppKit and the unit
/// tests can compile it.
enum ModifierKey: String, CaseIterable {
    case control, option, shift, command

    /// The glyph drawn in the UI. A double tap shows it twice (`⌘⌘`).
    var glyph: String {
        switch self {
        case .control: return "⌃"
        case .option:  return "⌥"
        case .shift:   return "⇧"
        case .command: return "⌘"
        }
    }

    /// The name written in the config file: `ctrl` / `opt` / `shift` / `cmd`.
    var configName: String {
        switch self {
        case .control: return "ctrl"
        case .option:  return "opt"
        case .shift:   return "shift"
        case .command: return "cmd"
        }
    }

    /// The same aliases `KeyCombo`'s parser accepts for one modifier.
    fileprivate init?(configToken token: String) {
        switch token {
        case "ctrl", "control", "⌃":        self = .control
        case "opt", "option", "alt", "⌥":   self = .option
        case "shift", "⇧":                  self = .shift
        case "cmd", "command", "meta", "⌘": self = .command
        default:                            return nil
        }
    }
}

/// What a popup hotkey or a Screenshot Text hotkey listens for.
///
/// A key combination is today's Carbon hotkey (`RegisterEventHotKey`). A double
/// tap is the same modifier pressed twice (`⌘⌘`), which Carbon cannot register,
/// so it is heard by `ModifierDoubleTapMonitor` instead. `KeyCombo` itself is
/// unchanged: an older build reads `"cmd+cmd"` as no key. `popup.hotKey` becomes
/// unset, and `ocr.hotKey` falls back to ⌘⇧S. The old getter is
/// `KeyCombo(configString:) ?? .defaultScreenOCR`.
enum HotKeyTrigger: Equatable {
    case combo(KeyCombo)
    case doubleTap(ModifierKey)

    /// `⌘⇧S` for a combo, `⌘⌘` for a double tap of command.
    var display: String {
        switch self {
        case .combo(let combo):     return combo.display
        case .doubleTap(let key):   return key.glyph + key.glyph
        }
    }

    /// `"shift+cmd+s"` for a combo, `"cmd+cmd"` for a double tap of command.
    var configString: String {
        switch self {
        case .combo(let combo):   return combo.configString
        case .doubleTap(let key): return "\(key.configName)+\(key.configName)"
        }
    }

    /// Parse a config value.
    ///
    /// Exactly two tokens that name the SAME modifier (`"cmd+cmd"`,
    /// `"command+command"`, `"⌘+⌘"`) is a double tap. Anything else is handed to
    /// `KeyCombo`, so `"cmd+cmd+s"` stays ⌘S. `"cmd+shift"`, `"cmd"`, `""`,
    /// `"ctrl*2"` and `"double+ctrl"` are nil — there is no key, and the two
    /// tokens are not one modifier twice.
    init?(configString raw: String) {
        let tokens = raw
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .split(whereSeparator: { $0 == "+" || $0 == "-" })
            .map(String.init)
        if tokens.count == 2,
           let first = ModifierKey(configToken: tokens[0]),
           let second = ModifierKey(configToken: tokens[1]),
           first == second {
            self = .doubleTap(first)
            return
        }
        guard let combo = KeyCombo(configString: raw) else { return nil }
        self = .combo(combo)
    }
}
