import XCTest

/// The schema is JSON written inside a Swift string, so every backslash is
/// escaped twice — once for Swift, once for JSON — and a slip there produces a
/// file no editor can read, with nothing in the app to notice (it only writes
/// the schema, never reads it). 26.09.16 shipped exactly that.
final class ConfigSchemaTests: XCTestCase {

    private func schema() throws -> [String: Any] {
        let data = try XCTUnwrap(ConfigSchema.json.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func pattern(_ section: String, _ key: String) throws -> NSRegularExpression {
        let properties = try XCTUnwrap(schema()["properties"] as? [String: Any])
        let group = try XCTUnwrap((properties[section] as? [String: Any])?["properties"] as? [String: Any])
        let raw = try XCTUnwrap((group[key] as? [String: Any])?["pattern"] as? String)
        return try NSRegularExpression(pattern: raw)
    }

    private func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    func testSchemaIsValidJSON() throws {
        XCTAssertNoThrow(try schema())
    }

    func testHotKeyPatternsAcceptWhatTheAppWrites() throws {
        let ocr = try pattern("ocr", "hotKey")
        XCTAssertTrue(matches(ocr, "shift+cmd+s"))
        XCTAssertFalse(matches(ocr, ""))

        let popup = try pattern("popup", "hotKey")
        XCTAssertTrue(matches(popup, "opt+x"))
        XCTAssertTrue(matches(popup, ""))          // none recorded yet
        XCTAssertFalse(matches(popup, "opt+"))
    }

    func testKeystrokeKindAndKeysPattern() throws {
        let definitions = try XCTUnwrap(schema()["definitions"] as? [String: Any])
        let action = try XCTUnwrap(definitions["action"] as? [String: Any])
        let properties = try XCTUnwrap(action["properties"] as? [String: Any])
        let kinds = try XCTUnwrap((properties["kind"] as? [String: Any])?["enum"] as? [String])
        XCTAssertTrue(kinds.contains("keystroke"))

        let raw = try XCTUnwrap((properties["keys"] as? [String: Any])?["pattern"] as? String)
        let regex = try NSRegularExpression(pattern: raw)
        XCTAssertTrue(matches(regex, "delete"))
        XCTAssertTrue(matches(regex, "shift+cmd+k"))
        XCTAssertFalse(matches(regex, ""))
        XCTAssertFalse(matches(regex, "cmd+"))
    }

    /// Every key name the schema tells a person they can type must be one
    /// `KeyCombo` can read. Ranges (`a-z`, `0-9`, `f1-f20`) are skipped; each
    /// single name is checked. The three lists are the same list.
    func testSchemaListedKeyNamesParse() throws {
        let lists = [
            listedKeyTokens(in: try sectionDescription("popup", "hotKey")),
            listedKeyTokens(in: try sectionDescription("ocr", "hotKey")),
            listedKeyTokens(in: try actionDescription("keys")),
        ]
        XCTAssertFalse(lists[0].isEmpty)
        XCTAssertEqual(lists[0], lists[1])
        XCTAssertEqual(lists[1], lists[2])

        let names = lists[0].filter { !$0.contains("-") }
        XCTAssertFalse(names.isEmpty)
        for required in ["space", "period", "grave", "keypadenter", "keypad0", "keypad9",
                         "keypaddecimal", "keypadclear", "help"] {
            XCTAssertTrue(names.contains(required), required)
        }
        for name in names {
            XCTAssertNotNil(KeyCombo(configString: name), name)
        }
    }

    private func sectionDescription(_ section: String, _ key: String) throws -> String {
        let properties = try XCTUnwrap(schema()["properties"] as? [String: Any])
        let group = try XCTUnwrap((properties[section] as? [String: Any])?["properties"] as? [String: Any])
        return try XCTUnwrap((group[key] as? [String: Any])?["description"] as? String)
    }

    private func actionDescription(_ key: String) throws -> String {
        let definitions = try XCTUnwrap(schema()["definitions"] as? [String: Any])
        let action = try XCTUnwrap(definitions["action"] as? [String: Any])
        let properties = try XCTUnwrap(action["properties"] as? [String: Any])
        return try XCTUnwrap((properties[key] as? [String: Any])?["description"] as? String)
    }

    /// The comma-separated key list after "Keys:", or after the popup hotkey's
    /// "key names as ocr.hotKey:". The list ends at the next sentence.
    private func listedKeyTokens(in description: String) -> [String] {
        let markers = ["Keys: ", "key names as ocr.hotKey: "]
        guard let marker = markers.first(where: { description.contains($0) }),
              let range = description.range(of: marker) else {
            return []
        }
        let tail = description[range.upperBound...]
        guard let list = tail.split(separator: ".", maxSplits: 1).first else { return [] }
        return list.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }
}
