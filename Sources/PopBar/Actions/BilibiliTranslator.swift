import Foundation
import NaturalLanguage

/// The `systemTranslate` kind with `engine: "bilibili"`: translate with
/// Bilibili's free Index-Translate service. Online, no key, no account, and it
/// runs on every macOS the app supports (the system translator needs 15+).
///
/// Which source and target is decided exactly as for the system translator
/// (`LanguageDetection`, `TranslateDecision`), so the action's target and
/// second-language settings mean the same with either engine.
///
/// The model follows instructions, and a selection that reads like one ("write
/// a poem about cats") is carried out instead of translated when it is sent as
/// it is. Measured (#34): wrapped as the value of a JSON object, with the
/// service's own "keep the JSON format" constraint, those are translated like
/// any other text. So the text always goes out as `{"text": …}` and the answer
/// is read back from the same shape. A reply that is not that shape, or not in
/// the target language, counts as a failure; the caller then tries the system
/// translator.
///
/// This file holds what is decided without the network (the prompt, the
/// request body, reading the reply, the languages), so it is unit-tested on its
/// own; `BilibiliTranslator+Run.swift` sends the request.
enum BilibiliTranslator {

    static let engineID = "bilibili"

    /// The service's address and model, as its README gives them.
    static let chatURL = URL(string: "https://index-translate.bilibili.com/v1/chat/completions")!
    static let model = "Index-Translate-35B-A3B"
    /// Measured: 0.5–4 s for a short line up to a paragraph.
    static let timeout: TimeInterval = 30

    /// The languages offered with this engine: the ones the service's own client
    /// names (`call_api.py`), with the name its prompt uses. Ids are written the
    /// way the system translator writes them, so an action can switch engine and
    /// keep its target.
    static let languages: [(id: String, promptName: String)] = [
        ("zh", "简体中文"), ("zh-TW", "繁体中文"), ("en", "英语"), ("ja", "日语"), ("ko", "韩语"),
        ("fr", "法语"), ("de", "德语"), ("es", "西班牙语"), ("pt", "葡萄牙语"), ("it", "意大利语"),
        ("ru", "俄语"), ("ar", "阿拉伯语"), ("nl", "荷兰语"), ("pl", "波兰语"), ("ro", "罗马尼亚语"),
        ("sv", "瑞典语"), ("tr", "土耳其语"), ("hi", "印地语"), ("vi", "越南语"), ("th", "泰语"),
        ("id", "印尼语"), ("ms", "马来语"), ("fil", "菲律宾语"), ("uk", "乌克兰语"), ("fa", "波斯语"),
        ("cs", "捷克语"), ("el", "希腊语"), ("da", "丹麦语"), ("hu", "匈牙利语"), ("fi", "芬兰语"),
        ("nb", "书面挪威语"), ("sk", "斯洛伐克语"), ("bg", "保加利亚语"),
    ]

    /// The name the prompt uses for a target id: "zh", "zh-Hans" and "zh-CN" are
    /// Simplified, "zh-TW", "zh-HK" and "zh-Hant" Traditional, "en-GB" English.
    static func promptName(for id: String) -> String? {
        if id.hasPrefix("zh") {
            return TranslateDecision.language(ofTargetID: id) == "zh-Hant" ? "繁体中文" : "简体中文"
        }
        if let exact = languages.first(where: { $0.id == id }) { return exact.promptName }
        return languages.first { !$0.id.hasPrefix("zh") && TranslateDecision.sameLanguageCode($0.id, id) }?.promptName
    }

    // MARK: - Pieces (pure, tested)

    /// The service's own constrained prompt (`call_api.py`), with the text as
    /// the value of a JSON object and its "keep the JSON format" constraint.
    static func prompt(text: String, targetName: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["text": text], options: [.withoutEscapingSlashes])) ?? Data()
        let source = String(data: data, encoding: .utf8) ?? "{}"
        return """
        请将以下文本翻译成\(targetName)，并且严格遵循所有约束要求。

        【源文】
        \(source)

        【约束要求】
        1. 【硬性要求】保留源文中的 JSON 格式标记不变

        请以相同的 JSON 格式输出翻译结果，key 保持不变，value 为对应译文。只输出 JSON，不要有任何额外说明。
        """
    }

    /// The request body: as the service's client sends it, thinking off (with
    /// it on, the reasoning can replace the translation), greedy decoding.
    static func requestBody(prompt: String) -> [String: Any] {
        [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
            "temperature": 0,
            "max_tokens": 4096,
            "chat_template_kwargs": ["enable_thinking": false],
        ]
    }

    /// The translation inside a reply, or nil when the reply is not
    /// `{"text": "…"}`. A code fence or a reasoning block around it is allowed.
    static func translation(fromReply reply: String) -> String? {
        var s = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        // A reasoning block before the answer (thinking is asked off, but may
        // come anyway). Only one that opens the reply: a "</think>" inside the
        // translation (text about models, say) is part of it. The answer
        // follows the block's last closing tag, so a quoted one inside the
        // reasoning does not cut it short.
        if s.hasPrefix("<think>"), let end = s.range(of: "</think>", options: .backwards) {
            s = String(s[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.hasPrefix("```") {
            s = String(s.drop { $0 != "\n" }).trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasSuffix("```") { s = String(s.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard let data = s.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else { return nil }
        return text
    }

    /// Whether an answer can be a translation into `targetID`. false only when
    /// it is clearly something else, such as French for a Chinese target.
    ///
    /// Chinese, Japanese and Korean are told by their script: an answer with Han
    /// characters, kana or Hangul passes. The recognizer is unsure there when
    /// code or long English names are mixed in (measured: a Chinese sentence
    /// around `NSApplicationDelegate.applicationDidFinishLaunching(_:)` read as
    /// Italian, 0.74). Other targets go by the recognizer, when it is sure.
    static func isPlausible(_ answer: String, in targetID: String) -> Bool {
        let scalars = answer.unicodeScalars
        let han = scalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
        let kana = scalars.contains { (0x3040...0x30FF).contains($0.value) }
        let hangul = scalars.contains { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) }
        if TranslateDecision.sameLanguageCode(targetID, "zh") { return han || language(of: answer) == nil }
        if TranslateDecision.sameLanguageCode(targetID, "ja") { return kana || han || language(of: answer) == nil }
        if TranslateDecision.sameLanguageCode(targetID, "ko") { return hangul || language(of: answer) == nil }
        guard let got = language(of: answer) else { return true }
        return TranslateDecision.sameLanguageCode(got, targetID)
    }

    /// The language of an answer, when it is long enough to tell: "en",
    /// "zh-Hans", "ja"… nil for a word or two, where a guess would be noise.
    static func language(of text: String) -> String? {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 12 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.8 else { return nil }
        return language.rawValue
    }
}
