import XCTest

/// The actions live in the same hand-editable config file as everything else, and
/// the same promise applies to them: a key this build does not recognise must
/// still be there after the app rewrites the list.
///
/// The rest of the file keeps unknown keys by being held as a JSON tree. An action
/// is not — it is decoded into `PopBarActionConfig` — so it needs its own
/// mechanism, and this is what checks that the mechanism works.
final class ActionRoundTripTests: XCTestCase {

    private func roundTrip(_ json: String) throws -> JSONValue {
        let actions = try JSONDecoder().decode([PopBarActionConfig].self, from: Data(json.utf8))
        let data = try JSONEncoder().encode(actions)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func testAnUnknownKeyOnAnActionSurvivesBeingRewritten() throws {
        let out = try roundTrip("""
        [{
          "id": "a1", "title": "Copy", "iconSymbol": "doc.on.doc", "kind": "copy",
          "prompt": "",
          "_note": "written by hand",
          "futureField": { "nested": [1, 2, 3] }
        }]
        """)

        XCTAssertEqual(out.arrayValue?.count, 1)
        let action = try XCTUnwrap(out.arrayValue?.first)
        XCTAssertEqual(action[path: "title"]?.stringValue, "Copy")
        XCTAssertEqual(action[path: "_note"]?.stringValue, "written by hand",
                       "a hand-written key on an action was dropped when the list was rewritten")
        XCTAssertEqual(action[path: "futureField.nested"]?.arrayValue?.count, 3)
    }

    func testAnUnknownKeyOnAChildActionSurvivesToo() throws {
        let out = try roundTrip("""
        [{
          "id": "g1", "title": "Group", "iconSymbol": "square.grid.2x2", "kind": "group",
          "prompt": "",
          "children": [
            { "id": "c1", "title": "Child", "iconSymbol": "sparkles", "kind": "ai",
              "prompt": "hi", "_note": "also by hand" }
          ]
        }]
        """)

        let child = try XCTUnwrap(out.arrayValue?.first?[path: "children"]?.arrayValue?.first)
        XCTAssertEqual(child[path: "title"]?.stringValue, "Child")
        XCTAssertEqual(child[path: "_note"]?.stringValue, "also by hand")
    }

    func testAnUnknownKindIsWrittenBackUnchanged() throws {
        // The reason this mechanism exists at all: an older build must not turn a
        // newer build's action into a plain AI action on its next save.
        let out = try roundTrip("""
        [{ "id": "x", "title": "From the future", "iconSymbol": "star",
           "kind": "teleport", "prompt": "" }]
        """)
        XCTAssertEqual(out.arrayValue?.first?[path: "kind"]?.stringValue, "teleport")
    }

    func testAKnownFieldIsNeverShadowedByAStrayExtra() throws {
        // If a decode ever let a known name into `extra`, encoding it again would
        // write the key twice. Belt and braces: the title must be the real one.
        let out = try roundTrip("""
        [{ "id": "a", "title": "Real", "iconSymbol": "doc", "kind": "copy", "prompt": "" }]
        """)
        XCTAssertEqual(out.arrayValue?.first?[path: "title"]?.stringValue, "Real")
    }

    func testAnEmptyListRoundTripsAsEmpty() throws {
        // Emptying the list is a decision a person can make; it must not come back
        // as something else.
        XCTAssertEqual(try roundTrip("[]").arrayValue?.count, 0)
    }
}

/// The app's localized-string helper, which this file's `DefaultActions` calls.
/// The test target compiles the source file directly rather than hosting the app,
/// so the helper has to exist here; the titles it returns do not matter to these
/// tests.
func L(_ key: String) -> String { key }
