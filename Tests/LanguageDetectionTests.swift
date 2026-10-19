import NaturalLanguage
import XCTest

/// Language detection for system translation. Every probability table is
/// written out here. Nothing in this file calls `NLLanguageRecognizer`.
final class LanguageDetectionTests: XCTestCase {

    private let chineseFirst = ["zh-Hans", "en"]

    func testTheRecognizerIsConstrainedToFortyFiveLanguages() {
        XCTAssertEqual(LanguageDetection.constraints.count, 45)
        XCTAssertTrue(LanguageDetection.constraints.contains(.undetermined))
        // Undetermined is a constraint, not an answer and not a preferred language.
        XCTAssertEqual(LanguageDetection.codes.count, 44)
        XCTAssertFalse(LanguageDetection.codes.contains("und"))
        XCTAssertTrue(LanguageDetection.codes.contains("mn-Mong"))
        XCTAssertEqual(LanguageDetection.constraints.first { $0 == .mongolian }?.rawValue, "mn-Mong")
    }

    func testHintsBoostPreferredLanguagesAndFillTheRest() {
        let weights = LanguageDetection.hints(preferred: ["zh-Hans", "en"])
        XCTAssertEqual(weights.count, 45)
        XCTAssertEqual(weights["en"] ?? 0, 3.5, accuracy: 0.000_001)
        XCTAssertEqual(weights["zh-Hans"] ?? 0, 2.5, accuracy: 0.000_001)
        XCTAssertEqual(weights["zh-Hant"] ?? 0, 1.0, accuracy: 0.000_001)
        XCTAssertEqual(weights["tr"] ?? 0, 0.08, accuracy: 0.000_001)
        // Hebrew is allowed, and it has no base weight, so it gets the small default.
        XCTAssertEqual(weights["he"] ?? 0, 0.05, accuracy: 0.000_001)
        // Undetermined is constrained and has no base weight, so it gets the same default.
        XCTAssertEqual(weights["und"] ?? 0, 0.05, accuracy: 0.000_001)
    }

    func testAPreferredLanguageBelowTwoGainsOne() {
        let weights = LanguageDetection.hints(preferred: ["ko"])
        XCTAssertEqual(weights["ko"] ?? 0, 1.7, accuracy: 0.000_001)
    }

    func testAPreferredLanguageWithNoBaseWeightStartsAtOne() {
        let weights = LanguageDetection.hints(preferred: ["he"])
        XCTAssertEqual(weights["he"] ?? 0, 1.0, accuracy: 0.000_001)
        XCTAssertEqual(weights["ka"] ?? 0, 0.05, accuracy: 0.000_001)
    }

    func testAdjustedLiftsSimplifiedWhenChineseIsFirst() {
        let weights = LanguageDetection.adjusted(
            raw: ["zh-Hant": 0.62, "zh-Hans": 0.38],
            preferred: chineseFirst,
            firstIsChinese: true)
        XCTAssertEqual(weights["zh-Hans"] ?? 0, 0.78, accuracy: 0.000_001)
        XCTAssertEqual(weights["zh-Hant"] ?? 0, 0.62, accuracy: 0.000_001)
    }

    func testAdjustedLiftsEnglishFurtherWhenItIsFirst() {
        let weights = LanguageDetection.adjusted(
            raw: ["fr": 0.68, "en": 0.17],
            preferred: ["en", "zh-Hans"],
            firstIsChinese: false)
        XCTAssertEqual(weights["en"] ?? 0, 0.77, accuracy: 0.000_001)
        XCTAssertEqual(weights["fr"] ?? 0, 0.68, accuracy: 0.000_001)
    }

    func testEnglishGainsTwoTenthsWhenItIsNotPreferred() {
        let weights = LanguageDetection.adjusted(
            raw: ["en": 0.17, "fr": 0.68],
            preferred: ["zh-Hans"],
            firstIsChinese: true)
        XCTAssertEqual(weights["en"] ?? 0, 0.37, accuracy: 0.000_001)
    }

    func testSimplifiedAndTraditionalAreChosenFromTheCharacters() {
        XCTAssertEqual(resolve("你好", ["zh-Hant": 0.62, "zh-Hans": 0.38]), "zh-Hans")
        XCTAssertEqual(resolve("漢字", ["zh-Hant": 0.75, "ja": 0.25]), "zh-Hant")
        XCTAssertEqual(resolve("東京", ["ja": 0.89, "zh-Hant": 0.11]), "ja")
    }

    func testJapaneseWinsWhenItIsPreferredAndClose() {
        // 0.42 plus the first-place boost passes 0.58. A higher Traditional
        // score would keep Traditional, which is why this table is the lower one.
        XCTAssertEqual(
            resolve("漢字", ["zh-Hant": 0.58, "ja": 0.42], preferred: ["ja", "zh-Hans", "en"], firstIsChinese: false),
            "ja")
    }

    func testShortLatinWords() {
        XCTAssertEqual(resolve("apple", ["en": 0.70, "fr": 0.07, "tr": 0.04]), "en")
        // Danish stays ahead of English after the boost. The wrong guess is kept.
        XCTAssertEqual(resolve("Finder", ["da": 0.57, "de": 0.36, "en": 0.04]), "da")
        XCTAssertEqual(resolve("OK", ["en": 0.43, "pl": 0.22]), "en")
        XCTAssertEqual(resolve("oui", ["fr": 0.85, "en": 0.11], preferred: chineseFirst), "en")
        XCTAssertEqual(resolve("merci", ["fr": 0.60, "en": 0.22], preferred: chineseFirst), "en")
    }

    func testBonjourFollowsWhicheverLanguageIsFirst() {
        XCTAssertEqual(resolve("bonjour", ["fr": 0.68, "en": 0.17], preferred: chineseFirst, firstIsChinese: true), "fr")
        XCTAssertEqual(
            resolve("bonjour", ["fr": 0.68, "en": 0.17], preferred: ["en", "zh-Hans"], firstIsChinese: false),
            "en")
    }

    func testMixedTextKeepsTheNonEnglishHalfWhenItIsLonger() {
        let result = LanguageDetection.resolve(text: "iPhone 很好用", preferred: chineseFirst, firstIsChinese: true) { chunk in
            if chunk == "iPhone 很好用" { return ["en": 0.45, "pt": 0.13] }
            if chunk == "很好用" { return ["zh-Hans": 0.57, "zh-Hant": 0.43] }
            return ["ja": 0.99]
        }
        XCTAssertEqual(result, "zh-Hans")
    }

    func testMostlyEnglishMixedTextStaysEnglish() {
        // A wrong recursive answer is sitting there. Returning English means the
        // English words were enough on their own and that answer was not used.
        let result = LanguageDetection.resolve(
            text: "Hello world with one 中文 word",
            preferred: chineseFirst,
            firstIsChinese: true
        ) { chunk in
            if chunk == "Hello world with one 中文 word" { return ["en": 0.99] }
            return ["zh-Hans": 0.99]
        }
        XCTAssertEqual(result, "en")
    }

    func testAShortLatinWordWithLowConfidenceBecomesEnglish() {
        // Danish is still ahead after the boost: 0.45 against English
        // 0.04 + 0.4 = 0.44. That confidence is under 0.5, "Finder" is six
        // Latin characters, and the adjusted English score is over 0.1, so
        // the short-text rule answers English.
        XCTAssertEqual(resolve("Finder", ["da": 0.45, "de": 0.36, "en": 0.04]), "en")
    }

    func testThreeCharactersThatAreNotLatinKeepTheDetectedLanguage() {
        // "はい" is two characters. Japanese is not preferred, and the text is
        // not Latin, so the very-short rule keeps the detected language.
        XCTAssertEqual(resolve("はい", ["ja": 0.9]), "ja")
    }

    func testAnEnglishAnswerFromTheRemainderIsDiscarded() {
        // "Hi" is one English word and "你好" is two letters, so the remainder
        // is detected again. That second answer is English and is not used.
        // The English answer from the whole text stands.
        var seen: [String] = []
        let result = LanguageDetection.resolve(text: "Hi 你好", preferred: chineseFirst, firstIsChinese: true) { chunk in
            seen.append(chunk)
            if chunk == "Hi 你好" { return ["en": 0.8] }
            return ["en": 0.99]
        }
        XCTAssertEqual(seen, ["Hi 你好", "你好"])
        XCTAssertEqual(result, "en")
    }

    func testUndeterminedIsNotALanguage() {
        // Undetermined is the highest score. The text is five kana, not a short
        // Latin word, so none of the later rules replace it. The result is no
        // language, rather than "und" or the lower Japanese score.
        XCTAssertNil(resolve("こんにちは", ["und": 0.8, "ja": 0.2]))
    }

    func testTheRecognizerSeesTheOriginalText() {
        // Three spaces on each side make twelve characters. The trimmed word
        // is six. The short-text rule answers English only for that trimmed
        // length, and the recognizer is shown the spaces.
        var seen: [String] = []
        let result = LanguageDetection.resolve(
            text: "   Finder   ",
            preferred: chineseFirst,
            firstIsChinese: true
        ) { chunk in
            seen.append(chunk)
            return ["da": 0.45, "de": 0.36, "en": 0.04]
        }
        XCTAssertEqual(seen, ["   Finder   "])
        XCTAssertEqual(result, "en")
    }

    func testEmptyAndNumericText() {
        XCTAssertEqual(resolve("2024", [:]), "en")
        XCTAssertNil(resolve("", [:]))
        XCTAssertNil(resolve("   ", [:]))
        XCTAssertEqual(resolve("1234567890", ["ja": 0.99]), "en")
    }

    func testChineseWithNoHanCharactersStaysTraditional() {
        // The recognizer said Chinese, and the text has no Han character.
        // 0/0 is not ≥ 0.9, so this is Traditional rather than Simplified.
        XCTAssertEqual(resolve("abc", ["zh-Hans": 0.80]), "zh-Hant")
    }

    func testHanStats() {
        let thanks = LanguageDetection.hanStats("謝謝")
        XCTAssertEqual(thanks.han, 2)
        XCTAssertEqual(thanks.traditional, 2)
        XCTAssertFalse(thanks.mixed)

        let traditional = LanguageDetection.hanStats("繁體中文")
        XCTAssertEqual(traditional.han, 4)
        XCTAssertEqual(traditional.traditional, 1)
        XCTAssertFalse(traditional.mixed)

        XCTAssertTrue(LanguageDetection.hanStats("iPhone 很好用").mixed)
    }

    func testChineseConversionIsCharacterByCharacter() {
        XCTAssertEqual(LanguageDetection.toSimplified("系統翻譯"), "系统翻译")
        XCTAssertEqual(LanguageDetection.toTraditional("系统"), "系統")
        XCTAssertEqual(LanguageDetection.toSimplified("你好"), "你好")
        XCTAssertEqual(LanguageDetection.toTraditional("你好"), "你好")
        XCTAssertEqual(LanguageDetection.toSimplified("軟體"), "软体")
    }

    private func resolve(_ text: String, _ raw: [String: Double],
                         preferred: [String]? = nil, firstIsChinese: Bool = true) -> String? {
        let preferred = preferred ?? chineseFirst
        return LanguageDetection.resolve(text: text, preferred: preferred, firstIsChinese: firstIsChinese) { _ in raw }
    }
}
