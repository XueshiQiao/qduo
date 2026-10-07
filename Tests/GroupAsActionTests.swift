import XCTest

/// A group is an action too (issue #16): what counts as a group, what may be
/// dropped into it, and what the config file says.
final class GroupAsActionTests: XCTestCase {

    private func action(_ id: String, _ kind: PopBarActionConfig.Kind = .copy,
                        children: [PopBarActionConfig] = [], marked: Bool = false) -> PopBarActionConfig {
        var a = PopBarActionConfig(id: id, title: id, iconSymbol: "star", kind: kind)
        a.children = children
        if marked { a.marksGroup = true }
        return a
    }

    func testWhatCountsAsAGroup() {
        XCTAssertTrue(action("g", .group).isGroup)
        XCTAssertFalse(action("g", .group).isGroupThatRuns)
        XCTAssertTrue(action("g", .ai, children: [action("c")]).isGroupThatRuns)
        XCTAssertTrue(action("g", .ai, marked: true).isGroupThatRuns)
        XCTAssertFalse(action("a", .ai).isGroup)
    }

    func testActionsDropIntoAGroupOfAnyKind() {
        let list = [action("plain"), action("empty", .group), action("runs", .ai, children: [action("c")]),
                    action("marked", .speak, marked: true), action("x")]
        for group in ["empty", "runs", "marked"] {
            XCTAssertTrue(ActionTree.canMove("x", to: .insideBefore(groupID: group, childID: nil), in: list), group)
        }
        XCTAssertFalse(ActionTree.canMove("x", to: .insideBefore(groupID: "plain", childID: nil), in: list))
    }

    func testAGroupNeverGoesInsideAGroup() {
        let list = [action("empty", .group), action("runs", .ai, children: [action("c")]),
                    action("marked", .speak, marked: true)]
        for moving in ["runs", "marked"] {
            XCTAssertFalse(ActionTree.canMove(moving, to: .insideBefore(groupID: "empty", childID: nil), in: list), moving)
        }
    }

    func testTheListShowsEveryGroupAsOne() {
        let rows = ActionTree.flatten([action("plain"), action("runs", .ai, children: [action("c")]),
                                       action("marked", .speak, marked: true)])
        XCTAssertEqual(rows.map(\.isGroup), [false, true, false, true])
        XCTAssertEqual(rows.map(\.parentID), [nil, nil, "runs", nil])
    }

    func testEditingAGroupKeepsItsChildren() {
        let list = [action("g", .group, children: [action("c1"), action("c2")])]
        var edited = action("g", .ai)          // the editor's copy: a new kind, stale (no) children
        edited.prompt = "p"
        let out = ActionTree.update(edited, in: list)
        XCTAssertEqual(out?.first?.kind, .ai)
        XCTAssertEqual(out?.first?.children.map(\.id), ["c1", "c2"])
    }

    func testTheMarkIsWrittenOnlyWhenSet() throws {
        let json = #"[{ "id": "g", "title": "G", "iconSymbol": "star", "kind": "ai", "prompt": "p", "group": true },"#
                 + #" { "id": "a", "title": "A", "iconSymbol": "star", "kind": "copy" },"#
                 + #" { "id": "h", "title": "H", "iconSymbol": "star", "kind": "speak","#
                 + #"   "children": [{ "id": "c", "title": "C", "iconSymbol": "star", "kind": "copy" }] }]"#
        let actions = try JSONDecoder().decode([PopBarActionConfig].self, from: Data(json.utf8))
        XCTAssertEqual(actions.map(\.isGroup), [true, false, true])
        XCTAssertEqual(actions[2].kind, .speak)
        let written = String(decoding: try JSONEncoder().encode(actions), as: UTF8.self)
        XCTAssertEqual(written.components(separatedBy: "\"group\":true").count - 1, 1)
        let again = try JSONDecoder().decode([PopBarActionConfig].self, from: Data(written.utf8))
        XCTAssertEqual(again, actions)
    }
}
