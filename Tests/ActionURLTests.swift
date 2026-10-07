import XCTest

/// Running an action from a URL (issue #15): what a URL may say, which action
/// it reaches, and the names actions go by.
final class ActionURLTests: XCTestCase {

    private func parse(_ string: String) -> ActionURL.Request? {
        URL(string: string).flatMap { ActionURL.parse($0, scheme: "qduo") }
    }

    func testAURLNamesAnActionAndCarriesText() {
        XCTAssertEqual(parse("qduo://run/translate?text=Hello%20world"),
                       ActionURL.Request(name: "translate", text: "Hello world"))
        XCTAssertEqual(parse("QDUO://RUN/Translate?text=a%0Ab")?.name, "translate")
        XCTAssertEqual(parse("qduo://run/translate?text=a%0Ab")?.text, "a\nb")
        XCTAssertEqual(parse("qduo://run/translate?text=%E4%BD%A0%E5%A5%BD")?.text, "你好")
    }

    func testAPlusIsAPlusAndTheFirstTextWins() {
        XCTAssertEqual(parse("qduo://run/translate?text=1+1")?.text, "1+1")
        XCTAssertEqual(parse("qduo://run/translate?text=a&text=b")?.text, "a")
    }

    func testMissingTextIsAnEmptyRequestNotAnInvalidURL() {
        XCTAssertEqual(parse("qduo://run/translate"), ActionURL.Request(name: "translate", text: ""))
        XCTAssertEqual(parse("qduo://run/translate?text=")?.text, "")
    }

    func testAnythingElseIsRefused() {
        for bad in ["other://run/translate?text=a", "qduo://open/translate?text=a", "qduo://run?text=a",
                    "qduo://run/a/b?text=a", "qduo://run/%E7%BF%BB%E8%AF%91?text=a", "qduo://run/-x?text=a",
                    "qduo-debug://run/translate?text=a"] {
            XCTAssertNil(parse(bad), bad)
        }
    }

    func testNames() {
        for good in ["a", "translate", "ask-chatgpt", "to_upper", "2nd"] { XCTAssertTrue(ActionURL.isValidName(good), good) }
        for bad in ["", "-a", "_a", "Translate", "a b", "翻译", "a/b", String(repeating: "a", count: 41)] {
            XCTAssertFalse(ActionURL.isValidName(bad), bad)
        }
        XCTAssertEqual(ActionURL.sanitized("Ask  ChatGPT!"), "ask-chatgpt")
        XCTAssertEqual(ActionURL.sanitized("翻译"), "")
        XCTAssertEqual(ActionURL.sanitized("--A_b"), "a_b")
    }

    func testSuggestedNameComesFromTheTitleThenTheKindAndIsUnique() {
        XCTAssertEqual(ActionURL.suggestedName(title: "Ask ChatGPT", kind: "openURL", taken: []), "ask-chatgpt")
        XCTAssertEqual(ActionURL.suggestedName(title: "翻译", kind: "ai", taken: []), "ai")
        XCTAssertEqual(ActionURL.suggestedName(title: "翻译", kind: "ai", taken: ["ai", "ai-2"]), "ai-3")
        XCTAssertEqual(ActionURL.suggestedName(title: "翻译", kind: "systemTranslate", taken: []), "systemtranslate")
        XCTAssertTrue(ActionURL.isValidName(ActionURL.suggestedName(title: "Copy -", kind: "copy", taken: [])))
        // A name already at the length limit still gets a valid, different one.
        let long = String(repeating: "a", count: 40)
        let next = ActionURL.suggestedName(title: long, kind: "ai", taken: [long])
        XCTAssertTrue(ActionURL.isValidName(next), next)
        XCTAssertNotEqual(next, long)
    }

    private func action(_ id: String, _ kind: PopBarActionConfig.Kind = .copy, url: String? = nil,
                        children: [PopBarActionConfig] = []) -> PopBarActionConfig {
        var a = PopBarActionConfig(id: id, title: id, iconSymbol: "star", kind: kind)
        a.urlName = url
        a.children = children
        return a
    }

    func testOnlyAnActionThatWasGivenANameIsReached() {
        let list = [action("plain"), action("named", url: "copy"),
                    action("folder", .group, url: "folder", children: [action("child", .speak, url: "read")])]
        XCTAssertEqual(ActionURL.action(named: "copy", in: list)?.id, "named")
        XCTAssertEqual(ActionURL.action(named: "COPY", in: list)?.id, "named")
        XCTAssertEqual(ActionURL.action(named: "read", in: list)?.id, "child")
        XCTAssertNil(ActionURL.action(named: "plain", in: list))    // its id or title is not a name
        XCTAssertNil(ActionURL.action(named: "folder", in: list))   // a group that only unfolds runs nothing
        XCTAssertEqual(ActionURL.takenNames(in: list), ["copy", "folder", "read"])
        XCTAssertEqual(ActionURL.takenNames(in: list, except: "named"), ["folder", "read"])
    }

    func testTheExampleURLParsesBackToWhatItSays() {
        let example = ActionURL.example(scheme: "qduo", name: "translate", text: "Hello world & 你好")
        XCTAssertEqual(parse(example), ActionURL.Request(name: "translate", text: "Hello world & 你好"))
    }

    func testURLNameRoundTripsAndIsLeftOutWhenUnset() throws {
        let json = #"[{ "id": "a", "title": "A", "iconSymbol": "star", "kind": "copy", "urlName": "copy" },"#
                 + #" { "id": "b", "title": "B", "iconSymbol": "star", "kind": "copy" }]"#
        let actions = try JSONDecoder().decode([PopBarActionConfig].self, from: Data(json.utf8))
        XCTAssertEqual(actions.map(\.urlName), ["copy", nil])
        let written = String(decoding: try JSONEncoder().encode(actions), as: UTF8.self)
        XCTAssertEqual(written.components(separatedBy: "urlName").count - 1, 1)
    }
}
