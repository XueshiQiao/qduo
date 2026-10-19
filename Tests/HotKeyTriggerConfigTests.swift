import XCTest

/// `HotKeyTrigger` as a person types it into the config file. A modifier named
/// twice is a double tap; everything else is still a `KeyCombo`.
final class HotKeyTriggerConfigTests: XCTestCase {

    func testDoubleTapRoundTripForAllFourModifiers() throws {
        let cases: [(String, ModifierKey, String)] = [
            ("cmd+cmd", .command, "⌘⌘"),
            ("ctrl+ctrl", .control, "⌃⌃"),
            ("opt+opt", .option, "⌥⌥"),
            ("shift+shift", .shift, "⇧⇧"),
        ]
        for (raw, key, display) in cases {
            let trigger = try XCTUnwrap(HotKeyTrigger(configString: raw), raw)
            XCTAssertEqual(trigger, .doubleTap(key), raw)
            XCTAssertEqual(trigger.display, display, raw)
            XCTAssertEqual(trigger.configString, raw, raw)
            let roundTrip = try XCTUnwrap(HotKeyTrigger(configString: trigger.configString), raw)
            XCTAssertEqual(roundTrip, trigger, raw)
        }
    }

    func testModifierAliases() throws {
        let command = try XCTUnwrap(HotKeyTrigger(configString: "command+command"))
        XCTAssertEqual(command, .doubleTap(.command))
        XCTAssertEqual(command.configString, "cmd+cmd")
        XCTAssertEqual(command.display, "⌘⌘")

        let aliases: [(String, ModifierKey)] = [
            ("⌘+⌘", .command),
            ("meta+meta", .command),
            ("alt+alt", .option),
            ("control+control", .control),
            ("ctrl+control", .control),
            ("cmd + cmd", .command),
            ("CMD-CMD", .command),
            ("⇧+⇧", .shift),
        ]
        for (raw, key) in aliases {
            XCTAssertEqual(try XCTUnwrap(HotKeyTrigger(configString: raw), raw), .doubleTap(key), raw)
        }
    }

    func testCmdCmdSStaysACombo() throws {
        let trigger = try XCTUnwrap(HotKeyTrigger(configString: "cmd+cmd+s"))
        let combo = try XCTUnwrap(KeyCombo(configString: "cmd+s"))
        XCTAssertEqual(trigger, .combo(combo))
        XCTAssertEqual(trigger.display, "⌘S")
        XCTAssertEqual(trigger.configString, "cmd+s")
    }

    func testStringsThatAreNotADoubleTapOrACombo() {
        for raw in ["cmd+shift", "cmd", "", "ctrl*2", "double+ctrl"] {
            XCTAssertNil(HotKeyTrigger(configString: raw), raw)
        }
    }

    /// An older build only has `KeyCombo`. `"cmd+cmd"` is nil there, so
    /// `popup.hotKey` becomes unset and `ocr.hotKey` falls back to ⌘⇧S
    /// (`KeyCombo(configString:) ?? .defaultScreenOCR`).
    func testOldKeyComboParserRejectsADoubleTap() {
        for raw in ["cmd+cmd", "ctrl+ctrl", "opt+opt", "shift+shift"] {
            XCTAssertNil(KeyCombo(configString: raw), raw)
            XCTAssertNil(KeyCombo(strictConfigString: raw), raw)
        }
    }

    func testADoubleTapIsNotAnyCombo() throws {
        let tap = HotKeyTrigger.doubleTap(.command)
        XCTAssertNotEqual(tap, .combo(.defaultScreenOCR))
        for name in ["cmd+c", "cmd+cmd+s", "shift+cmd+s", "s", "ctrl+opt+shift+cmd+k"] {
            let combo = try XCTUnwrap(KeyCombo(configString: name), name)
            XCTAssertNotEqual(tap, .combo(combo), name)
        }
    }

}
