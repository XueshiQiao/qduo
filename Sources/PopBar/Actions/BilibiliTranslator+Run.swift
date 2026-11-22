import Foundation
import AIModelKit

/// Sending the text to Bilibili's translator and judging the answer. What is
/// sent and how the reply is read are in `BilibiliTranslator.swift`.
extension BilibiliTranslator {

    private static let log = FileLog("PopBar.BilibiliTranslate")

    enum Failure: Error, Equatable {
        case noTarget
        case alreadyInTarget(String)
        /// A target the service's prompt has no name for.
        case unsupportedTarget(String)
        /// The service could not be reached or refused the request.
        case service(ConnectionProblem)
        /// It answered, but not with `{"text": …}`.
        case badReply
        /// The answer is in another language than the target: the text was
        /// most likely taken as an instruction ("translate this into French").
        case wrongLanguage(expected: String, got: String)
    }

    /// The editor's language list for this engine, named in the app's language.
    static func targets() -> [SystemTranslator.Target] {
        languages.map { SystemTranslator.Target(id: $0.id, name: SystemTranslator.displayName(of: $0.id)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Translate

    /// `targetID` and `secondID` as for `SystemTranslator.translate`.
    static func translate(_ text: String, to targetID: String?, second secondID: String? = nil) async -> Result<String, Failure> {
        guard let targetID = targetID?.trimmingCharacters(in: .whitespaces), !targetID.isEmpty else {
            return .failure(.noTarget)
        }
        let locales = Locale.preferredLanguages
        let preferred = TranslateDecision.preferredLanguages(targetID: targetID, secondSetting: secondID, locales: locales)
        let firstIsChinese = TranslateDecision.isChinese(TranslateDecision.language(ofTargetID: targetID))
        let detected = LanguageDetection.resolve(text: text, preferred: preferred, firstIsChinese: firstIsChinese) { chunk in
            LanguageDetection.rawHypotheses(chunk, preferred: preferred)
        }
        let resolvedID: String
        switch TranslateDecision.decide(source: detected, targetID: targetID, secondSetting: secondID, locales: locales) {
        case .alreadyInTarget(let language):
            log.info("\(text.count) char(s) already in \(language) — not translated")
            return .failure(.alreadyInTarget(language))
        case .convertChinese(let to):
            // Simplified ↔ Traditional stays on this Mac, as with the system engine.
            log.info("\(text.count) char(s), \(detected ?? "auto") → \(to): ICU conversion")
            return .success(to == "zh-Hant" ? LanguageDetection.toTraditional(text) : LanguageDetection.toSimplified(text))
        case .translate(_, let to):
            resolvedID = to
        }
        guard let name = promptName(for: resolvedID) else {
            log.info("\(text.count) char(s), \(detected ?? "auto") → \(resolvedID): not a language of this service")
            return .failure(.unsupportedTarget(resolvedID))
        }

        let started = Date()
        let content: String
        do {
            content = try await send(prompt(text: text, targetName: name))
        } catch let error where error is CancellationError || (error as? URLError)?.code == .cancelled {
            // The action was given up on; the caller checks that and shows nothing.
            return .failure(.service(.badResponse("cancelled")))
        } catch let failure as Failure {
            log.error("\(text.count) char(s) → \(resolvedID): \(failure)")
            return .failure(failure)
        } catch {
            let problem = ConnectionProblem(error)
            log.error("\(text.count) char(s) → \(resolvedID): \(problem.description)")
            return .failure(.service(problem))
        }
        // Privacy: never log the text, only its size and languages.
        guard let translation = translation(fromReply: content) else {
            log.error("\(text.count) char(s) → \(resolvedID): the reply is not {\"text\": …} (\(content.count) char(s))")
            return .failure(.badReply)
        }
        guard isPlausible(translation, in: resolvedID) else {
            let got = language(of: translation) ?? "?"
            log.error("\(text.count) char(s) → \(resolvedID): the answer is in \(got)")
            return .failure(.wrongLanguage(expected: resolvedID, got: got))
        }
        log.info("\(text.count) char(s), \(detected ?? "auto") → \(resolvedID): done in \(String(format: "%.0f ms", Date().timeIntervalSince(started) * 1000))")
        return .success(translation)
    }

    // MARK: - Network

    private static func send(_ prompt: String) async throws -> String {
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(prompt: prompt))
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = ModelListParser.errorMessage(in: data) ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw Failure.service(ConnectionProblem(ModelServiceError.http(status: status, message: message)))
        }
        do {
            return try ChatResponseParser.text(in: data, format: .openAI)
        } catch {
            throw Failure.badReply
        }
    }
}
