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

    func testASpeakActionKeepsItsReader() throws {
        let out = try roundTrip("""
        [{ "id": "s1", "title": "Read", "iconSymbol": "speaker.wave.2.fill", "kind": "speak", "reader": "r-42" },
         { "id": "s2", "title": "Read default", "iconSymbol": "speaker.wave.2.fill", "kind": "speak" }]
        """)
        XCTAssertEqual(out.arrayValue?.first?[path: "reader"]?.stringValue, "r-42")
        // No reader = the default one, and nothing is written for it.
        XCTAssertNil(out.arrayValue?.last?[path: "reader"])
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

    func testTheSettingsKindIsKnownAndWrittenBackAsItself() throws {
        let json = """
        [{ "id": "s", "title": "Settings", "iconSymbol": "gearshape", "kind": "settings" }]
        """
        let action = try XCTUnwrap(try JSONDecoder().decode([PopBarActionConfig].self, from: Data(json.utf8)).first)
        XCTAssertEqual(action.kind, .settings)
        XCTAssertFalse(action.isUnsupported)
        XCTAssertEqual(try roundTrip(json).arrayValue?.first?[path: "kind"]?.stringValue, "settings")
    }

    func testThePauseKindIsKnownAndWrittenBackAsItself() throws {
        let json = """
        [{ "id": "p", "title": "Pause", "iconSymbol": "pause.circle", "kind": "pause" }]
        """
        let action = try XCTUnwrap(try JSONDecoder().decode([PopBarActionConfig].self, from: Data(json.utf8)).first)
        XCTAssertEqual(action.kind, .pause)
        XCTAssertFalse(action.isUnsupported)
        XCTAssertEqual(try roundTrip(json).arrayValue?.first?[path: "kind"]?.stringValue, "pause")
    }

    func testTheSystemTranslateKindKeepsItsKindAndOutput() throws {
        let json = """
        [{ "id": "t", "title": "Translate", "iconSymbol": "translate", "kind": "systemTranslate",
           "targetLanguage": "zh-TW", "output": "replace" }]
        """
        let action = try XCTUnwrap(try JSONDecoder().decode([PopBarActionConfig].self, from: Data(json.utf8)).first)
        XCTAssertEqual(action.kind, .systemTranslate)
        XCTAssertFalse(action.isUnsupported)
        XCTAssertTrue(action.hasOutput)
        XCTAssertEqual(action.outputMode, .replace)
        XCTAssertEqual(action.targetLanguage, "zh-TW")
        let out = try roundTrip(json).arrayValue?.first
        XCTAssertEqual(out?[path: "kind"]?.stringValue, "systemTranslate")
        XCTAssertEqual(out?[path: "output"]?.stringValue, "replace")
        XCTAssertEqual(out?[path: "targetLanguage"]?.stringValue, "zh-TW")
    }

    func testTheCompareOutputLoadsAndSavesAsCompare() throws {
        let json = """
        [{ "id": "p", "title": "Polish", "iconSymbol": "wand.and.stars", "kind": "ai", "prompt": "p", "output": "compare" }]
        """
        let action = try XCTUnwrap(try JSONDecoder().decode([PopBarActionConfig].self, from: Data(json.utf8)).first)
        XCTAssertEqual(action.outputMode, .compare)
        XCTAssertEqual(try roundTrip(json).arrayValue?.first?[path: "output"]?.stringValue, "compare")
    }

    func testAKnownFieldIsNeverShadowedByAStrayExtra() throws {
        // If a decode ever let a known name into `extra`, encoding it again would
        // write the key twice. Belt and braces: the title must be the real one.
        let out = try roundTrip("""
        [{ "id": "a", "title": "Real", "iconSymbol": "doc", "kind": "copy", "prompt": "" }]
        """)
        XCTAssertEqual(out.arrayValue?.first?[path: "title"]?.stringValue, "Real")
    }

    func testNewKindsKeepTheirFieldsAndUnknownValues() throws {
        // `op` and `output` are held as strings, so a value a newer build wrote
        // must come back exactly as it was, not be dropped or rewritten.
        let out = try roundTrip("""
        [{ "id": "t", "title": "Shout", "iconSymbol": "a", "kind": "transform",
           "op": "rot13", "output": "replaceAndSelect" },
         { "id": "u", "title": "Search", "iconSymbol": "m", "kind": "openURL",
           "url": "https://x.com/?q={text}", "openIn": "preview" },
         { "id": "s", "title": "Run", "iconSymbol": "t", "kind": "script", "script": "wc -w" }]
        """)
        let items = try XCTUnwrap(out.arrayValue)
        XCTAssertEqual(items[0][path: "op"]?.stringValue, "rot13")
        XCTAssertEqual(items[0][path: "output"]?.stringValue, "replaceAndSelect")
        XCTAssertEqual(items[1][path: "url"]?.stringValue, "https://x.com/?q={text}")
        XCTAssertEqual(items[1][path: "openIn"]?.stringValue, "preview")
        XCTAssertEqual(items[2][path: "script"]?.stringValue, "wc -w")
        XCTAssertNil(items[2][path: "prompt"], "an action without a prompt does not write an empty one")
    }

    func testOutputDefaultsToThePanelAndCountIgnoresIt() throws {
        let actions = try JSONDecoder().decode([PopBarActionConfig].self, from: Data("""
        [{ "id": "a", "title": "T", "iconSymbol": "a", "kind": "transform", "op": "uppercase" },
         { "id": "b", "title": "T", "iconSymbol": "a", "kind": "transform", "op": "count", "output": "replace" },
         { "id": "c", "title": "T", "iconSymbol": "a", "kind": "ai", "prompt": "p", "output": "nonsense" }]
        """.utf8))
        XCTAssertEqual(actions.map(\.outputMode), [.panel, .panel, .panel])
    }

    func testURLTemplateEncodesTheSelectionAsOneQueryValue() throws {
        XCTAssertEqual(URLTemplate.fill("https://s.com/?q={text}", with: "a b&c=d#e?f/g")?.absoluteString,
                       "https://s.com/?q=a%20b%26c%3Dd%23e%3Ff%2Fg")
        XCTAssertEqual(URLTemplate.fill("dict://{text}", with: "你好")?.absoluteString,
                       "dict://%E4%BD%A0%E5%A5%BD")
        XCTAssertNil(URLTemplate.fill("   ", with: "x"), "no scheme, no URL")
        // The scheme has to be the template's own: a template that begins with
        // the placeholder would take it from the selection.
        XCTAssertNil(URLTemplate.fill("{text}?x=1", with: "http://x.com"))
        XCTAssertNil(URLTemplate.fill("{text}//evil.com", with: "http:"))
        XCTAssertEqual(URLTemplate.writtenScheme(of: "dict://{text}"), "dict")
        XCTAssertEqual(URLTemplate.writtenScheme(of: "svn+ssh://{text}"), "svn+ssh")
        XCTAssertEqual(URLTemplate.writtenScheme(of: "https://a/{text}:{text}"), "https")
        XCTAssertEqual(URLTemplate.writtenScheme(of: "obsidian://open"), "obsidian")
        for template in ["{text}", "{text}:x", "1a:{text}", "x y:{text}", "www.google.com/search?q={text}"] {
            XCTAssertNil(URLTemplate.writtenScheme(of: template), template)
        }
        XCTAssertNil(URLTemplate.fill("{text}?x=1", with: "tel:10086"))
        XCTAssertNil(URLTemplate.fill("{text}?x=1", with: "file:///Applications/Calculator.app"))
        XCTAssertNil(URLTemplate.fill("t{text}", with: "el:10086"))
        XCTAssertEqual(URLTemplate.fill("tel:{text}", with: "10086")?.absoluteString, "tel:10086")
        XCTAssertEqual(URLTemplate.fill("TEL:{text}", with: "10086")?.absoluteString, "TEL:10086")
        XCTAssertEqual(URLTemplate.fill("maps://?q={text}", with: "tel:1")?.absoluteString, "maps://?q=tel:1")
        XCTAssertEqual(URLTemplate.fill("https://s.com/?q={text}", with: "tel:10086")?.absoluteString,
                       "https://s.com/?q=tel:10086")
        XCTAssertEqual(URLTemplate.fill("obsidian://open", with: "x")?.absoluteString, "obsidian://open",
                       "a template with no placeholder opens as written")
        XCTAssertFalse(URLTemplate.isWeb(try XCTUnwrap(URL(string: "obsidian://new"))))
    }

    func testATemplateThatIsOnlyThePlaceholderOpensTheSelectionItself() {
        XCTAssertTrue(URLTemplate.isSelectionOnly("  {text}\n"))
        XCTAssertFalse(URLTemplate.isSelectionOnly("https://{text}"))
        XCTAssertFalse(URLTemplate.isSelectionOnly(""))

        func address(_ selection: String) -> String? { URLTemplate.webAddress(in: selection)?.absoluteString }
        // Written out in full: opened as written, structure intact.
        XCTAssertEqual(address("https://example.com/a?b=1&c=2#d"), "https://example.com/a?b=1&c=2#d")
        XCTAssertEqual(address("  HTTP://Example.com/A \n"), "HTTP://Example.com/A")
        XCTAssertEqual(address("http://localhost:3000/x"), "http://localhost:3000/x")
        XCTAssertEqual(address("https://zh.wikipedia.org/wiki/中文"), "https://zh.wikipedia.org/wiki/%E4%B8%AD%E6%96%87")
        // No scheme: the link detector completes it.
        XCTAssertEqual(address("example.com"), "http://example.com")
        XCTAssertEqual(address("github.com/apple/swift"), "http://github.com/apple/swift")
        // The detector knows neither of these.
        XCTAssertEqual(address("localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(address("192.168.1.1:8080/admin"), "http://192.168.1.1:8080/admin")
        XCTAssertNil(address("999.1.1.1"))
        XCTAssertNil(address("localhost:99999"))
        // Nor a bare Chinese domain; written out in full it opens.
        XCTAssertNil(address("中文.com"))
        XCTAssertNotNil(address("https://中文.com/路径"))
        // A user name in front of the host is how a link passes for another site.
        XCTAssertNil(address("https://a.com@evil.com"))
        XCTAssertNil(address("https:////example.com"))
        // Far too long to be an address — and quick to say so.
        XCTAssertNil(address("localhost/" + String(repeating: "a", count: URLTemplate.maxAddressLength)))
        XCTAssertNil(address("https://example.com/" + String(repeating: ")", count: 200_000)))
        // What a sentence wraps an address in is not part of it.
        XCTAssertEqual(address("(https://example.com)"), "https://example.com")
        XCTAssertEqual(address("https://example.com/a。"), "https://example.com/a")
        XCTAssertEqual(address("“example.com”，"), "http://example.com")
        XCTAssertEqual(address("https://en.wikipedia.org/wiki/Swift_(programming_language)"),
                       "https://en.wikipedia.org/wiki/Swift_(programming_language)")
        // Not an address, or an address among other words.
        for selection in ["", "   ", "123", "hello world", "readme.md", "3.14", "localhost:3000 is up",
                          "see example.com for details", "example.com\nsecond line", "https://"] {
            XCTAssertNil(address(selection), selection)
        }
        // Anything but a web page would make the system act on text somebody
        // else wrote.
        for selection in ["file:///Applications/Calculator.app", "ssh://root@1.2.3.4", "tel:10086",
                          "foo@bar.com", "mailto:foo@bar.com", "javascript:alert(1)", "ftp://example.com/f",
                          "x-apple.systempreferences:com.apple.preference.security"] {
            XCTAssertNil(address(selection), selection)
        }
    }

    func testTemplatesAreValidActions() {
        // Every template must be something the editor would let you save.
        for section in ActionTemplates.sections() {
            for action in section.actions where action.kind == .transform {
                XCTAssertNotNil(action.op.flatMap(TextTransform.init(rawValue:)), action.title)
            }
            for action in section.actions where action.kind == .openURL {
                let url = action.url ?? ""
                XCTAssertTrue(URLTemplate.isSelectionOnly(url) || URLTemplate.fill(url, with: "x") != nil, action.title)
            }
        }
    }

    func testTheDefaultsFoldTheLessUsedActionsIntoOneToolsGroup() throws {
        let seed = DefaultActions.seed()
        XCTAssertEqual(seed.map(\.kind), [.ai, .ai, .ai, .group, .openURL, .speak, .copy])
        let group = try XCTUnwrap(seed.first { $0.kind == .group })
        XCTAssertEqual(group.children.map(\.kind), [.webPreview, .settings, .openURL])
        // The third is ChatGPT, asked with the selection.
        XCTAssertEqual(group.children.last?.url, "https://chatgpt.com/?q={text}")
        // And the group survives the trip through the config file.
        let data = try JSONEncoder().encode(seed)
        let back = try JSONDecoder().decode([PopBarActionConfig].self, from: data)
        XCTAssertEqual(back.first { $0.kind == .group }?.children.count, 3)
    }

    func testTheDefaultPolishComparesBeforeReplacing() {
        let seed = DefaultActions.seed()
        XCTAssertEqual(seed.map(\.outputMode), [.panel, .compare, .panel, .panel, .panel, .panel, .panel])
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
