import Carbon.HIToolbox   // kVK_* virtual key codes + cmdKey/shiftKey/optionKey/controlKey masks
import CoreGraphics       // CGEventFlags, for the flags a real key-down carries

/// A single keyboard shortcut: a virtual key code plus a Carbon modifier bitmask.
///
/// Stored in the exact shape `RegisterEventHotKey` wants, so a `KeyCombo` can be
/// handed straight to `GlobalHotKey` without translation. `display` renders it
/// for the UI without touching any main-thread-only TIS API (see `keyGlyphs`).
struct KeyCombo: Codable, Equatable {

    /// Virtual key code, e.g. `UInt32(kVK_ANSI_S) == 1`.
    var keyCode: UInt32
    /// Bitmask of `cmdKey`(256) | `shiftKey`(512) | `optionKey`(2048) | `controlKey`(4096).
    var carbonModifiers: UInt32

    /// Human display like `"⌘⇧S"`. Modifier glyph order is fixed: ⌃ ⌥ ⇧ ⌘,
    /// followed by the key glyph.
    var display: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { result += "⌘" }
        result += Self.keyGlyphs[keyCode] ?? "Key \(keyCode)"
        return result
    }

    /// The flags a physical key-down of this combo carries, for `CGEvent`.
    ///
    /// Carbon's modifier bits become the matching `CGEventFlags`. Some more
    /// flags are not modifiers the user held. Arrow keys are virtual keys
    /// 123–126, which belong to the keypad, and a real keyboard sets both the
    /// numeric-pad flag and the secondary-fn flag when it sends them. The
    /// numeric keypad itself — 0–9, decimal, plus, minus, multiply, divide,
    /// equals, clear and enter — carries the numeric-pad flag only. Forward
    /// delete (117), home (115), end (119), page up (116), page down (121)
    /// and help are the same cluster as the arrows and carry secondary-fn,
    /// not the numeric-pad flag. A terminal or an editor that checks those
    /// flags ignores a synthetic key that arrives without them, so the flags
    /// are added to match the key a person would have pressed.
    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if carbonModifiers & UInt32(cmdKey)     != 0 { flags.insert(.maskCommand) }
        if carbonModifiers & UInt32(shiftKey)   != 0 { flags.insert(.maskShift) }
        if carbonModifiers & UInt32(optionKey)  != 0 { flags.insert(.maskAlternate) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        switch keyCode {
        case UInt32(kVK_LeftArrow), UInt32(kVK_RightArrow), UInt32(kVK_DownArrow), UInt32(kVK_UpArrow):
            flags.insert(.maskSecondaryFn)
            flags.insert(.maskNumericPad)
        case UInt32(kVK_ForwardDelete), UInt32(kVK_Home), UInt32(kVK_End),
             UInt32(kVK_PageUp), UInt32(kVK_PageDown), UInt32(kVK_Help):
            flags.insert(.maskSecondaryFn)
        case UInt32(kVK_ANSI_Keypad0), UInt32(kVK_ANSI_Keypad1), UInt32(kVK_ANSI_Keypad2),
             UInt32(kVK_ANSI_Keypad3), UInt32(kVK_ANSI_Keypad4), UInt32(kVK_ANSI_Keypad5),
             UInt32(kVK_ANSI_Keypad6), UInt32(kVK_ANSI_Keypad7), UInt32(kVK_ANSI_Keypad8),
             UInt32(kVK_ANSI_Keypad9), UInt32(kVK_ANSI_KeypadDecimal), UInt32(kVK_ANSI_KeypadPlus),
             UInt32(kVK_ANSI_KeypadMinus), UInt32(kVK_ANSI_KeypadMultiply), UInt32(kVK_ANSI_KeypadDivide),
             UInt32(kVK_ANSI_KeypadEquals), UInt32(kVK_ANSI_KeypadClear), UInt32(kVK_ANSI_KeypadEnter):
            flags.insert(.maskNumericPad)
        default:
            break
        }
        return flags
    }

    /// Default trigger for Screenshot OCR: ⌘⇧S.
    static let defaultScreenOCR = KeyCombo(keyCode: UInt32(kVK_ANSI_S),
                                           carbonModifiers: UInt32(cmdKey | shiftKey))

    // MARK: - Key glyph table

    /// Static virtual-key-code → glyph map. Deliberately a plain dictionary: it
    /// avoids `TISCopyCurrentKeyboardInputSource` (main-thread-only), so `display`
    /// is safe to read from any thread. Unlisted codes fall back to `"Key <n>"`.
    private static let keyGlyphs: [UInt32: String] = [
        // Letters A–Z (uppercase).
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",

        // Digits 0–9.
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",

        // The punctuation row. The written names live in KeyCombo+Config;
        // these are only what the UI draws.
        UInt32(kVK_ANSI_Minus): "-",
        UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_LeftBracket): "[",
        UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_Backslash): "\\",
        UInt32(kVK_ANSI_Semicolon): ";",
        UInt32(kVK_ANSI_Quote): "'",
        UInt32(kVK_ANSI_Comma): ",",
        UInt32(kVK_ANSI_Period): ".",
        UInt32(kVK_ANSI_Slash): "/",
        UInt32(kVK_ANSI_Grave): "`",

        // Numeric keypad, including enter. Short text, the same idea as "F1".
        UInt32(kVK_ANSI_KeypadEnter): "⌤",
        UInt32(kVK_ANSI_Keypad0): "Num0", UInt32(kVK_ANSI_Keypad1): "Num1",
        UInt32(kVK_ANSI_Keypad2): "Num2", UInt32(kVK_ANSI_Keypad3): "Num3",
        UInt32(kVK_ANSI_Keypad4): "Num4", UInt32(kVK_ANSI_Keypad5): "Num5",
        UInt32(kVK_ANSI_Keypad6): "Num6", UInt32(kVK_ANSI_Keypad7): "Num7",
        UInt32(kVK_ANSI_Keypad8): "Num8", UInt32(kVK_ANSI_Keypad9): "Num9",
        UInt32(kVK_ANSI_KeypadDecimal): "Num.",
        UInt32(kVK_ANSI_KeypadPlus): "Num+",
        UInt32(kVK_ANSI_KeypadMinus): "Num-",
        UInt32(kVK_ANSI_KeypadMultiply): "Num*",
        UInt32(kVK_ANSI_KeypadDivide): "Num/",
        UInt32(kVK_ANSI_KeypadEquals): "Num=",
        UInt32(kVK_ANSI_KeypadClear): "⌧",

        // Editing / whitespace.
        UInt32(kVK_Space):  "Space",
        UInt32(kVK_Return): "↩",
        UInt32(kVK_Tab):    "⇥",
        UInt32(kVK_Escape): "⎋",
        UInt32(kVK_Delete): "⌫",
        UInt32(kVK_ForwardDelete): "⌦",

        // Arrows.
        UInt32(kVK_LeftArrow):  "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow):    "↑",
        UInt32(kVK_DownArrow):  "↓",

        // The cluster above the arrows on a full keyboard, plus Help.
        UInt32(kVK_Home): "↖",
        UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞",
        UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_Help): "Help",

        // Function keys F1–F20.
        UInt32(kVK_F1):  "F1",  UInt32(kVK_F2):  "F2",  UInt32(kVK_F3):  "F3",
        UInt32(kVK_F4):  "F4",  UInt32(kVK_F5):  "F5",  UInt32(kVK_F6):  "F6",
        UInt32(kVK_F7):  "F7",  UInt32(kVK_F8):  "F8",  UInt32(kVK_F9):  "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16", UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20",
    ]
}
