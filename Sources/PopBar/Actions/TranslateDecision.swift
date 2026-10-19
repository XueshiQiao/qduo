import Foundation
import NaturalLanguage

/// Where a system translation goes, once the source language is already known.
/// This file does not look at the text and does not run a recognizer. The
/// caller passes the detected source, the action's two settings, and the
/// system language list (`Locale.preferredLanguages` in the app, a fixed list
/// in tests).
///
/// "none" is an opt-out stored in the action: do not translate when the text
/// is already in the target language. It has to be compared as that exact
/// word before any locale lookup. `Locale` reads the identifier "none" as
/// English, so handing it to `language(ofTargetID:)` would turn the opt-out
/// into English.
enum TranslateDecision {

    enum Outcome: Equatable {
        /// Ask the system translator. `source` nil means the translator may
        /// detect the source itself. `toTargetID` is an id in the same form
        /// the action stores ("zh", "zh-TW", "en", "en-GB").
        case translate(source: String?, toTargetID: String)
        /// Simplified ↔ Traditional, done locally. `to` is "zh-Hans" or "zh-Hant".
        case convertChinese(to: String)
        /// The text is already in the target language and the action opted out
        /// of a second language. The message uses the stored target id.
        case alreadyInTarget(String)
    }

    /// A stored target id, or one entry of `Locale.preferredLanguages`, as the
    /// code detection uses. "zh" is Simplified. "en-GB" is "en". "ar-AE" is "ar".
    /// "mn" is Mongolian's recognizer code, "mn-Mong".
    ///
    /// "zh-HK" has no script in the short id. Its maximal identifier does, and
    /// that script is Hant, so this returns "zh-Hant". Treating every
    /// script-less zh-* as Simplified would call Hong Kong Chinese Simplified.
    /// Reading the script from the maximal identifier is a deliberate
    /// difference, and Hong Kong Chinese stays Traditional.
    ///
    /// "und" is undetermined. Its maximal identifier is English, so that
    /// expansion is not used. The result is "und", and the preferred lists
    /// drop it.
    static func language(ofTargetID id: String) -> String {
        let parsed = Locale.Language(identifier: id)
        if parsed.languageCode?.identifier == NLLanguage.undetermined.rawValue {
            return NLLanguage.undetermined.rawValue
        }
        let full = Locale.Language(identifier: parsed.maximalIdentifier)
        guard let code = full.languageCode?.identifier, !code.isEmpty else { return id }
        if code == "zh" {
            if full.script?.identifier == "Hant" { return "zh-Hant" }
            return "zh-Hans"
        }
        // The recognizer's Mongolian code is "mn-Mong". A system language of
        // "mn" has to use that code, or the preferred list drops it.
        if code == "mn" { return NLLanguage.mongolian.rawValue }
        return code
    }

    /// "zh-Hans" and "zh-Hant". A bare "zh" is not, because the callers of this
    /// pass the result of `language(ofTargetID:)` and that result carries a script.
    static func isChinese(_ language: String) -> Bool {
        language.hasPrefix("zh-")
    }

    /// English goes to Simplified Chinese. Anything else goes to English.
    static func autoTarget(_ language: String) -> String {
        language == "en" ? "zh-Hans" : "en"
    }

    /// The system list, mapped and de-duplicated, keeping only languages the
    /// recognizer is allowed to answer with. Undetermined is left out.
    static func systemPreferredLanguages(from locales: [String]) -> [String] {
        var languages: [String] = []
        for locale in locales {
            let language = language(ofTargetID: locale)
            guard language != NLLanguage.undetermined.rawValue,
                  LanguageDetection.codes.contains(language),
                  !languages.contains(language) else { continue }
            languages.append(language)
        }
        return languages
    }

    /// The system's second language. The first distinct entry is dropped. The
    /// next one is the answer. When the list has nothing left, or what is left
    /// is the same language again, English stands in, and if that English is
    /// itself the first language the answer is Simplified Chinese.
    static func systemSecondLanguage(locales: [String]) -> String {
        let list = systemPreferredLanguages(from: locales)
        let sysFirst = list.first ?? "en"
        let sysSecond = list.filter { $0 != sysFirst }.first ?? "en"
        if sysSecond == sysFirst { return autoTarget(sysFirst) }
        return sysSecond
    }

    /// The second language the action will use, as a detection code. A concrete
    /// setting is mapped. "none" and a missing setting both use the system.
    static func secondLanguage(setting: String?, locales: [String]) -> String {
        if let setting, setting != "none" { return language(ofTargetID: setting) }
        return systemSecondLanguage(locales: locales)
    }

    /// Languages to hint and to boost, most preferred first: the action's
    /// target, then its second language, then the system list. "none" does not
    /// change this list. It only changes `decide`. Duplicates are dropped.
    /// Undetermined is dropped, and so is a code the recognizer cannot answer with.
    static func preferredLanguages(targetID: String, secondSetting: String?, locales: [String]) -> [String] {
        let first = language(ofTargetID: targetID)
        let second = secondLanguage(setting: secondSetting, locales: locales)
        var languages: [String] = []
        for language in [first, second] + systemPreferredLanguages(from: locales) {
            guard language != NLLanguage.undetermined.rawValue,
                  LanguageDetection.codes.contains(language),
                  !languages.contains(language) else { continue }
            languages.append(language)
        }
        return languages
    }

    /// Same language, ignoring script and region. "zh-Hans", "zh" and "zh-TW"
    /// are one language. "en" and "en-GB" are one. "yue" and "zh" are not.
    /// The editor uses this to hide a second language that names the target
    /// again. It must not be used on the opt-out word "none": see the type comment.
    static func sameLanguageCode(_ a: String, _ b: String) -> Bool {
        guard let x = Locale.Language(identifier: a).languageCode,
              let y = Locale.Language(identifier: b).languageCode else { return false }
        return x == y
    }

    static func decide(source: String?, targetID: String, secondSetting: String?, locales: [String]) -> Outcome {
        let first = language(ofTargetID: targetID)
        guard let source else {
            return .translate(source: nil, toTargetID: targetID)
        }
        if secondSetting == "none" {
            if source == first { return .alreadyInTarget(targetID) }
            if isChinese(source), isChinese(first) { return .convertChinese(to: first) }
            return .translate(source: source, toTargetID: targetID)
        }

        let second = secondLanguage(setting: secondSetting, locales: locales)
        var target = first
        var tookSecond = false
        if source == first {
            target = second
            tookSecond = true
        }
        if target == source {
            target = autoTarget(source)
            tookSecond = false
        }
        if isChinese(source), isChinese(target) { return .convertChinese(to: target) }
        return .translate(source: source, toTargetID: storageID(for: target, first: first, targetID: targetID,
                                                                tookSecond: tookSecond, secondSetting: secondSetting))
    }

    /// The id to store in the translation request. The action's own target id
    /// is kept when the text is going there, so "en-GB" stays "en-GB". An
    /// explicit second language is kept the same way. A language that came from
    /// the system list, or from the English / Simplified fallback, is written
    /// as "en", "zh", "zh-TW", or the code itself.
    private static func storageID(for target: String, first: String, targetID: String,
                                  tookSecond: Bool, secondSetting: String?) -> String {
        if target == first { return targetID }
        if tookSecond, let secondSetting, secondSetting != "none" { return secondSetting }
        switch target {
        case "en": return "en"
        case "zh-Hans": return "zh"
        case "zh-Hant": return "zh-TW"
        default: return target
        }
    }
}
