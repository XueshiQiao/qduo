import Foundation

/// One thing `ConfigValidator` found.
struct ConfigIssue: Codable, Equatable {
    enum Severity: String, Codable {
        /// The app would not do what the file says: a wrong type, a value it
        /// cannot read, an action that cannot run. `apply` refuses the file.
        case error
        /// Probably a mistake, but the app copes: an unknown key, an app that
        /// is not installed, a missing API key. `apply --strict` refuses it.
        case warning
        /// Worth telling the user, never a reason to refuse: a script action,
        /// which runs a shell command.
        case note
    }
    let severity: Severity
    let path: String
    let message: String
}

/// What the validator may ask about this Mac. Every answer is optional: nil
/// means "cannot tell here", and nothing is reported for it. The unit tests
/// pass fixed answers; the app and the command line pass `ValidationEnvironment.live`.
struct ValidationEnvironment {
    /// Whether this Mac can draw the SF Symbol of that name.
    var symbolExists: (String) -> Bool? = { _ in nil }
    /// Whether an app with that bundle id is installed.
    var appInstalled: (String) -> Bool? = { _ in nil }
    /// Whether the Keychain holds an API key for that provider. nil also for a
    /// provider that needs no key (Ollama).
    var hasAPIKey: (String) -> Bool? = { _ in nil }
    /// The thinking values a provider accepts, or nil when anything goes.
    var thinkingValues: (String) -> [String]? = { _ in nil }
    /// Whether a file exists — for an action's own icon picture.
    var fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }

    /// Answers nothing about this Mac; only the file itself is checked.
    static let fileOnly = ValidationEnvironment()
}

/// Checks a config file the way the app will read it, before it is put in
/// place. Used by the command line (`cli validate`, `cli apply`) so an AI
/// agent finds out what is wrong with an edit before the user does.
///
/// Two layers. The schema (`SchemaCheck`) catches wrong types, values that are
/// not allowed and numbers out of range. The checks here catch what a schema
/// cannot say: two actions with one id, a hotkey the app cannot parse, an
/// `openURL` action with no address, a speak action naming a reader that does
/// not exist, the same combination for two hotkeys.
///
/// The app itself is lenient on purpose — it reads what it can and keeps the
/// rest — so a mistake in the file never shows up as an error there. It shows
/// up as an action that quietly does nothing. This is where it is caught.
enum ConfigValidator {

    struct Report: Codable, Equatable {
        let issues: [ConfigIssue]
        var errors: [ConfigIssue] { issues.filter { $0.severity == .error } }
        var warnings: [ConfigIssue] { issues.filter { $0.severity == .warning } }
        var notes: [ConfigIssue] { issues.filter { $0.severity == .note } }

        /// Whether the file may be applied. Strict also refuses warnings.
        func passes(strict: Bool) -> Bool {
            errors.isEmpty && (!strict || warnings.isEmpty)
        }
    }

    /// Kinds whose produced text `output` applies to (`PopBarActionConfig.hasOutput`).
    static let kindsWithOutput: Set<String> = ["ai", "transform", "shortcut", "script", "systemTranslate"]

    /// The fields that belong to one kind only, and the kinds they belong to.
    /// One of these on an action of another kind is ignored by the app.
    static let kindFields: [String: Set<String>] = [
        "prompt": ["ai"],
        "modelOverride": ["ai"],
        "url": ["openURL"],
        "openIn": ["openURL"],
        "op": ["transform"],
        "shortcut": ["shortcut"],
        "script": ["script"],
        "keys": ["keystroke"],
        "targetLanguage": ["systemTranslate"],
        "secondLanguage": ["systemTranslate"],
        "engine": ["systemTranslate"],
        "reader": ["speak"],
        "output": kindsWithOutput,
    ]

    static func validate(data: Data, env: ValidationEnvironment = .fileOnly) -> Report {
        // JSONSerialization first, only for its error: it says where the
        // problem is ("around line 12, column 5"), which JSONDecoder does not.
        do {
            _ = try JSONSerialization.jsonObject(with: data)
        } catch {
            let detail = ((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String) ?? error.localizedDescription
            return Report(issues: [ConfigIssue(severity: .error, path: "(file)",
                                               message: "is not valid JSON: \(detail)")])
        }
        guard let document = try? JSONDecoder().decode(JSONValue.self, from: data),
              document.objectValue != nil else {
            return Report(issues: [ConfigIssue(severity: .error, path: "(file)",
                                               message: "must be one JSON object, { … }")])
        }
        return validate(document: document, env: env)
    }

    static func validate(document: JSONValue, env: ValidationEnvironment = .fileOnly) -> Report {
        var issues: [ConfigIssue] = []

        if let schema = SchemaCheck() {
            for finding in schema.check(document) {
                issues.append(ConfigIssue(severity: finding.kind == .violation ? .error : .warning,
                                          path: finding.path, message: finding.message))
            }
        } else {
            // Never skip the schema quietly: everything would then "pass".
            issues.append(ConfigIssue(severity: .error, path: "(schema)",
                                      message: "this build's own schema could not be read, so the file cannot be checked; report this as a bug"))
        }

        checkHotKeys(document, &issues)
        checkModels(document, env, &issues)
        let readers = checkSpeech(document, &issues)
        checkRings(document, &issues)
        checkAppLists(document, env, &issues)
        if let actions = document[path: "actions"]?.arrayValue {
            checkActions(actions, readers: readers, env: env, &issues)
        }
        return Report(issues: issues)
    }

    // MARK: - Hotkeys

    private static func checkHotKeys(_ doc: JSONValue, _ issues: inout [ConfigIssue]) {
        var popup: HotKeyTrigger?
        if let raw = doc[path: "popup.hotKey"]?.stringValue, !raw.isEmpty {
            popup = HotKeyTrigger(configString: raw)
            if popup == nil {
                issues.append(ConfigIssue(severity: .error, path: "popup.hotKey",
                                          message: "\"\(raw)\" is not a key combination the app can read (e.g. \"opt+x\", or \"cmd+cmd\" for a double tap of Command)"))
            }
        }
        var ocr: HotKeyTrigger?
        if let raw = doc[path: "ocr.hotKey"]?.stringValue {
            ocr = HotKeyTrigger(configString: raw)
            if ocr == nil {
                issues.append(ConfigIssue(severity: .error, path: "ocr.hotKey",
                                          message: "\"\(raw)\" is not a key combination the app can read (e.g. \"shift+cmd+s\")"))
            }
        }
        if let popup, let ocr, popup == ocr {
            issues.append(ConfigIssue(severity: .error, path: "popup.hotKey",
                                      message: "is the same combination as ocr.hotKey; the two hotkeys must differ"))
        }
    }

    // MARK: - Models

    private static func checkModels(_ doc: JSONValue, _ env: ValidationEnvironment, _ issues: inout [ConfigIssue]) {
        guard let provider = doc[path: "models.provider"]?.stringValue else { return }
        if provider == "custom",
           (doc[path: "models.custom.apiURL"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(ConfigIssue(severity: .warning, path: "models.custom.apiURL",
                                      message: "is empty, so AI actions have nowhere to send requests while models.provider is \"custom\""))
        }
        if env.hasAPIKey(provider) == false {
            issues.append(ConfigIssue(severity: .warning, path: "models.provider",
                                      message: "is \"\(provider)\", but no API key for \(provider) is saved on this Mac. AI actions will fail until the user adds one in Settings › AI Models. Never ask for the key in chat."))
        }
        if let thinking = doc[path: "models.thinking"]?.stringValue,
           let allowed = env.thinkingValues(provider), !allowed.contains(thinking) {
            issues.append(ConfigIssue(severity: .warning, path: "models.thinking",
                                      message: "\"\(thinking)\" is not a thinking value \(provider) offers (\(allowed.map { "\"\($0)\"" }.joined(separator: ", "))); the app will use the nearest one"))
        }
    }

    // MARK: - Speech

    /// Returns the reader ids a speak action may name.
    private static func checkSpeech(_ doc: JSONValue, _ issues: inout [ConfigIssue]) -> Set<String> {
        var ids: Set<String> = ["system"]
        for (i, reader) in (doc[path: "speech.readers"]?.arrayValue ?? []).enumerated() {
            guard let id = reader[path: "id"]?.stringValue else { continue }
            if ids.contains(id) {
                issues.append(ConfigIssue(severity: .error, path: "speech.readers[\(i)].id",
                                          message: "\"\(id)\" is used by another reader (or is the reserved \"system\")"))
            }
            ids.insert(id)
        }
        if let reader = doc[path: "speech.defaultReader"]?.stringValue, !ids.contains(reader) {
            issues.append(ConfigIssue(severity: .error, path: "speech.defaultReader",
                                      message: "\"\(reader)\" is not \"system\" or the id of a reader in speech.readers"))
        }
        return ids
    }

    // MARK: - Ring geometry

    private static func checkRings(_ doc: JSONValue, _ issues: inout [ConfigIssue]) {
        for section in ["wheel", "donut"] {
            guard let outer = doc[path: "\(section).outerRadius"]?.doubleValue,
                  let inner = doc[path: "\(section).innerRadius"]?.doubleValue else { continue }
            if inner > outer - 26 {
                issues.append(ConfigIssue(severity: .warning, path: "\(section).innerRadius",
                                          message: "should be at least 26 below outerRadius (\(Int(outer))); the app will shrink it"))
            }
        }
    }

    // MARK: - App lists

    private static func checkAppLists(_ doc: JSONValue, _ env: ValidationEnvironment, _ issues: inout [ConfigIssue]) {
        for path in ["popup.excludedApps", "popup.copyFirstApps", "popup.terminalApps", "history.excludedApps"] {
            for (i, item) in (doc[path: path]?.arrayValue ?? []).enumerated() {
                guard let id = item.stringValue else { continue }
                if id.contains(" ") || !id.contains(".") {
                    issues.append(ConfigIssue(severity: .error, path: "\(path)[\(i)]",
                                              message: "\"\(id)\" does not look like a bundle id (e.g. \"com.apple.Terminal\"); find it with: osascript -e 'id of app \"Name\"'"))
                } else if env.appInstalled(id) == false {
                    // A note, not a warning: the built-in lists name apps on
                    // purpose that most Macs do not have.
                    issues.append(ConfigIssue(severity: .note, path: "\(path)[\(i)]",
                                              message: "no app with bundle id \"\(id)\" is installed on this Mac"))
                }
            }
        }
    }

    // MARK: - Actions

    private static func checkActions(_ actions: [JSONValue], readers: Set<String>,
                                     env: ValidationEnvironment, _ issues: inout [ConfigIssue]) {
        var ids: [String: String] = [:]        // id → path of the first action with it
        var urlNames: [String: String] = [:]

        func visit(_ action: JSONValue, path: String, depth: Int) {
            guard let object = action.objectValue else { return }   // the schema already said so

            if let id = object["id"]?.stringValue {
                if id.trimmingCharacters(in: .whitespaces).isEmpty {
                    issues.append(ConfigIssue(severity: .error, path: "\(path).id", message: "is empty; give the action a fresh UUID"))
                } else if let first = ids[id] {
                    issues.append(ConfigIssue(severity: .error, path: "\(path).id",
                                              message: "\"\(id)\" is also the id of \(first); every action needs its own id (a new action gets a fresh UUID)"))
                } else {
                    ids[id] = path
                }
            }
            if let name = object["urlName"]?.stringValue {
                if let first = urlNames[name] {
                    issues.append(ConfigIssue(severity: .error, path: "\(path).urlName",
                                              message: "\"\(name)\" is also the urlName of \(first); urlName must be unique"))
                } else {
                    urlNames[name] = path
                }
            }
            if let title = object["title"]?.stringValue, title.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(ConfigIssue(severity: .warning, path: "\(path).title", message: "is empty, so the popup shows no name"))
            }

            let kind = object["kind"]?.stringValue ?? ""
            checkKind(kind, object, path: path, readers: readers, env: env, &issues)

            for (field, kinds) in kindFields.sorted(by: { $0.key < $1.key })
            where object[field] != nil && !kinds.contains(kind) && !kind.isEmpty {
                // A note: the settings window leaves these behind when an
                // action's kind is changed, so existing files are full of them.
                issues.append(ConfigIssue(severity: .note, path: "\(path).\(field)",
                                          message: "is ignored on a \"\(kind)\" action; it is for \(kinds.sorted().joined(separator: ", "))"))
            }

            if let symbol = object["iconSymbol"]?.stringValue, env.symbolExists(symbol) == false {
                issues.append(ConfigIssue(severity: .warning, path: "\(path).iconSymbol",
                                          message: "\"\(symbol)\" is not an SF Symbol this Mac can draw; the action would show no icon"))
            }
            if let image = object["iconImage"]?.stringValue, !env.fileExists(ActionIconStore.url(for: image)) {
                issues.append(ConfigIssue(severity: .warning, path: "\(path).iconImage",
                                          message: "\"\(image)\" does not exist (looked for \(ActionIconStore.url(for: image).path)); iconSymbol is drawn instead"))
            }

            if let children = object["children"]?.arrayValue {
                if depth >= 1, !children.isEmpty {
                    issues.append(ConfigIssue(severity: .error, path: "\(path).children",
                                              message: "groups are one level deep: the actions inside a group cannot have children of their own (the app drops them)"))
                } else {
                    for (i, child) in children.enumerated() {
                        visit(child, path: "\(path).children[\(i)]", depth: depth + 1)
                    }
                }
            }
        }

        for (i, action) in actions.enumerated() {
            visit(action, path: "actions[\(i)]", depth: 0)
        }
    }

    private static func checkKind(_ kind: String, _ action: [String: JSONValue], path: String,
                                  readers: Set<String>, env: ValidationEnvironment,
                                  _ issues: inout [ConfigIssue]) {
        func text(_ key: String) -> String? {
            guard let value = action[key]?.stringValue else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : value
        }
        func missing(_ key: String, _ why: String) {
            issues.append(ConfigIssue(severity: .error, path: "\(path).\(key)", message: why))
        }

        switch kind {
        case "ai":
            if text("prompt") == nil {
                issues.append(ConfigIssue(severity: .warning, path: "\(path).prompt",
                                          message: "is empty, so the model gets the selection with no instruction"))
            }
            if let override = action["modelOverride"]?.objectValue {
                let provider = override["provider"]?.stringValue ?? ""
                let known = providerIDs
                if provider.isEmpty || (!known.isEmpty && !known.contains(provider)) {
                    missing("modelOverride.provider", "\"\(provider)\" is not a provider the app knows (\(known.sorted().joined(separator: ", ")))")
                } else if env.hasAPIKey(provider) == false {
                    issues.append(ConfigIssue(severity: .warning, path: "\(path).modelOverride.provider",
                                              message: "no API key for \(provider) is saved on this Mac; this action will fail until the user adds one in Settings › AI Models"))
                }
                if (override["model"]?.stringValue ?? "").isEmpty {
                    missing("modelOverride.model", "is empty; name the model, as the provider spells it")
                }
                if let effort = override["reasoningEffort"]?.stringValue,
                   let allowed = env.thinkingValues(provider), !allowed.contains(effort) {
                    issues.append(ConfigIssue(severity: .warning, path: "\(path).modelOverride.reasoningEffort",
                                              message: "\"\(effort)\" is not a thinking value \(provider) offers (\(allowed.map { "\"\($0)\"" }.joined(separator: ", "))); the app will use the nearest one"))
                }
            }
        case "openURL":
            guard let url = text("url") else {
                missing("url", "an openURL action needs an address, e.g. \"https://www.google.com/search?q={text}\"")
                return
            }
            if !url.contains(URLTemplate.placeholder) {
                issues.append(ConfigIssue(severity: .warning, path: "\(path).url",
                                          message: "has no {text}, so the selection is not put into the address"))
            }
        case "transform":
            if text("op") == nil { missing("op", "a transform action needs an op, e.g. \"uppercase\"") }
        case "shortcut":
            if text("shortcut") == nil { missing("shortcut", "a shortcut action needs the name of a Shortcut") }
        case "script":
            guard let script = text("script") else {
                missing("script", "a script action needs a shell command")
                return
            }
            issues.append(ConfigIssue(severity: .note, path: "\(path).script",
                                      message: "runs a shell command on the selected text: \(script). Make sure the user asked for exactly this; the app also asks the user before it runs the first time."))
        case "keystroke":
            guard let keys = text("keys") else {
                missing("keys", "a keystroke action needs one key combination, e.g. \"shift+cmd+k\"")
                return
            }
            if KeyCombo(strictConfigString: keys) == nil {
                missing("keys", "\"\(keys)\" is not one key combination the app can read (e.g. \"delete\" or \"shift+cmd+k\")")
            }
        case "systemTranslate":
            guard let target = text("targetLanguage") else {
                missing("targetLanguage", "a systemTranslate action needs the language to translate into, e.g. \"zh\", \"en\", \"ja\"")
                return
            }
            if action["engine"]?.stringValue == BilibiliTranslator.engineID {
                let supported = BilibiliTranslator.languages.map(\.id)
                if !supported.contains(target) {
                    missing("targetLanguage", "\"\(target)\" is not a language the Bilibili translator has (\(supported.joined(separator: ", ")))")
                }
                if let second = text("secondLanguage"), second != "none", !supported.contains(second) {
                    missing("secondLanguage", "\"\(second)\" is not a language the Bilibili translator has")
                }
            }
        case "speak":
            if let reader = text("reader"), !readers.contains(reader) {
                missing("reader", "\"\(reader)\" is not \"system\" or the id of a reader in speech.readers")
            }
        default:
            break
        }
    }

    /// The providers the schema lists for `models.provider` — the same list the
    /// app's provider table has (a schema test keeps the two equal).
    static let providerIDs: Set<String> = {
        guard let data = ConfigSchema.json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let properties = root["properties"] as? [String: Any],
              let models = (properties["models"] as? [String: Any])?["properties"] as? [String: Any],
              let provider = models["provider"] as? [String: Any],
              let list = provider["enum"] as? [String] else { return [] }
        return Set(list)
    }()
}
