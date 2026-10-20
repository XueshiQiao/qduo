import Foundation
import NaturalLanguage

/// Which language a piece of text is in, before a system translation decides
/// where to send it. The probabilities come from `NLLanguageRecognizer`. The
/// weights and the corrections after that are applied here, so a short English
/// word is less often called Turkish and mixed Chinese stays Chinese.
///
/// `rawHypotheses` is the only function that creates a recognizer. Tests pass
/// their own probability tables into `resolve` and never call it.
///
/// Nothing in here writes a log. A log line belongs with the translation that
/// uses the result, and it may name a language code and a character count only.
enum LanguageDetection {

    /// Languages the recognizer is constrained to. Undetermined is included, so
    /// the hints give it 0.05, the same small default as a language with no
    /// base weight. An answer of undetermined is not kept: `resolve` turns
    /// "und" into nil. An empty answer is still English.
    static let constraints: [NLLanguage] = [
        .simplifiedChinese, .traditionalChinese, .english, .japanese, .korean,
        .french, .spanish, .catalan, .portuguese, .italian, .german, .russian,
        .arabic, .swedish, .romanian, .thai, .slovak, .dutch, .hungarian, .greek,
        .danish, .finnish, .polish, .czech, .turkish, .ukrainian, .bulgarian,
        .indonesian, .malay, .vietnamese, .persian, .hindi, .telugu, .tamil,
        .urdu, .khmer, .lao, .bengali, .burmese, .norwegian, .croatian,
        .mongolian, .hebrew, .georgian, .undetermined,
    ]

    /// Codes a result or a preferred language may use. "und" is not one of
    /// them. Mongolian's code is "mn-Mong", not "mn".
    static let codes: Set<String> = Set(constraints.filter { $0 != .undetermined }.map(\.rawValue))

    /// How strongly each language is hinted before the recognizer runs.
    /// A language that is often guessed by mistake (Turkish) stays very low.
    /// English and Simplified Chinese start higher because short Latin text
    /// collapses onto them once the user's languages are added.
    private static let baseWeights: [NLLanguage: Double] = [
        .english: 2.0,
        .simplifiedChinese: 1.5,
        .traditionalChinese: 1.0,
        .japanese: 0.8,
        .korean: 0.7,
        .french: 0.8,
        .spanish: 0.8,
        .italian: 0.6,
        .portuguese: 0.7,
        .german: 0.6,
        .dutch: 0.4,
        .russian: 0.8,
        .polish: 0.4,
        .czech: 0.3,
        .turkish: 0.08,
        .catalan: 0.1,
        .arabic: 0.3,
        .persian: 0.2,
        .thai: 0.3,
        .vietnamese: 0.25,
        .hindi: 0.2,
        .swedish: 0.15,
        .danish: 0.15,
        .norwegian: 0.15,
        .finnish: 0.1,
        .ukrainian: 0.3,
        .bulgarian: 0.15,
        .romanian: 0.2,
        .hungarian: 0.05,
        .greek: 0.2,
        .slovak: 0.05,
        .croatian: 0.1,
        .indonesian: 0.1,
        .malay: 0.08,
    ]

    /// Hint weight for every constrained language, after the preferred list is
    /// added. A preferred language whose base weight is at least 2 gains 1.5;
    /// any other preferred language gains 1, or starts at 1 when it has no base
    /// weight. Every constrained language that is still missing gets 0.05.
    static func hints(preferred: [String]) -> [String: Double] {
        var weights: [String: Double] = [:]
        for (language, weight) in baseWeights {
            weights[language.rawValue] = weight
        }
        var seen = Set<String>()
        for language in preferred where seen.insert(language).inserted {
            if let weight = weights[language] {
                let boost = weight >= 2.0 ? 1.5 : 1.0
                weights[language] = weight + boost
            } else {
                weights[language] = 1.0
            }
        }
        for language in constraints where weights[language.rawValue] == nil {
            weights[language.rawValue] = 0.05
        }
        return weights
    }

    /// The recognizer's probabilities, lifted a little toward the languages the
    /// action and the system prefer. Only a language that is already in `raw`
    /// moves: a preferred language the recognizer did not offer stays absent.
    /// Position 0 gains 0.4, and each later position gains 0.1 less, down to
    /// 0.1. English gains a further 0.1 when the first preferred language is
    /// Chinese, and 0.2 otherwise. English that is not preferred at all still
    /// gains 0.2 when it was offered.
    static func adjusted(raw: [String: Double], preferred: [String], firstIsChinese: Bool) -> [String: Double] {
        var adjusted = raw
        for (index, language) in preferred.enumerated() {
            guard let probability = raw[language] else { continue }
            var boost = max(0.4 - 0.1 * Double(index), 0.1)
            if language == "en" {
                boost += firstIsChinese ? 0.1 : 0.2
            }
            adjusted[language] = probability + boost
        }
        if !preferred.contains("en"), let english = raw["en"] {
            adjusted["en"] = english + 0.2
        }
        return adjusted
    }

    /// One recognizer pass. Constraints and hints are both set, and at most
    /// five hypotheses come back, keyed by the language's raw value.
    static func rawHypotheses(_ text: String, preferred: [String]) -> [String: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = constraints
        var hintsByLanguage: [NLLanguage: Double] = [:]
        for (code, weight) in hints(preferred: preferred) {
            hintsByLanguage[NLLanguage(rawValue: code)] = weight
        }
        recognizer.languageHints = hintsByLanguage
        recognizer.processString(text)
        var raw: [String: Double] = [:]
        for (language, probability) in recognizer.languageHypotheses(withMaximum: 5) {
            raw[language.rawValue] = probability
        }
        return raw
    }

    /// The language code to tell the translator, or nil when the trimmed text
    /// is empty, or when the answer is undetermined and no later correction
    /// names a language. Nil tells the translator to detect the source itself.
    ///
    /// The recognizer is given the original text of each pass, including
    /// surrounding spaces and the non-ASCII remainder of mixed text. Counting
    /// and the corrections use the trimmed text. A test can pass its own
    /// probability table instead of the recognizer.
    static func resolve(text: String, preferred: [String], firstIsChinese: Bool,
                        rawHypotheses: (String) -> [String: Double]) -> String? {
        resolve(text: text, preferred: preferred, firstIsChinese: firstIsChinese,
                rawHypotheses: rawHypotheses, inheritedStats: nil)
    }

    private static func resolve(text: String, preferred: [String], firstIsChinese: Bool,
                                rawHypotheses: (String) -> [String: Double],
                                inheritedStats: ScriptStats?) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return nil }

        // The recognizer sees this pass's text as it arrived, spaces included.
        // The corrections below use the trimmed text. A recursive pass arrives
        // already reduced to its letters.
        let raw = rawHypotheses(text)
        if raw.isEmpty { return "en" }

        let weights = adjusted(raw: raw, preferred: preferred, firstIsChinese: firstIsChinese)
        guard let best = mostLikely(weights) else { return "en" }
        // "und" is undetermined, not a language. The corrections below still
        // run, and if none of them names a language the result stays nil.
        let detected: String? = best.language == NLLanguage.undetermined.rawValue ? nil : best.language
        let confidence = best.confidence
        // Count once, on the text the user selected. A later pass over the
        // non-ASCII remainder reuses this count: the Han characters are the
        // same ones, and the mixed-script flag must not be recalculated on a
        // remainder that no longer contains the Latin half.
        let stats = inheritedStats ?? hanStats(clean)

        if detected == "zh-Hans" || detected == "zh-Hant" {
            // No Han character was counted. Dividing by that count would be
            // 0/0, which is not a number, and "not a number ≥ 0.9" does not
            // hold. The result is Traditional.
            if stats.han == 0 { return "zh-Hant" }
            let simplifiedRatio = Double(stats.han - stats.traditional) / Double(stats.han)
            return simplifiedRatio >= 0.9 ? "zh-Hans" : "zh-Hant"
        }

        if stats.mixed, detected == "en" {
            let englishWords = englishWordCount(clean)
            let rest = lettersWithoutASCII(clean)
            if englishWords > rest.count || rest.isEmpty { return "en" }
            // The remainder has no ASCII letters left. Detecting it again when
            // it is the same string would never finish, so that case falls
            // through and the English answer stands.
            if rest != clean {
                let sub = resolve(text: rest, preferred: preferred, firstIsChinese: firstIsChinese,
                                  rawHypotheses: rawHypotheses, inheritedStats: stats)
                // English, or no language, from the remainder is not used.
                // This pass's answer stands, and the short-text rules below still run.
                if let sub, sub != "en" { return sub }
            }
        }

        if digitShare(clean) > 0.7 { return "en" }

        if confidence < 0.5, clean.count <= 10, isWhollyLatin(clean),
           let english = weights["en"], english > 0.1 {
            return "en"
        }

        if clean.count <= 3 {
            if let detected, preferred.contains(detected), confidence > 0.3 { return detected }
            if isWhollyLatin(clean) { return "en" }
        }

        return detected
    }

    // MARK: - Characters

    struct ScriptStats: Equatable {
        var han = 0
        /// Han characters that change when written as Simplified.
        var traditional = 0
        var latin = 0
        var other = 0
        /// At least two of Latin, Han and any other letter are present.
        var mixed: Bool {
            [latin > 0, han > 0, other > 0].filter { $0 }.count >= 2
        }
    }

    static func hanStats(_ text: String) -> ScriptStats {
        var stats = ScriptStats()
        for character in text {
            let piece = String(character)
            if isHan(piece) {
                stats.han += 1
                if piece != toSimplified(piece) { stats.traditional += 1 }
            } else if character.isASCII && character.isLetter {
                stats.latin += 1
            } else if isLatinPiece(piece) {
                stats.latin += 1
            } else if character.isLetter {
                stats.other += 1
            }
        }
        return stats
    }

    /// Traditional characters written as Simplified, one character at a time.
    /// 「軟體」 becomes 「软体」, not 「软件」: the transform does not look up a word.
    static func toSimplified(_ text: String) -> String {
        text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
    }

    /// Simplified characters written as Traditional.
    static func toTraditional(_ text: String) -> String {
        text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
    }

    // MARK: - Private

    private static func mostLikely(_ weights: [String: Double]) -> (language: String, confidence: Double)? {
        guard let best = weights.max(by: { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key > rhs.key
        }) else { return nil }
        return (best.key, best.value)
    }

    private static func isHan(_ text: String) -> Bool {
        text.range(of: #"^\p{Han}$"#, options: .regularExpression) != nil
    }

    private static func isLatinPiece(_ text: String) -> Bool {
        text.range(of: #"^\p{Latin}$"#, options: .regularExpression) != nil
    }

    private static func isWhollyLatin(_ text: String) -> Bool {
        text.range(of: #"^\p{Latin}+$"#, options: .regularExpression) != nil
    }

    /// Share of characters that are digits. Exactly 0.7 does not count as heavy.
    private static func digitShare(_ text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        let digits = text.filter(\.isNumber).count
        return Double(digits) / Double(text.count)
    }

    /// Words whose letters are all ASCII. A Han character is its own word, so
    /// it never counts as one of these. Digits are not letters and drop out.
    private static func englishWordCount(_ text: String) -> Int {
        wordPieces(text).filter { piece in
            let letters = piece.filter(\.isLetter)
            return !letters.isEmpty && letters.allSatisfy(\.isASCII)
        }.count
    }

    /// Drop ASCII letters and keep the other letters.
    private static func lettersWithoutASCII(_ text: String) -> String {
        String(text.filter { $0.isLetter && !$0.isASCII })
    }

    /// Pieces of `text` in order. Whitespace and punctuation split them, except
    /// `@ # / • " - .`, which stay inside a piece. Each Han character is its
    /// own piece.
    private static func wordPieces(_ text: String) -> [String] {
        var separators = CharacterSet.whitespacesAndNewlines
        separators.formUnion(.punctuationCharacters)
        separators.remove(charactersIn: "@#/•\"-.")
        var pieces: [String] = []
        var current = ""
        for character in text {
            let piece = String(character)
            if let scalar = piece.unicodeScalars.first, separators.contains(scalar) {
                if !current.isEmpty {
                    pieces.append(current)
                    current = ""
                }
                continue
            }
            if isHan(piece) {
                if !current.isEmpty {
                    pieces.append(current)
                    current = ""
                }
                pieces.append(piece)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
