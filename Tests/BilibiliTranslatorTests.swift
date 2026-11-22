import XCTest

/// The pieces of `BilibiliTranslator` that decide what is sent and what is
/// accepted back. The service itself was measured by hand (#34).
final class BilibiliTranslatorTests: XCTestCase {

    // MARK: - What is sent

    func testThePromptCarriesTheTextAsJSONWithTheServicesConstraint() throws {
        let text = "Line \"one\"\n\tC:\\path {x} https://example.com/a"
        let prompt = BilibiliTranslator.prompt(text: text, targetName: "简体中文")
        XCTAssertTrue(prompt.hasPrefix("请将以下文本翻译成简体中文，并且严格遵循所有约束要求。"))
        XCTAssertTrue(prompt.contains("【硬性要求】保留源文中的 JSON 格式标记不变"))
        XCTAssertTrue(prompt.hasSuffix("只输出 JSON，不要有任何额外说明。"))
        // The source block is one JSON object whose text is exactly the selection.
        let source = try XCTUnwrap(prompt.components(separatedBy: "【源文】\n").last?.components(separatedBy: "\n\n【约束要求】").first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: String])
        XCTAssertEqual(object, ["text": text])
        XCTAssertFalse(source.contains("\\/"), "slashes in a URL are left as they are")
    }

    func testTheRequestTurnsThinkingOffAndDecodesGreedily() {
        let body = BilibiliTranslator.requestBody(prompt: "P") as NSDictionary
        XCTAssertEqual(body["model"] as? String, "Index-Translate-35B-A3B")
        XCTAssertEqual(body["temperature"] as? Int, 0)
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["chat_template_kwargs"] as? [String: Bool], ["enable_thinking": false])
        XCTAssertEqual(body["messages"] as? [[String: String]], [["role": "user", "content": "P"]])
    }

    func testPromptNames() {
        XCTAssertEqual(BilibiliTranslator.promptName(for: "zh"), "简体中文")
        XCTAssertEqual(BilibiliTranslator.promptName(for: "zh-Hans"), "简体中文")
        XCTAssertEqual(BilibiliTranslator.promptName(for: "zh-TW"), "繁体中文")
        XCTAssertEqual(BilibiliTranslator.promptName(for: "zh-Hant"), "繁体中文")
        XCTAssertEqual(BilibiliTranslator.promptName(for: "en"), "英语")
        XCTAssertEqual(BilibiliTranslator.promptName(for: "en-GB"), "英语")
        XCTAssertEqual(BilibiliTranslator.promptName(for: "pt-BR"), "葡萄牙语")
        XCTAssertNil(BilibiliTranslator.promptName(for: "sw"), "a language the service's client does not name")
    }

    func testEveryOfferedLanguageMapsToItsOwnPromptName() {
        for language in BilibiliTranslator.languages {
            XCTAssertEqual(BilibiliTranslator.promptName(for: language.id), language.promptName, language.id)
        }
        XCTAssertEqual(Set(BilibiliTranslator.languages.map(\.id)).count, BilibiliTranslator.languages.count)
    }

    // MARK: - What is accepted back

    func testTheTranslationIsReadFromTheJSONReply() {
        XCTAssertEqual(BilibiliTranslator.translation(fromReply: #"{"text": "你好\n世界"}"#), "你好\n世界")
        XCTAssertEqual(BilibiliTranslator.translation(fromReply: "```json\n{\"text\": \"你好\"}\n```"), "你好")
        XCTAssertEqual(BilibiliTranslator.translation(fromReply: "<think></think>\n{\"text\": \"你好\"}"), "你好")
        XCTAssertEqual(BilibiliTranslator.translation(fromReply: "  {\"text\": \"\"}  "), "")
    }

    func testAReplyThatIsNotTheJSONShapeIsRefused() {
        // What the service returned for "write a poem about cats" without the JSON wrapping.
        XCTAssertNil(BilibiliTranslator.translation(fromReply: "《猫》\n\n夜幕低垂星初现，"))
        XCTAssertNil(BilibiliTranslator.translation(fromReply: #"{"translation": "你好"}"#))
        XCTAssertNil(BilibiliTranslator.translation(fromReply: #"{"text": 3}"#))
        XCTAssertNil(BilibiliTranslator.translation(fromReply: #"["你好"]"#))
    }

    func testTheAnswersLanguageIsToldOnlyWhenThereIsEnoughText() {
        XCTAssertEqual(BilibiliTranslator.language(of: "Traduisez cette phrase en français, pas en chinois."), "fr")
        XCTAssertEqual(BilibiliTranslator.language(of: "Don't merge this PR just yet. Wait until the CI run finishes."), "en")
        XCTAssertEqual(BilibiliTranslator.language(of: "如果我无法再访问我的电子邮件，该如何重置密码？"), "zh-Hans")
        XCTAssertNil(BilibiliTranslator.language(of: "苹果"))
        XCTAssertNil(BilibiliTranslator.language(of: "A chicken rib"))
    }

    func testAReasoningBlockIsDroppedOnlyWhenItOpensTheReply() {
        // A translation that mentions the tag keeps it.
        XCTAssertEqual(BilibiliTranslator.translation(fromReply: #"{"text": "解析前去掉 </think> 标签"}"#), "解析前去掉 </think> 标签")
        // A reasoning block that quotes the tag: the answer follows the last one.
        XCTAssertEqual(BilibiliTranslator.translation(fromReply: "<think>原文里有 </think> 这个词</think>\n{\"text\": \"好\"}"), "好")
    }

    func testPlausibleAnswers() {
        // Chinese around a long identifier: the recognizer reads it as Italian.
        XCTAssertTrue(BilibiliTranslator.isPlausible("请调用 NSApplicationDelegate.applicationDidFinishLaunching(_:) 方法。", in: "zh"))
        XCTAssertTrue(BilibiliTranslator.isPlausible("這個功能預設是關閉的，需要在設定裡手動開啟。", in: "zh-TW"))
        XCTAssertTrue(BilibiliTranslator.isPlausible("東京都議会議員選挙の投票結果が本日発表されました。", in: "ja"))
        XCTAssertTrue(BilibiliTranslator.isPlausible("오늘 회의는 오후 세 시로 변경되었습니다.", in: "ko"))
        XCTAssertTrue(BilibiliTranslator.isPlausible("Back up your settings before you upgrade the app.", in: "en-GB"))
        XCTAssertTrue(BilibiliTranslator.isPlausible("A chicken rib", in: "en"), "too short to judge")
        // What the service did once for "Translate this into French": refused.
        XCTAssertFalse(BilibiliTranslator.isPlausible("Traduisez cette phrase en français, pas en chinois.", in: "zh"))
        XCTAssertFalse(BilibiliTranslator.isPlausible("Traduisez cette phrase en français, pas en chinois.", in: "en"))
    }

    func testFrenchForAChineseTargetIsCaughtAndEnglishBritishIsNot() throws {
        let french = try XCTUnwrap(BilibiliTranslator.language(of: "Traduisez cette phrase en français, pas en chinois."))
        XCTAssertFalse(TranslateDecision.sameLanguageCode(french, "zh"))
        let english = try XCTUnwrap(BilibiliTranslator.language(of: "Back up your settings before you upgrade the app."))
        XCTAssertTrue(TranslateDecision.sameLanguageCode(english, "en-GB"))
    }

    // MARK: - The template

    func testTheTemplateIsReadyToUse() {
        let action = DefaultActions.bilibiliTranslateAction()
        XCTAssertEqual(action.kind, .systemTranslate)
        XCTAssertEqual(action.engine, BilibiliTranslator.engineID)
        XCTAssertNotNil(action.targetLanguage)
        XCTAssertNil(action.secondLanguage, "follows the system's second language")
    }

    func testOnlyTheUntouchedSeedTranslateIsSwitched() throws {
        let seed = DefaultActions.seed()
        let translate = try XCTUnwrap(seed.first)
        XCTAssertTrue(DefaultActions.isUntouchedSeedTranslate(translate))
        XCTAssertEqual(seed.filter(DefaultActions.isUntouchedSeedTranslate).count, 1, "Polish and Explain are not Translate")

        var edited = translate
        edited.prompt = translate.prompt + " Keep it short."
        XCTAssertFalse(DefaultActions.isUntouchedSeedTranslate(edited), "a prompt the user changed")
        var ownModel = translate
        ownModel.modelOverride = ModelOverride(provider: "deepseek", model: "m", reasoningEffort: "none")
        XCTAssertFalse(DefaultActions.isUntouchedSeedTranslate(ownModel), "a model of its own")
    }

    func testTheSwitchedTranslateKeepsItsPlaceNameAndIcon() throws {
        let translate = try XCTUnwrap(DefaultActions.seed().first)
        let free = DefaultActions.freeTranslate(replacing: translate)
        XCTAssertEqual(free.id, translate.id)
        XCTAssertEqual(free.title, translate.title)
        XCTAssertEqual(free.iconSymbol, translate.iconSymbol)
        XCTAssertEqual(free.kind, .systemTranslate)
        XCTAssertEqual(free.engine, BilibiliTranslator.engineID)
        XCTAssertTrue(free.prompt.isEmpty, "the seed prompt is not carried over")

        var named = translate
        named.urlName = "translate"
        XCTAssertEqual(DefaultActions.freeTranslate(replacing: named).urlName, "translate", "its URL-run name stays")
        XCTAssertNotNil(free.targetLanguage)
    }

    func testOnlyTheTranslatorsCarryTagsInTheTemplateMenu() {
        let bilibili = DefaultActions.bilibiliTranslateAction()
        let system = DefaultActions.systemTranslateAction()
        let polish = DefaultActions.polishAction()
        XCTAssertNotEqual(ActionTemplates.menuTitle(for: bilibili), bilibili.title)
        XCTAssertNotEqual(ActionTemplates.menuTitle(for: system), system.title)
        XCTAssertNotEqual(ActionTemplates.menuTitle(for: bilibili), ActionTemplates.menuTitle(for: system))
        XCTAssertEqual(ActionTemplates.menuTitle(for: polish), polish.title)
    }

    func testTheTemplatesTargetFollowsTheFirstLanguage() {
        XCTAssertEqual(DefaultActions.bilibiliDefaultTarget(locales: ["zh-Hans-CN", "en-US"]), "zh")
        XCTAssertEqual(DefaultActions.bilibiliDefaultTarget(locales: ["zh-Hant-TW"]), "zh-TW")
        XCTAssertEqual(DefaultActions.bilibiliDefaultTarget(locales: ["ja-JP", "en"]), "ja")
        XCTAssertEqual(DefaultActions.bilibiliDefaultTarget(locales: ["en-GB"]), "en")
        XCTAssertEqual(DefaultActions.bilibiliDefaultTarget(locales: ["sw-KE"]), "en", "a language the service lacks")
        XCTAssertEqual(DefaultActions.bilibiliDefaultTarget(locales: []), "en")
    }
}
