import NaturalLanguage
import XCTest

/// Where a system translation goes once the source language is known.
/// The locale lists are fixed, so the result does not depend on this Mac.
final class TranslateDecisionTests: XCTestCase {

    func testLanguageOfTargetIDDropsRegionAndReadsTheChineseScript() {
        XCTAssertEqual(TranslateDecision.language(ofTargetID: "zh"), "zh-Hans")
        XCTAssertEqual(TranslateDecision.language(ofTargetID: "zh-TW"), "zh-Hant")
        // zh-HK names no script. Its maximal identifier does, and that script
        // is Hant. A script-less zh-* is not forced to Simplified.
        XCTAssertEqual(TranslateDecision.language(ofTargetID: "zh-HK"), "zh-Hant")
        XCTAssertEqual(TranslateDecision.language(ofTargetID: "en-GB"), "en")
        XCTAssertEqual(TranslateDecision.language(ofTargetID: "ar-AE"), "ar")
    }

    func testSameLanguageCodeIgnoresScriptAndRegion() {
        XCTAssertTrue(TranslateDecision.sameLanguageCode("zh-Hant", "zh"))
        XCTAssertTrue(TranslateDecision.sameLanguageCode("zh-Hans", "zh-TW"))
        XCTAssertTrue(TranslateDecision.sameLanguageCode("en", "en-GB"))
        XCTAssertTrue(TranslateDecision.sameLanguageCode("pt-BR", "pt-PT"))
        XCTAssertFalse(TranslateDecision.sameLanguageCode("yue", "zh"))
        XCTAssertFalse(TranslateDecision.sameLanguageCode("en", "fr"))
    }

    func testSystemSecondLanguage() {
        XCTAssertEqual(TranslateDecision.systemSecondLanguage(locales: ["en", "zh-Hans"]), "zh-Hans")
        XCTAssertEqual(TranslateDecision.systemSecondLanguage(locales: ["zh-Hans"]), "en")
        XCTAssertEqual(TranslateDecision.systemSecondLanguage(locales: ["en"]), "zh-Hans")
        XCTAssertEqual(TranslateDecision.systemSecondLanguage(locales: ["en-US", "zh-Hans-CN"]), "zh-Hans")
        XCTAssertEqual(TranslateDecision.systemPreferredLanguages(from: ["zh-HK", "en-GB", "en"]), ["zh-Hant", "en"])
    }

    func testPreferredLanguagesAreTheSameForNoneAndForAMissingSetting() {
        let locales = ["en", "zh-Hans"]
        XCTAssertEqual(
            TranslateDecision.preferredLanguages(targetID: "ja", secondSetting: "none", locales: locales),
            TranslateDecision.preferredLanguages(targetID: "ja", secondSetting: nil, locales: locales))
        XCTAssertEqual(
            TranslateDecision.preferredLanguages(targetID: "ja", secondSetting: nil, locales: locales),
            ["ja", "zh-Hans", "en"])
    }

    func testNoneReportsTextAlreadyInTheTarget() {
        XCTAssertEqual(decide(source: "zh-Hans", target: "zh", second: "none"), .alreadyInTarget("zh"))
        XCTAssertEqual(decide(source: "zh-Hant", target: "zh", second: "none"), .convertChinese(to: "zh-Hans"))
        XCTAssertEqual(decide(source: "en", target: "zh", second: "none"), .translate(source: "en", toTargetID: "zh"))
        XCTAssertEqual(decide(source: nil, target: "zh", second: "none"), .translate(source: nil, toTargetID: "zh"))
    }

    func testNoneOnAnEnglishTargetDoesNotBecomeChinese() {
        // The identifier "none" is English to Locale. The opt-out still stops.
        XCTAssertEqual(
            decide(source: "en", target: "en", second: "none", locales: ["en"]),
            .alreadyInTarget("en"))
    }

    func testAnExplicitEnglishSecondLanguage() {
        XCTAssertEqual(decide(source: "zh-Hans", target: "zh", second: "en"), .translate(source: "zh-Hans", toTargetID: "en"))
        XCTAssertEqual(decide(source: "zh-Hant", target: "zh", second: "en"), .convertChinese(to: "zh-Hans"))
        XCTAssertEqual(decide(source: "fr", target: "zh", second: "en"), .translate(source: "fr", toTargetID: "zh"))
    }

    func testTraditionalTargetWithAnEnglishSecondLanguage() {
        XCTAssertEqual(decide(source: "zh-Hans", target: "zh-TW", second: "en"), .convertChinese(to: "zh-Hant"))
        XCTAssertEqual(decide(source: "zh-Hant", target: "zh-TW", second: "en"), .translate(source: "zh-Hant", toTargetID: "en"))
    }

    func testAnExplicitSecondLanguageKeepsItsOwnIdentifier() {
        XCTAssertEqual(
            decide(source: "zh-Hans", target: "zh", second: "en-GB"),
            .translate(source: "zh-Hans", toTargetID: "en-GB"))
    }

    func testAMissingSecondLanguageFollowsTheSystemThenTheFallback() {
        XCTAssertEqual(
            decide(source: "zh-Hans", target: "zh", second: nil, locales: ["en", "zh-Hans"]),
            .translate(source: "zh-Hans", toTargetID: "en"))
        XCTAssertEqual(
            decide(source: "zh-Hans", target: "zh", second: nil, locales: ["zh-Hans"]),
            .translate(source: "zh-Hans", toTargetID: "en"))
        XCTAssertEqual(
            decide(source: "ja", target: "ja", second: nil, locales: ["en"]),
            .translate(source: "ja", toTargetID: "zh"))
        XCTAssertEqual(
            decide(source: "en", target: "en", second: nil, locales: ["en"]),
            .translate(source: "en", toTargetID: "zh"))
    }

    func testASourceThatIsNotTheTargetKeepsTheStoredTargetIdentifier() {
        XCTAssertEqual(
            decide(source: "fr", target: "en-GB", second: nil, locales: ["en"]),
            .translate(source: "fr", toTargetID: "en-GB"))
    }

    func testAMissingSecondLanguageUsesTheNextSystemLanguage() {
        XCTAssertEqual(
            decide(source: "en", target: "en", second: nil, locales: ["en", "zh-Hant"]),
            .translate(source: "en", toTargetID: "zh-TW"))
        XCTAssertEqual(
            decide(source: "zh-Hans", target: "zh", second: nil, locales: ["zh-Hans", "ja"]),
            .translate(source: "zh-Hans", toTargetID: "ja"))
    }

    func testPreferredLanguagesMapAnExplicitSecondLanguage() {
        XCTAssertEqual(
            TranslateDecision.preferredLanguages(targetID: "zh", secondSetting: "en-GB", locales: ["ja"]),
            ["zh-Hans", "en", "ja"])
    }

    func testMongolianUsesTheRecognizerCode() {
        let mongolian = NLLanguage.mongolian.rawValue
        XCTAssertEqual(TranslateDecision.language(ofTargetID: "mn"), mongolian)
        XCTAssertEqual(TranslateDecision.systemPreferredLanguages(from: ["mn", "en"]), [mongolian, "en"])
        XCTAssertEqual(TranslateDecision.systemPreferredLanguages(from: ["mn-MN", "en"]), [mongolian, "en"])
    }

    func testUndeterminedIsLeftOutOfThePreferredLanguages() {
        // "und" must not be expanded into English, and it must not be kept.
        XCTAssertEqual(TranslateDecision.language(ofTargetID: "und"), NLLanguage.undetermined.rawValue)
        XCTAssertEqual(TranslateDecision.systemPreferredLanguages(from: ["und", "ja"]), ["ja"])
        XCTAssertEqual(
            TranslateDecision.preferredLanguages(targetID: "zh", secondSetting: nil, locales: ["und", "fr"]),
            ["zh-Hans", "en", "fr"])
    }

    func testAMissingSourceGoesToTheTargetEvenWhenASecondLanguageIsSet() {
        XCTAssertEqual(
            decide(source: nil, target: "zh", second: "en"),
            .translate(source: nil, toTargetID: "zh"))
    }

    private func decide(source: String?, target: String, second: String?,
                        locales: [String] = ["en"]) -> TranslateDecision.Outcome {
        TranslateDecision.decide(source: source, targetID: target, secondSetting: second, locales: locales)
    }
}
