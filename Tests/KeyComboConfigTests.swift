import XCTest
import CoreGraphics
import Carbon.HIToolbox

/// `KeyCombo` as a person types it into the config file: names, aliases, the
/// stable written form, and the flags a real key-down of that key carries.
final class KeyComboConfigTests: XCTestCase {

    func testDeleteAndItsAliasesAreBackspaceWithNoModifiers() throws {
        for name in ["delete", "backspace", "del"] {
            let combo = try XCTUnwrap(KeyCombo(configString: name), name)
            XCTAssertEqual(combo.keyCode, 51, name)
            XCTAssertEqual(combo.carbonModifiers, 0, name)
        }
        XCTAssertEqual(try XCTUnwrap(KeyCombo(configString: "delete")).display, "⌫")
        XCTAssertEqual(try XCTUnwrap(KeyCombo(configString: "backspace")).configString, "delete")
        XCTAssertEqual(try XCTUnwrap(KeyCombo(configString: "del")).configString, "delete")
    }

    func testNavigationKeysHaveTheDocumentedCodes() throws {
        let expected: [(String, UInt32)] = [
            ("forwarddelete", 117), ("fwddelete", 117),
            ("home", 115), ("end", 119), ("pageup", 116), ("pagedown", 121),
        ]
        for (name, code) in expected {
            let combo = try XCTUnwrap(KeyCombo(configString: name), name)
            XCTAssertEqual(combo.keyCode, code, name)
            XCTAssertEqual(combo.carbonModifiers, 0, name)
        }
        XCTAssertEqual(try XCTUnwrap(KeyCombo(configString: "fwddelete")).configString, "forwarddelete")
    }

    func testNewKeysDisplayAsGlyphs() throws {
        let glyphs = [
            "forwarddelete": "⌦",
            "home": "↖",
            "end": "↘",
            "pageup": "⇞",
            "pagedown": "⇟",
        ]
        for (name, glyph) in glyphs {
            let display = try XCTUnwrap(KeyCombo(configString: name), name).display
            XCTAssertEqual(display, glyph, name)
            XCTAssertFalse(display.contains("Key "), name)
        }
        XCTAssertEqual(try XCTUnwrap(KeyCombo(configString: "f13")).display, "F13")
        XCTAssertEqual(try XCTUnwrap(KeyCombo(configString: "f20")).display, "F20")
        XCTAssertEqual(try XCTUnwrap(KeyCombo(configString: "f13")).keyCode, UInt32(kVK_F13))
        XCTAssertEqual(try XCTUnwrap(KeyCombo(configString: "f20")).keyCode, UInt32(kVK_F20))
    }

    func testEveryCanonicalNameRoundTrips() throws {
        var names = "abcdefghijklmnopqrstuvwxyz".map { String($0) }
        names += (0..<10).map { String($0) }
        names += (1...20).map { "f\($0)" }
        names += ["space", "return", "tab", "escape", "delete",
                  "forwarddelete", "home", "end", "pageup", "pagedown",
                  "left", "right", "up", "down",
                  "minus", "equal", "leftbracket", "rightbracket", "backslash",
                  "semicolon", "quote", "comma", "period", "slash", "grave",
                  "keypadenter",
                  "keypad0", "keypad1", "keypad2", "keypad3", "keypad4",
                  "keypad5", "keypad6", "keypad7", "keypad8", "keypad9",
                  "keypaddecimal", "keypadplus", "keypadminus", "keypadmultiply",
                  "keypaddivide", "keypadequals", "keypadclear",
                  "help"]
        for name in names {
            let combo = try XCTUnwrap(KeyCombo(configString: name), name)
            XCTAssertEqual(combo.configString, name)
            XCTAssertFalse(combo.display.hasPrefix("Key "), name)
        }
    }

    func testPunctuationKeysRoundTripAndDisplayTheirGlyph() throws {
        let keys: [(name: String, code: UInt32, glyph: String)] = [
            ("minus", UInt32(kVK_ANSI_Minus), "-"),
            ("equal", UInt32(kVK_ANSI_Equal), "="),
            ("leftbracket", UInt32(kVK_ANSI_LeftBracket), "["),
            ("rightbracket", UInt32(kVK_ANSI_RightBracket), "]"),
            ("backslash", UInt32(kVK_ANSI_Backslash), "\\"),
            ("semicolon", UInt32(kVK_ANSI_Semicolon), ";"),
            ("quote", UInt32(kVK_ANSI_Quote), "'"),
            ("comma", UInt32(kVK_ANSI_Comma), ","),
            ("period", UInt32(kVK_ANSI_Period), "."),
            ("slash", UInt32(kVK_ANSI_Slash), "/"),
            ("grave", UInt32(kVK_ANSI_Grave), "`"),
            ("keypadenter", UInt32(kVK_ANSI_KeypadEnter), "⌤"),
        ]
        for key in keys {
            let combo = try XCTUnwrap(KeyCombo(configString: key.name), key.name)
            XCTAssertEqual(combo.configString, key.name, key.name)
            XCTAssertEqual(combo.keyCode, key.code, key.name)
            XCTAssertEqual(combo.carbonModifiers, 0, key.name)
            XCTAssertEqual(combo.display, key.glyph, key.name)
            XCTAssertFalse(combo.display.contains("Key "), key.name)
        }

        let comma = try XCTUnwrap(KeyCombo(configString: "cmd+comma"))
        XCTAssertEqual(comma.keyCode, 43)
        XCTAssertEqual(comma.carbonModifiers, UInt32(cmdKey))
        XCTAssertEqual(comma.configString, "cmd+comma")
        XCTAssertEqual(comma.display, "⌘,")
    }

    func testModifierOrderIsCtrlOptShiftCmdThenTheKey() throws {
        XCTAssertEqual(try XCTUnwrap(KeyCombo(configString: "cmd+shift+k")).configString, "shift+cmd+k")
        XCTAssertEqual(try XCTUnwrap(KeyCombo(configString: "cmd+opt+ctrl+a")).configString, "ctrl+opt+cmd+a")
    }

    func testUnusableStringsAreNil() {
        for raw in ["", "cmd+", "cmd+bogus", "cmd+a, cmd+c"] {
            XCTAssertNil(KeyCombo(configString: raw), raw)
            XCTAssertNil(KeyCombo(strictConfigString: raw), raw)
        }
    }

    /// A hotkey keeps the old "last key wins" reading. A keystroke does not:
    /// two keys in one combo are not a combination.
    func testStrictConfigStringRequiresExactlyOneKey() throws {
        XCTAssertNil(KeyCombo(strictConfigString: "cmd+a+c"))
        let lenient = try XCTUnwrap(KeyCombo(configString: "cmd+a+c"))
        XCTAssertEqual(lenient.display, "⌘C")
        XCTAssertEqual(lenient.keyCode, UInt32(kVK_ANSI_C))
        XCTAssertEqual(lenient.carbonModifiers, UInt32(cmdKey))

        let strict = try XCTUnwrap(KeyCombo(strictConfigString: "shift+cmd+k"))
        let loose = try XCTUnwrap(KeyCombo(configString: "shift+cmd+k"))
        XCTAssertEqual(strict, loose)
        // Spaces and the spoken aliases stay as tolerant as the original.
        XCTAssertEqual(KeyCombo(strictConfigString: "shift + command + k"), loose)
        XCTAssertEqual(KeyCombo(strictConfigString: "shift-cmd-k"), loose)
    }

    func testCGEventFlagsMatchWhatARealKeyboardSends() throws {
        let letter = try XCTUnwrap(KeyCombo(configString: "ctrl+opt+shift+cmd+k"))
        XCTAssertEqual(letter.cgEventFlags, [.maskControl, .maskAlternate, .maskShift, .maskCommand])
        XCTAssertEqual(try XCTUnwrap(KeyCombo(configString: "delete")).cgEventFlags, [])

        // Arrows are virtual keys 123–126 and carry both keypad flags.
        let arrows = [("left", UInt32(123)), ("right", UInt32(124)), ("down", UInt32(125)), ("up", UInt32(126))]
        for (name, code) in arrows {
            let combo = try XCTUnwrap(KeyCombo(configString: name), name)
            XCTAssertEqual(combo.keyCode, code, name)
            XCTAssertTrue(combo.cgEventFlags.contains(.maskSecondaryFn), name)
            XCTAssertTrue(combo.cgEventFlags.contains(.maskNumericPad), name)
        }
        let shifted = try XCTUnwrap(KeyCombo(configString: "shift+left"))
        XCTAssertEqual(shifted.cgEventFlags, [.maskShift, .maskSecondaryFn, .maskNumericPad])

        for name in ["forwarddelete", "home", "end", "pageup", "pagedown"] {
            let combo = try XCTUnwrap(KeyCombo(configString: name), name)
            XCTAssertTrue(combo.cgEventFlags.contains(.maskSecondaryFn), name)
            XCTAssertFalse(combo.cgEventFlags.contains(.maskNumericPad), name)
        }
        let help = try XCTUnwrap(KeyCombo(configString: "help"))
        XCTAssertEqual(help.keyCode, UInt32(kVK_Help))
        XCTAssertEqual(help.display, "Help")
        XCTAssertTrue(help.cgEventFlags.contains(.maskSecondaryFn))
        XCTAssertFalse(help.cgEventFlags.contains(.maskNumericPad))

        // Every numeric-keypad key, including enter, carries the numeric-pad
        // flag and not the secondary-fn flag the arrow cluster uses.
        let keypad = ["keypadenter", "keypad0", "keypad1", "keypad2", "keypad3", "keypad4",
                      "keypad5", "keypad6", "keypad7", "keypad8", "keypad9",
                      "keypaddecimal", "keypadplus", "keypadminus", "keypadmultiply",
                      "keypaddivide", "keypadequals", "keypadclear"]
        for name in keypad {
            let combo = try XCTUnwrap(KeyCombo(configString: name), name)
            XCTAssertEqual(combo.cgEventFlags, [.maskNumericPad], name)
        }
        let shiftedPad = try XCTUnwrap(KeyCombo(configString: "shift+keypad5"))
        XCTAssertEqual(shiftedPad.cgEventFlags, [.maskShift, .maskNumericPad])
    }

    func testKeypadKeysAndHelpDisplayAsShortGlyphs() throws {
        let keys: [(name: String, code: UInt32, glyph: String)] = [
            ("keypad0", UInt32(kVK_ANSI_Keypad0), "Num0"),
            ("keypad1", UInt32(kVK_ANSI_Keypad1), "Num1"),
            ("keypad2", UInt32(kVK_ANSI_Keypad2), "Num2"),
            ("keypad3", UInt32(kVK_ANSI_Keypad3), "Num3"),
            ("keypad4", UInt32(kVK_ANSI_Keypad4), "Num4"),
            ("keypad5", UInt32(kVK_ANSI_Keypad5), "Num5"),
            ("keypad6", UInt32(kVK_ANSI_Keypad6), "Num6"),
            ("keypad7", UInt32(kVK_ANSI_Keypad7), "Num7"),
            ("keypad8", UInt32(kVK_ANSI_Keypad8), "Num8"),
            ("keypad9", UInt32(kVK_ANSI_Keypad9), "Num9"),
            ("keypaddecimal", UInt32(kVK_ANSI_KeypadDecimal), "Num."),
            ("keypadplus", UInt32(kVK_ANSI_KeypadPlus), "Num+"),
            ("keypadminus", UInt32(kVK_ANSI_KeypadMinus), "Num-"),
            ("keypadmultiply", UInt32(kVK_ANSI_KeypadMultiply), "Num*"),
            ("keypaddivide", UInt32(kVK_ANSI_KeypadDivide), "Num/"),
            ("keypadequals", UInt32(kVK_ANSI_KeypadEquals), "Num="),
            ("keypadclear", UInt32(kVK_ANSI_KeypadClear), "⌧"),
            ("help", UInt32(kVK_Help), "Help"),
        ]
        for key in keys {
            let combo = try XCTUnwrap(KeyCombo(configString: key.name), key.name)
            XCTAssertEqual(combo.configString, key.name, key.name)
            XCTAssertEqual(combo.keyCode, key.code, key.name)
            XCTAssertEqual(combo.carbonModifiers, 0, key.name)
            XCTAssertEqual(combo.display, key.glyph, key.name)
            XCTAssertFalse(combo.display.hasPrefix("Key "), key.name)
        }
    }
}
