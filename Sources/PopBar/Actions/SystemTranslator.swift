import AppKit
import SwiftUI
import Translation

/// The `systemTranslate` kind: translate with macOS's own translator (the
/// Translation framework), no model and no API key. On the device, with one
/// exception: the Shortcut route below.
///
/// The target language is the action's own `targetLanguage`, chosen by the user
/// from the list the system supports — never guessed. The source is detected
/// from the text (`LanguageDetection`). `secondLanguage` says what happens when
/// the text is already in the target language: absent follows the system's
/// second language, "none" shows the "already in this language" message, and
/// any other id is that language. Simplified and Traditional Chinese are
/// converted on this Mac, one character at a time, and never take a route below.
/// Which source and which target that is is decided in `TranslateDecision`
/// before any of those routes.
///
/// The framework offers two ways in, and which one works depends on the system
/// and on whether the language pair is downloaded:
///
/// - macOS 26+, pair downloaded: `TranslationSession(installedSource:target:)`
///   is created directly. No window. Measured on macOS 27: 20–80 ms.
/// - Anything else on macOS 15+: the session can only be obtained from SwiftUI's
///   `.translationTask`, which must sit in a view inside a window. That is also
///   the only route that shows the system's "Download Languages" sheet, and the
///   sheet is shown ON that window — so for a pair that still needs downloading
///   the window is made visible; for a downloaded one it stays transparent.
///
/// Before asking for a download, the app's own Shortcut is tried, if the user
/// has added it (`viaShortcut`). Unlike everything above, that route sends the
/// text to Apple's translation server and needs a connection.
///
/// macOS 13/14 have no API that returns a translation to the app, so the kind is
/// not offered there (`isAvailable`).
enum SystemTranslator {

    private static let log = FileLog("PopBar.SystemTranslate")

    static var isAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// Debug knob: take the `.translationTask` route even where the direct one
    /// would do, so that route can be exercised on macOS 26+.
    /// `defaults write <bundle id> systemTranslate.forceViewPath -bool YES`
    private static var forceViewPath: Bool {
        UserDefaults.standard.bool(forKey: "systemTranslate.forceViewPath")
    }

    enum Failure: Error {
        case needsNewerSystem
        case noTarget
        case alreadyInTarget(String)
        case unsupportedPair(source: String, target: String)
        case didNotStart
        /// The download sheet was shown and translating still failed.
        case notDownloaded
        /// Superseded by a newer request, or the action was abandoned: nothing to show.
        case cancelled
        case failed(String)
    }

    /// `targetID` is the action's `targetLanguage`: an identifier from
    /// `supportedTargets()`, e.g. "zh", "zh-TW", "en-GB". `secondID` is the
    /// action's `secondLanguage`: nil follows the system's second language,
    /// "none" keeps the "already in this language" message, and any other id
    /// is that language.
    static func translate(_ text: String, to targetID: String?, second secondID: String? = nil) async -> Result<String, Failure> {
        guard #available(macOS 15.0, *) else { return .failure(.needsNewerSystem) }
        guard let targetID = targetID?.trimmingCharacters(in: .whitespaces), !targetID.isEmpty else {
            return .failure(.noTarget)
        }
        return await translate15(text, to: targetID, second: secondID)
    }

    /// A language to offer in the editor's picker.
    struct Target: Identifiable, Hashable {
        /// Stored in the action: the system's minimal identifier ("zh", "zh-TW").
        let id: String
        let name: String
    }

    /// Every language the system translator can translate into, named in the
    /// app's language and sorted by that name. Empty before macOS 15.
    static func supportedTargets() async -> [Target] {
        guard #available(macOS 15.0, *) else { return [] }
        let languages = await LanguageAvailability().supportedLanguages
        let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? Locale.current.identifier)
        // A language listed more than once (English for the US and the UK) is
        // told apart by region; Chinese by script, which is what readers know
        // it by (简体 / 繁體), not by country.
        let codes = languages.compactMap { $0.languageCode?.identifier }
        let targets = languages.map { language -> Target in
            let full = Locale.Language(identifier: language.maximalIdentifier)
            let code = full.languageCode?.identifier ?? language.minimalIdentifier
            var nameID = language.minimalIdentifier
            if codes.filter({ $0 == code }).count > 1 {
                if code == "zh", let script = full.script?.identifier {
                    nameID = "zh-\(script)"
                } else if let region = full.region?.identifier {
                    nameID = "\(code)-\(region)"
                }
            }
            return Target(id: language.minimalIdentifier,
                          name: locale.localizedString(forIdentifier: nameID) ?? language.minimalIdentifier)
        }
        return targets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The name `supportedTargets()` would give an identifier, for messages.
    static func displayName(of id: String) -> String {
        let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? Locale.current.identifier)
        // Chinese by script, as in the picker: "zh-TW" reads 繁體, not Taiwan.
        let full = Locale.Language(identifier: Locale.Language(identifier: id).maximalIdentifier)
        var nameID = id
        if full.languageCode?.identifier == "zh", let script = full.script?.identifier { nameID = "zh-\(script)" }
        return locale.localizedString(forIdentifier: nameID) ?? id
    }

    /// Same language and, where both names say so, the same script. The
    /// Shortcut's language list needs this: Simplified and Traditional are not
    /// interchangeable there, while English and British English are.
    static func isSameLanguage(_ a: String, _ b: String) -> Bool {
        let x = Locale.Language(identifier: Locale.Language(identifier: a).maximalIdentifier)
        let y = Locale.Language(identifier: Locale.Language(identifier: b).maximalIdentifier)
        guard x.languageCode == y.languageCode else { return false }
        guard let sx = x.script, let sy = y.script else { return true }
        return sx == sy
    }

    @available(macOS 15.0, *)
    private static func translate15(_ text: String, to targetID: String, second secondID: String?) async -> Result<String, Failure> {
        let locales = Locale.preferredLanguages
        let preferred = TranslateDecision.preferredLanguages(targetID: targetID, secondSetting: secondID, locales: locales)
        // The action's target itself. The preferred list can start with another
        // language when the target is not one the recognizer answers with.
        let firstIsChinese = TranslateDecision.isChinese(TranslateDecision.language(ofTargetID: targetID))
        let detected = LanguageDetection.resolve(text: text, preferred: preferred, firstIsChinese: firstIsChinese) { chunk in
            LanguageDetection.rawHypotheses(chunk, preferred: preferred)
        }
        let decision = TranslateDecision.decide(source: detected, targetID: targetID, secondSetting: secondID, locales: locales)
        let sourceID: String?
        let resolvedID: String
        switch decision {
        case .alreadyInTarget(let language):
            log.info("\(text.count) char(s) already in \(language) — not translated")
            return .failure(.alreadyInTarget(language))
        case .convertChinese(let to):
            let converted = to == "zh-Hant" ? LanguageDetection.toTraditional(text) : LanguageDetection.toSimplified(text)
            log.info("\(text.count) char(s), \(detected ?? "auto") \(chineseBranch(source: detected, targetID: targetID, secondID: secondID)) → \(to)")
            return .success(converted)
        case .translate(let source, let to):
            if let note = translationBranch(source: source, targetID: targetID, resolvedID: to, secondID: secondID, locales: locales) {
                log.info("\(text.count) char(s), \(source ?? "auto") \(note)")
            }
            sourceID = source
            resolvedID = to
        }
        let source = sourceID.map { Locale.Language(identifier: $0) }
        let target = Locale.Language(identifier: resolvedID)
        let started = Date()

        let status: LanguageAvailability.Status
        if let source {
            status = await LanguageAvailability().status(from: source, to: target)
        } else {
            do { status = try await LanguageAvailability().status(for: text, to: target) }
            catch { return .failure(.failed(error.localizedDescription)) }
        }
        // Privacy: never log the text, only its size and languages.
        log.info("\(text.count) char(s), \(sourceID ?? "auto") → \(resolvedID): \(status)")

        switch status {
        case .unsupported:
            return .failure(.unsupportedPair(source: sourceID ?? "?", target: resolvedID))
        case .installed:
            if #available(macOS 26.0, *), let source, !forceViewPath {
                do {
                    let out = try await directTranslate(text, source: source, target: target)
                    log.info("direct: done in \(ms(since: started))")
                    return .success(out)
                } catch is CancellationError {
                    return .failure(.cancelled)
                } catch {
                    // Deleted between the status check and now, say: the view
                    // route can still ask for the download — on a window the
                    // user can see, or its sheet would be invisible.
                    log.error("direct failed (\(error.localizedDescription)) — trying the view route")
                    let now = await LanguageAvailability().status(from: source, to: target)
                    return await viaView(text, source: source, target: target,
                                         needsDownload: now != .installed, started: started)
                }
            }
            return await viaView(text, source: source, target: target, needsDownload: false, started: started)
        case .supported:
            break
        @unknown default:
            break
        }
        // The pair still needs downloading. A Shortcut can translate it without
        // the download, if the user has the one this looks for.
        if let out = await viaShortcut(text, sourceID: sourceID, targetID: resolvedID, started: started) {
            return .success(out)
        }
        if Task.isCancelled { return .failure(.cancelled) }
        return await viaView(text, source: source, target: target, needsDownload: true, started: started)
    }

    /// "second language" when the text was already the target and went to the
    /// action's second language. "fallback" when that second language was the
    /// source as well, so English or Simplified Chinese was used instead.
    private static func translationBranch(source: String?, targetID: String, resolvedID: String,
                                          secondID: String?, locales: [String]) -> String? {
        guard secondID != "none", let source else { return nil }
        let first = TranslateDecision.language(ofTargetID: targetID)
        guard source == first, resolvedID != targetID else { return nil }
        let second = TranslateDecision.secondLanguage(setting: secondID, locales: locales)
        if second == source { return "fallback → \(resolvedID)" }
        return "second language → \(resolvedID)"
    }

    /// Local Simplified ↔ Traditional. When the text was already the target and
    /// the second language is the other script, say so. The fallback never
    /// lands here: a Chinese source falls back to English, which is translated.
    private static func chineseBranch(source: String?, targetID: String, secondID: String?) -> String {
        let first = TranslateDecision.language(ofTargetID: targetID)
        if secondID != "none", source == first { return "second language, ICU conversion" }
        return "ICU conversion"
    }

    // MARK: - Shortcut (pair not downloaded)

    /// The Shortcut looked for, by name. It is this app's own, built by
    /// `scripts/make-translate-shortcut.py` and shipped as `Translate.shortcut`;
    /// the user adds it from the action's editor (`addShortcut`).
    ///
    /// Its "Translate Text" step runs in the system's Shortcut runner, which
    /// translates a pair that is not downloaded by asking Apple's server (the
    /// Translation framework, above, never does). Measured on macOS 27: about
    /// half a second once the runner is warm; offline it fails after 11 s with
    /// "Translation server did not respond in time", and the download is asked
    /// for as before.
    ///
    /// Named after the slug, not the app name, so Debug and Release share it.
    static let shortcutName = "\(Brand.slug)-translate"

    static func isShortcutInstalled() async -> Bool {
        await ProcessRunner.shortcutNames().contains(shortcutName)
    }

    /// Hand the bundled Shortcut to the Shortcuts app, which asks the user to
    /// add it. Nothing can add one silently: the system refuses an import from
    /// an app without Apple's own entitlement (measured: "Unauthorized add
    /// attempt"). The Shortcut is named after its file, hence the copy.
    @MainActor
    @discardableResult
    static func addShortcut() -> Bool {
        guard let bundled = Bundle.main.url(forResource: "Translate", withExtension: "shortcut") else {
            log.error("add shortcut: Translate.shortcut is not in the bundle")
            return false
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Brand.slug)-shortcut", isDirectory: true)
        let file = dir.appendingPathComponent("\(shortcutName).shortcut")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.copyItem(at: bundled, to: file)
        } catch {
            log.error("add shortcut: could not copy the file — \(error.localizedDescription)")
            return false
        }
        let opened = NSWorkspace.shared.open(file)
        log.info("add shortcut: handed '\(shortcutName)' to the Shortcuts app: \(opened)")
        return opened
    }

    /// Run the Shortcut once on a fixed word, right after the user added it. The
    /// first run of a new Shortcut makes the Shortcuts app ask for permission;
    /// asked for here, the question comes up over Settings. Left to the first
    /// real translation, it would come up beside the popup, and the click that
    /// answers it would close the popup and lose that translation.
    static func authorizeShortcut() async {
        let result = await ProcessRunner.runShortcut(shortcutName, input: "text=Hello&to=es_ES&from=en_US")
        switch result {
        case .success: log.info("shortcut '\(shortcutName)': first run done")
        case .failure(let failure): log.error("shortcut '\(shortcutName)': first run failed — \(failure)")
        }
    }

    /// nil = the route was not taken or did not work: fall back to the download.
    @available(macOS 15.0, *)
    private static func viaShortcut(_ text: String, sourceID: String?, targetID: String,
                                    started: Date) async -> String? {
        guard await ProcessRunner.shortcutNames().contains(shortcutName) else {
            log.info("shortcut route: '\(shortcutName)' is not installed")
            return nil
        }
        let languages = await LanguageAvailability().supportedLanguages
        guard let to = shortcutCode(for: targetID, among: languages) else {
            log.info("shortcut route: no code for target \(targetID)")
            return nil
        }
        // Percent-encode everything but unreserved characters: the Shortcut
        // splits its input on "&" and "=".
        var unreserved = CharacterSet(charactersIn: "-._~")
        unreserved.insert(charactersIn: "a"..."z")
        unreserved.insert(charactersIn: "A"..."Z")
        unreserved.insert(charactersIn: "0"..."9")
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        var input = "text=\(encoded)&to=\(to)"
        // Without a source the Shortcut detects it itself.
        let from = sourceID.flatMap { shortcutCode(for: $0, among: languages) }
        if let from { input += "&from=\(from)" }

        switch await ProcessRunner.runShortcut(shortcutName, input: input) {
        case .success(let out):
            // As it came, like the other two routes (measured: the Shortcut
            // adds no newline of its own).
            guard !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                log.error("shortcut route (\(from ?? "auto") → \(to)): empty output")
                return nil
            }
            log.info("shortcut route (\(from ?? "auto") → \(to)): done in \(ms(since: started))")
            return out
        case .failure(let failure):
            log.error("shortcut route (\(from ?? "auto") → \(to)): \(failure)")
            return nil
        }
    }

    /// The Shortcut's "Translate Text" step only takes a language WITH its
    /// region, as the system lists it: "es_ES", "zh_CN", "zh_TW", "en_GB".
    /// Measured: "es", "zh", "zh-Hans" and "es_MX" are all refused.
    @available(macOS 15.0, *)
    private static func shortcutCode(for id: String, among languages: [Locale.Language]) -> String? {
        let match = languages.first { $0.minimalIdentifier == id }
            ?? languages.first { isSameLanguage($0.minimalIdentifier, id) }
        guard let match, let code = match.languageCode?.identifier,
              let region = match.region?.identifier
                ?? Locale.Language(identifier: match.maximalIdentifier).region?.identifier
        else { return nil }
        return "\(code)_\(region)"
    }

    @available(macOS 15.0, *)
    private static func viaView(_ text: String, source: Locale.Language?, target: Locale.Language,
                                needsDownload: Bool, started: Date) async -> Result<String, Failure> {
        do {
            let out = try await TranslationHost.shared.translate(text, source: source, target: target,
                                                                 visible: needsDownload)
            log.info("view route (download needed: \(needsDownload)): done in \(ms(since: started))")
            return .success(out)
        } catch let failure as Failure {
            log.error("view route: \(failure)")
            return .failure(failure)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            log.error("view route failed: \(error.localizedDescription)")
            return .failure(.failed(error.localizedDescription))
        }
    }

    // MARK: - Direct (macOS 26+)

    /// Sessions are reused per language pair: the first call on a new session is
    /// several times slower than the next ones (measured: 80 ms, then 20 ms).
    @available(macOS 26.0, *)
    @MainActor private static var sessions: [String: TranslationSession] = [:]

    @available(macOS 26.0, *)
    @MainActor
    private static func directTranslate(_ text: String, source: Locale.Language,
                                        target: Locale.Language) async throws -> String {
        let key = "\(source.minimalIdentifier)>\(target.minimalIdentifier)"
        let session = sessions[key] ?? TranslationSession(installedSource: source, target: target)
        sessions[key] = session
        do {
            return try await session.translate(text).targetText
        } catch {
            sessions[key] = nil
            throw error
        }
    }

    private static func ms(since start: Date) -> String {
        String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000)
    }
}

// MARK: - The .translationTask route (macOS 15+)

/// Owns the one window the `.translationTask` route needs. Transparent and
/// click-through while it only hosts the task; shown, and the app brought
/// forward, when the system has to ask the user to download a language — its
/// sheet appears on this window.
@available(macOS 15.0, *)
@MainActor
private final class TranslationHost: NSObject, NSWindowDelegate {

    static let shared = TranslationHost()

    private static let log = FileLog("PopBar.SystemTranslate")

    /// How long to wait for the system to hand over a session. It arrives within
    /// milliseconds (measured: 6 ms, and the download sheet came after it), so a
    /// long wait means the route is not working at all. Only the hand-over is
    /// timed, never the download that may follow it.
    private static let sessionTimeout: UInt64 = 10_000_000_000

    final class Model: ObservableObject {
        @Published var configuration: TranslationSession.Configuration?
    }

    private struct Job {
        let id: Int
        let text: String
        /// nil once the action gave up on the result (its popup closed) while the
        /// download window stays up: the download carries on, nobody is waiting.
        var continuation: CheckedContinuation<String, Error>?
        var gotSession = false
        /// The window is shown for a language download.
        let visible: Bool
    }

    private let model = Model()
    private var job: Job?
    private var nextID = 0
    /// The app that was frontmost before the window was shown for a download,
    /// to hand the focus back to — a Replace only writes into the frontmost app.
    private var previousApp: NSRunningApplication?
    private lazy var window: NSPanel = makeWindow()

    func translate(_ text: String, source: Locale.Language?, target: Locale.Language,
                   visible: Bool) async throws -> String {
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                // One at a time: a newer request supersedes an unfinished one.
                if job != nil { Self.log.info("finish: superseded by a newer request") }
                // The app to hand the focus back to passes to the newer request:
                // if the old one brought this app forward, the newer one (asked
                // for from a pinned popup, say) still has to give it back.
                let handBackTo = previousApp
                finish(throwing: CancellationError())
                previousApp = handBackTo
                job = Job(id: id, text: text, continuation: continuation, visible: visible)
                show(visible: visible)
                var config = TranslationSession.Configuration(source: source, target: target)
                if model.configuration?.source == source, model.configuration?.target == target {
                    config = model.configuration!
                    config.invalidate()
                }
                model.configuration = config
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: Self.sessionTimeout)
                    guard let self, let job = self.job, job.id == id, !job.gotSession else { return }
                    Self.log.error("no session from the system after 10 s")
                    self.finish(throwing: SystemTranslator.Failure.didNotStart)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.job?.id == id else { return }
                self.abandon()
            }
        }
    }

    /// The action no longer wants the result (its popup closed, or another action
    /// ran). A transparent window just goes. A download window STAYS: clicking
    /// anywhere else closes the popup, and taking the download away with it would
    /// make the user start over. The action is released at once; the window
    /// closes by itself when the download and translation finish, or on Done.
    private func abandon() {
        guard var current = job else { return }
        guard current.visible else {
            Self.log.info("finish: the action was cancelled (its popup closed or another action ran)")
            finish(throwing: CancellationError())
            return
        }
        Self.log.info("the action was cancelled; the download window stays until the download is done")
        current.continuation?.resume(throwing: CancellationError())
        current.continuation = nil
        job = current
        // The user went elsewhere on purpose: do not pull the focus back later.
        previousApp = nil
    }

    /// Called by `.translationTask` with a live session.
    func run(_ session: TranslationSession) async {
        guard var current = job, !current.gotSession else { return }
        Self.log.info("got a session from .translationTask")
        current.gotSession = true
        job = current
        do {
            let response = try await session.translate(current.text)
            guard job?.id == current.id else { return }
            finish(returning: response.targetText)
        } catch {
            guard job?.id == current.id else { return }
            Self.log.info("finish: session.translate threw \(type(of: error)) — \(error.localizedDescription)")
            // After the download sheet, a failure most likely means the language
            // is not there yet (Done before it finished, or still downloading).
            // A cancellation stays one.
            let cancelled = error is CancellationError
            finish(throwing: current.visible && !cancelled ? SystemTranslator.Failure.notDownloaded : error)
        }
    }

    private func finish(returning value: String) {
        finish(.success(value))
    }

    private func finish(throwing error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<String, Error>) {
        guard let current = job else { return }
        job = nil
        hide()
        guard let continuation = current.continuation else {
            Self.log.info("download window closed; nobody was waiting for the result")
            return
        }
        guard let app = previousApp else {
            continuation.resume(with: result)
            return
        }
        previousApp = nil
        // The window was shown and took the focus: give it back. Not for a
        // cancellation — a newer request is taking over and needs the focus.
        guard case .success = result else {
            if !(result.failureIsCancellation) { app.activate() }
            continuation.resume(with: result)
            return
        }
        // A result: wait until the app really is frontmost again (activation is
        // asynchronous), so a Replace that follows finds its app in front.
        app.activate()
        Task { @MainActor in
            for _ in 0..<20 where NSWorkspace.shared.frontmostApplication != app {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            Self.log.info("focus back to the previous app: \(NSWorkspace.shared.frontmostApplication == app)")
            continuation.resume(with: result)
        }
    }

    private func show(visible: Bool) {
        if visible {
            // Where the user is looking: the screen under the pointer.
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2,
                                              y: frame.midY - window.frame.height / 2))
            }
            window.alphaValue = 1
            window.ignoresMouseEvents = false
            if previousApp == nil, let front = NSWorkspace.shared.frontmostApplication,
               front != NSRunningApplication.current {
                previousApp = front
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            // Never key: the app the text came from keeps its focus, so a
            // Replace still lands there.
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
        }
    }

    private func hide() {
        // A download sheet still up (the job was superseded) would otherwise be
        // left on a window that is gone or about to turn transparent.
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        window.orderOut(nil)
    }

    /// Closing the window by hand gives up on the translation it was hosting.
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            if job != nil { Self.log.info("finish: window closed by hand") }
            // Nothing takes over after a close by hand, so the focus goes back
            // here (`finish` leaves it alone for a cancellation).
            let app = previousApp
            finish(throwing: SystemTranslator.Failure.cancelled)
            app?.activate()
        }
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                            styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = L("systemTranslate.window.title")
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: HostView(model: model, host: self))
        panel.delegate = self
        return panel
    }

    private struct HostView: View {
        @ObservedObject var model: Model
        let host: TranslationHost

        var body: some View {
            VStack(spacing: 10) {
                Image(systemName: "character.bubble").font(.system(size: 28)).foregroundStyle(.secondary)
                Text(L("systemTranslate.window.body"))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .translationTask(model.configuration) { session in
                await host.run(session)
            }
        }
    }
}

private extension Result where Failure == Error {
    var failureIsCancellation: Bool {
        if case .failure(let error) = self {
            return error is CancellationError || (error as? SystemTranslator.Failure).map {
                if case .cancelled = $0 { return true } else { return false }
            } ?? false
        }
        return false
    }
}
