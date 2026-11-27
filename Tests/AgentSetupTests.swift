import XCTest

// MARK: - The checks on a config file

final class ConfigValidatorTests: XCTestCase {

    private func report(_ json: String, env: ValidationEnvironment = .fileOnly) -> ConfigValidator.Report {
        ConfigValidator.validate(data: Data(json.utf8), env: env)
    }

    private func paths(_ issues: [ConfigIssue]) -> [String] { issues.map(\.path) }

    /// Every action the app itself can write — the seed and every template —
    /// passes with no error and no warning. This is what catches the schema
    /// falling behind the app: a key the app writes that the schema does not
    /// list (`schemaVersion` was one) turns into a warning on every action.
    func testWhatTheAppWritesPassesCleanly() throws {
        var actions = DefaultActions.seed()
        for section in ActionTemplates.sections() { actions += section.actions }
        // Templates leave some fields for the user to fill in; fill them the way
        // the editor makes the user do before saving.
        actions = actions.map { action in
            var a = action
            if a.kind == .shortcut { a.shortcut = "Make Note" }
            if a.kind == .systemTranslate, a.targetLanguage == nil { a.targetLanguage = "zh" }
            return a
        }
        let encoded = try JSONEncoder().encode(actions)
        let list = try JSONDecoder().decode(JSONValue.self, from: encoded)
        let document: JSONValue = .object([
            "version": 1,
            "popup": .object(["enabled": true, "style": "liquidGlass", "hotKey": "opt+opt", "hotKeyEnabled": true]),
            "ocr": .object(["enabled": true, "hotKey": "shift+cmd+s"]),
            "models": .object(["provider": "deepseek", "model": "deepseek-chat", "thinking": "none"]),
            "actions": list,
        ])
        let result = ConfigValidator.validate(document: document)
        XCTAssertEqual(result.errors, [], "the app's own actions must not be errors")
        XCTAssertEqual(result.warnings, [], "the app's own actions must not be warnings")
    }

    func testBrokenJSONSaysWhere() {
        let r = report("{ \"popup\": { \"style\": \"capsule\", } ")
        XCTAssertEqual(r.errors.count, 1)
        XCTAssertTrue(r.errors[0].message.contains("not valid JSON"))
        XCTAssertFalse(report("[1, 2]").passes(strict: false), "the top level must be an object")
    }

    func testSchemaViolations() {
        let r = report("""
        { "popup": { "style": "bubble", "resultFontSize": 40, "simulateCopy": "yes" },
          "general": { "language": null },
          "actions": [ { "id": "a", "title": "T" } ] }
        """)
        let errors = paths(r.errors)
        XCTAssertTrue(errors.contains("popup.style"), "not an allowed value")
        XCTAssertTrue(errors.contains("popup.resultFontSize"), "above the maximum")
        XCTAssertTrue(errors.contains("popup.simulateCopy"), "wrong type")
        XCTAssertTrue(errors.contains("actions[0]"), "kind is required")
        XCTAssertFalse(errors.contains("general.language"), "null is allowed there")
    }

    func testATypoIsAWarningWithASuggestion() throws {
        let r = report(#"{ "popup": { "hotkey": "opt+x" } }"#)
        XCTAssertTrue(r.errors.isEmpty)
        let warning = try XCTUnwrap(r.warnings.first { $0.path == "popup.hotkey" })
        XCTAssertTrue(warning.message.contains("\"hotKey\""), warning.message)
        XCTAssertTrue(r.passes(strict: false))
        XCTAssertFalse(r.passes(strict: true))
    }

    func testActionsInsideGroupsAreCheckedAgainstTheSameDefinition() {
        let r = report("""
        { "actions": [ { "id": "g", "title": "G", "kind": "group",
                         "children": [ { "id": "c", "title": "C", "kind": "teleport" } ] } ] }
        """)
        XCTAssertTrue(paths(r.errors).contains("actions[0].children[0].kind"))
    }

    func testIdsAndURLNamesMustBeUnique() {
        let r = report("""
        { "actions": [ { "id": "x", "title": "A", "kind": "copy", "urlName": "go" },
                       { "id": "g", "title": "G", "kind": "group",
                         "children": [ { "id": "x", "title": "B", "kind": "copy", "urlName": "go" } ] } ] }
        """)
        XCTAssertTrue(paths(r.errors).contains("actions[1].children[0].id"))
        XCTAssertTrue(paths(r.errors).contains("actions[1].children[0].urlName"))
    }

    func testGroupsAreOneLevelDeep() {
        let r = report("""
        { "actions": [ { "id": "g", "title": "G", "kind": "group", "children": [
            { "id": "h", "title": "H", "kind": "group", "children": [ { "id": "i", "title": "I", "kind": "copy" } ] } ] } ] }
        """)
        XCTAssertTrue(paths(r.errors).contains("actions[0].children[0].children"))
    }

    func testEachKindNeedsItsFields() {
        let r = report("""
        { "actions": [
          { "id": "1", "title": "U", "kind": "openURL" },
          { "id": "2", "title": "T", "kind": "transform" },
          { "id": "3", "title": "S", "kind": "shortcut", "shortcut": "  " },
          { "id": "4", "title": "K", "kind": "keystroke", "keys": "cmd+a+c" },
          { "id": "5", "title": "L", "kind": "systemTranslate" },
          { "id": "6", "title": "B", "kind": "systemTranslate", "engine": "bilibili", "targetLanguage": "tlh" },
          { "id": "7", "title": "R", "kind": "speak", "reader": "nobody" },
          { "id": "8", "title": "X", "kind": "script" }
        ] }
        """)
        let errors = paths(r.errors)
        for expected in ["actions[0].url", "actions[1].op", "actions[2].shortcut", "actions[3].keys",
                         "actions[4].targetLanguage", "actions[5].targetLanguage", "actions[6].reader", "actions[7].script"] {
            XCTAssertTrue(errors.contains(expected), expected)
        }
    }

    func testValidActionsOfEachKindPass() {
        let r = report("""
        { "speech": { "defaultReader": "r1", "readers": [ { "id": "r1", "engine": "minimax" } ] },
          "actions": [
          { "id": "1", "title": "U", "kind": "openURL", "url": "https://example.com/?q={text}", "openIn": "preview" },
          { "id": "2", "title": "T", "kind": "transform", "op": "pinyin", "output": "replace" },
          { "id": "4", "title": "K", "kind": "keystroke", "keys": "shift+cmd+k" },
          { "id": "6", "title": "B", "kind": "systemTranslate", "engine": "bilibili", "targetLanguage": "ja", "secondLanguage": "none" },
          { "id": "7", "title": "R", "kind": "speak", "reader": "system" },
          { "id": "8", "title": "R2", "kind": "speak", "reader": "r1" }
        ] }
        """)
        XCTAssertEqual(r.errors, [])
        XCTAssertEqual(r.warnings, [])
    }

    func testAScriptIsAlwaysANoteNeverABlock() throws {
        let r = report(#"{ "actions": [ { "id": "1", "title": "S", "kind": "script", "script": "wc -w" } ] }"#)
        XCTAssertTrue(r.passes(strict: true))
        let note = try XCTUnwrap(r.notes.first { $0.path == "actions[0].script" })
        XCTAssertTrue(note.message.contains("wc -w"))
    }

    func testAFieldForAnotherKindIsANote() {
        let r = report(#"{ "actions": [ { "id": "1", "title": "C", "kind": "copy", "url": "https://x" } ] }"#)
        XCTAssertTrue(paths(r.notes).contains("actions[0].url"))
        XCTAssertTrue(r.passes(strict: true))
    }

    func testHotKeys() {
        XCTAssertTrue(paths(report(#"{ "popup": { "hotKey": "opt+nothing" } }"#).errors).contains("popup.hotKey"))
        XCTAssertTrue(report(#"{ "popup": { "hotKey": "" } }"#).errors.isEmpty, "empty = none recorded")
        let same = report(#"{ "popup": { "hotKey": "shift+cmd+s" }, "ocr": { "hotKey": "cmd+shift+s" } }"#)
        XCTAssertTrue(same.errors.contains { $0.message.contains("same combination") })
        XCTAssertTrue(report(#"{ "popup": { "hotKey": "cmd+cmd" }, "ocr": { "hotKey": "shift+cmd+s" } }"#).errors.isEmpty)
    }

    /// The override's third key is `reasoningEffort` — what the app writes and
    /// reads. Without it the app ignores the whole override.
    func testModelOverrideNeedsAllThreeKeys() {
        let missing = report("""
        { "actions": [ { "id": "1", "title": "A", "kind": "ai", "prompt": "p",
                         "modelOverride": { "provider": "openai", "model": "gpt-5", "effort": "low" } } ] }
        """)
        XCTAssertTrue(missing.errors.contains { $0.path == "actions[0].modelOverride" && $0.message.contains("reasoningEffort") })

        let unknown = report("""
        { "actions": [ { "id": "1", "title": "A", "kind": "ai", "prompt": "p",
                         "modelOverride": { "provider": "skynet", "model": "m", "reasoningEffort": "" } } ] }
        """)
        XCTAssertTrue(paths(unknown.errors).contains("actions[0].modelOverride.provider"))

        let fine = report("""
        { "actions": [ { "id": "1", "title": "A", "kind": "ai", "prompt": "p",
                         "modelOverride": { "provider": "openai", "model": "gpt-5", "reasoningEffort": "low" } } ] }
        """)
        XCTAssertEqual(fine.errors, [])
    }

    /// The decoder the app uses really does drop an override without
    /// `reasoningEffort` — the reason the check above is an error.
    func testTheAppIgnoresAnOverrideWithoutReasoningEffort() throws {
        let json = #"[{ "id": "1", "title": "A", "kind": "ai", "modelOverride": { "provider": "openai", "model": "gpt-5", "effort": "low" } }]"#
        let action = try XCTUnwrap(try JSONDecoder().decode([PopBarActionConfig].self, from: Data(json.utf8)).first)
        XCTAssertNil(action.modelOverride)
    }

    func testThisMacAnswersBecomeWarnings() {
        var env = ValidationEnvironment.fileOnly
        env.symbolExists = { $0 != "not.a.symbol" }
        env.appInstalled = { $0 != "com.example.missing" }
        env.hasAPIKey = { $0 == "ollama" ? nil : false }
        env.thinkingValues = { _ in ["", "low", "high"] }
        let r = report("""
        { "models": { "provider": "openai", "model": "gpt-5", "thinking": "max" },
          "popup": { "excludedApps": ["com.example.missing", "not a bundle id"] },
          "actions": [ { "id": "1", "title": "A", "kind": "copy", "iconSymbol": "not.a.symbol" },
                       { "id": "2", "title": "B", "kind": "copy", "iconImage": "nope-\(UUID().uuidString).png" } ] }
        """, env: env)
        let warnings = paths(r.warnings)
        XCTAssertTrue(warnings.contains("models.provider"), "no key saved")
        XCTAssertTrue(warnings.contains("models.thinking"))
        XCTAssertTrue(warnings.contains("actions[0].iconSymbol"))
        XCTAssertTrue(warnings.contains("actions[1].iconImage"))
        XCTAssertTrue(paths(r.notes).contains("popup.excludedApps[0]"), "not installed is only a note")
        XCTAssertTrue(paths(r.errors).contains("popup.excludedApps[1]"))
    }

    func testSpeechReaders() {
        let r = report("""
        { "speech": { "defaultReader": "gone", "readers": [ { "id": "a", "engine": "minimax" },
                                                            { "id": "a", "engine": "minimax" } ] } }
        """)
        XCTAssertTrue(paths(r.errors).contains("speech.defaultReader"))
        XCTAssertTrue(paths(r.errors).contains("speech.readers[1].id"))
    }

    func testProviderListComesFromTheSchema() {
        XCTAssertTrue(ConfigValidator.providerIDs.contains("deepseek"))
        XCTAssertTrue(ConfigValidator.providerIDs.contains("custom"))
    }
}

// MARK: - Backups and the file itself

final class ConfigFilesTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("agent-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func location(config: URL? = nil) -> ConfigLocation {
        ConfigLocation(configURL: config ?? dir.appendingPathComponent("config.json"),
                       backupDirectory: dir.appendingPathComponent("backups"))
    }

    func testBackupsSortNewestFirstAndAreCapped() throws {
        let loc = location()
        try ConfigFiles.write(Data("{}".utf8), to: loc)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<(ConfigFiles.keepBackups + 3) {
            try ConfigFiles.backUpCurrent(loc, now: start.addingTimeInterval(Double(i)))
        }
        let list = ConfigFiles.backups(loc)
        XCTAssertEqual(list.count, ConfigFiles.keepBackups)
        XCTAssertEqual(list.first?.file, "config-\(ConfigFiles.timestamp(start.addingTimeInterval(Double(ConfigFiles.keepBackups + 2)))).json")
        XCTAssertFalse(list.first?.created.isEmpty ?? true)
    }

    func testTwoBackupsInOneMillisecondBothKept() throws {
        let loc = location()
        try ConfigFiles.write(Data("{}".utf8), to: loc)
        let now = Date()
        let a = try XCTUnwrap(try ConfigFiles.backUpCurrent(loc, now: now))
        let b = try XCTUnwrap(try ConfigFiles.backUpCurrent(loc, now: now))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(ConfigFiles.backups(loc).count, 2)
    }

    func testNoFileNoBackup() throws {
        XCTAssertNil(try ConfigFiles.backUpCurrent(location()))
    }

    func testWritingThroughASymlinkKeepsTheSymlink() throws {
        let real = dir.appendingPathComponent("dotfiles/config.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"a\":1}".utf8).write(to: real)
        let link = dir.appendingPathComponent("config.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let loc = location(config: link)
        XCTAssertTrue(loc.isSymlink)

        try ConfigFiles.write(Data("{\"a\":2}".utf8), to: loc)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path)
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "{\"a\":2}")
    }
}

// MARK: - The command line, against a fake running app

/// Stands in for the running app. `prepare` can change the file (as the
/// app's own flush would), and after `commit` the app "comes back" with a
/// new pid.
private final class FakeApp: AgentIPCClient {
    var running: [AgentIPC.Instance]
    var onPrepare: (() -> Void)?
    private(set) var calls: [String] = []
    private var exited: Set<Int32> = []
    var comesBack = true

    init(running: [AgentIPC.Instance] = []) { self.running = running }

    static func instance(pid: Int32, bundleID: String = "test.app") -> AgentIPC.Instance {
        AgentIPC.Instance(pid: pid, bundleID: bundleID, name: "Test", version: "1", build: "1",
                          executable: "/x", configPath: "/c", windowVisible: false)
    }

    func ping(configPath: String) -> [AgentIPC.Instance] { calls.append("ping"); return running }

    func prepare(configPath: String, flush: Bool) -> (requestID: String, instances: [AgentIPC.Instance]) {
        calls.append(flush ? "prepare" : "prepare-noflush")
        onPrepare?()
        return ("req", running)
    }

    func commit(requestID: String, configPath: String) {
        calls.append("commit")
        for old in running { exited.insert(old.pid) }
        running = comesBack ? running.map { Self.instance(pid: $0.pid + 1000, bundleID: $0.bundleID) } : []
    }

    func abort(requestID: String, configPath: String) { calls.append("abort") }

    func isRunning(pid: Int32) -> Bool { !exited.contains(pid) && running.contains { $0.pid == pid } }

    /// Processes the system sees; by default exactly those that answer.
    var silent: [AgentIPC.Process] = []
    private(set) var processQueries = 0
    func runningProcesses() -> [AgentIPC.Process] {
        processQueries += 1
        return running.map { AgentIPC.Process(pid: $0.pid, bundleID: $0.bundleID) } + silent
    }
}

final class AgentCLITests: XCTestCase {

    private var dir: URL!
    private var out = ""
    private var err = ""

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("agent-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        out = ""
        err = ""
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var configURL: URL { dir.appendingPathComponent("config.json") }

    private func env(_ app: FakeApp) -> AgentCLIEnvironment {
        var env = AgentCLIEnvironment()
        env.location = ConfigLocation(configURL: configURL, backupDirectory: dir.appendingPathComponent("backups"))
        env.ipc = app
        env.home = dir.appendingPathComponent("home")
        env.cliPath = "/Applications/Test.app/Contents/MacOS/Test"
        env.restartWait = 0.5
        env.pause = { _ in }
        return env
    }

    @discardableResult
    private func run(_ args: [String], _ app: FakeApp, sandboxed: Bool = false) -> Int32 {
        var env = env(app)
        env.sandboxed = sandboxed
        return AgentCLI.execute(args, env: env, out: { self.out += $0 }, err: { self.err += $0 })
    }

    private func write(_ text: String, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private var current: String { (try? String(contentsOf: configURL, encoding: .utf8)) ?? "" }

    private let old = #"{ "popup": { "style": "capsule" } }"#
    private let new = #"{ "popup": { "style": "donut" } }"#

    func testApplyBacksUpWritesAndRestartsTheRunningApp() throws {
        _ = try write(old, "config.json")
        let staged = try write(new, "staged.json")
        let app = FakeApp(running: [FakeApp.instance(pid: 10), FakeApp.instance(pid: 20, bundleID: "test.app.debug")])

        XCTAssertEqual(run(["apply", staged.path], app), 0, err)
        XCTAssertEqual(current, new)
        XCTAssertEqual(Array(app.calls.prefix(2)), ["prepare", "commit"])
        let backups = ConfigFiles.backups(env(app).location)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOfFile: backups[0].path, encoding: .utf8), old)
        XCTAssertTrue(out.contains("now pid 1010"), out)
        XCTAssertTrue(out.contains("now pid 1020"), out)
        XCTAssertTrue(out.contains("cli rollback \(backups[0].file)"), out)
    }

    /// In an agent's sandbox, talking to the app kills the process and the
    /// config cannot be written: the changing commands refuse before trying,
    /// with a message that says to run them outside the sandbox.
    func testInASandboxTheChangingCommandsRefuseWithoutTouchingTheApp() throws {
        _ = try write(old, "config.json")
        let staged = try write(new, "staged.json")
        let app = FakeApp(running: [FakeApp.instance(pid: 10)])
        for args in [["apply", staged.path], ["restart"], ["rollback"], ["install-skill"]] {
            err = ""
            XCTAssertEqual(run(args, app, sandboxed: true), 1, args.joined(separator: " "))
            XCTAssertTrue(err.contains("outside the sandbox"), err)
            XCTAssertTrue(err.contains("Nothing was changed"), err)
        }
        XCTAssertEqual(current, old)
        XCTAssertTrue(app.calls.isEmpty, "\(app.calls)")
        XCTAssertEqual(app.processQueries, 0)
        XCTAssertTrue(ConfigFiles.backups(env(app).location).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("home/.agents").path))
    }

    /// The read-only commands still work there, and `info` says the running
    /// app is unknown instead of "not running".
    func testInASandboxReadOnlyCommandsWorkAndInfoDoesNotAskTheApp() throws {
        _ = try write(old, "config.json")
        let staged = try write(new, "staged.json")
        let app = FakeApp(running: [FakeApp.instance(pid: 10)])

        XCTAssertEqual(run(["info"], app, sandboxed: true), 0, err)
        XCTAssertTrue(out.contains("Running:       unknown"), out)
        out = ""
        XCTAssertEqual(run(["info", "--json"], app, sandboxed: true), 0, err)
        XCTAssertTrue(out.contains("\"sandboxed\" : true"), out)
        XCTAssertEqual(run(["validate", staged.path], app, sandboxed: true), 0, err)
        XCTAssertEqual(run(["backups"], app, sandboxed: true), 0, err)
        XCTAssertTrue(app.calls.isEmpty, "\(app.calls)")
        XCTAssertEqual(app.processQueries, 0)
    }

    func testApplyRefusesAnInvalidFileAndTouchesNothing() throws {
        _ = try write(old, "config.json")
        let staged = try write(#"{ "popup": { "style": "bubble" } }"#, "staged.json")
        let app = FakeApp(running: [FakeApp.instance(pid: 10)])

        XCTAssertEqual(run(["apply", staged.path], app), 1)
        XCTAssertEqual(current, old)
        XCTAssertFalse(app.calls.contains("prepare"), "a refused file must not stop the app from writing")
        XCTAssertTrue(ConfigFiles.backups(env(app).location).isEmpty)
        XCTAssertTrue(out.contains("popup.style"), out)
    }

    func testStrictRefusesWarnings() throws {
        _ = try write(old, "config.json")
        let staged = try write(#"{ "popup": { "styel": "donut" } }"#, "staged.json")
        XCTAssertEqual(run(["apply", "--strict", staged.path], FakeApp()), 1)
        XCTAssertEqual(current, old)
        XCTAssertEqual(run(["apply", staged.path], FakeApp()), 0, err)
    }

    /// The app saved a change from its settings window while preparing: the
    /// staged edit was made against an older file and would undo that change.
    func testApplyRefusesWhenTheAppSavedSomethingMeanwhile() throws {
        _ = try write(old, "config.json")
        let staged = try write(new, "staged.json")
        let app = FakeApp(running: [FakeApp.instance(pid: 10)])
        let userChange = #"{ "popup": { "style": "liquidGlass" } }"#
        app.onPrepare = { try? Data(userChange.utf8).write(to: self.configURL) }

        XCTAssertEqual(run(["apply", staged.path], app), 1)
        XCTAssertEqual(current, userChange, "the user's change must survive")
        XCTAssertTrue(app.calls.contains("abort"))
        XCTAssertFalse(app.calls.contains("commit"))
        XCTAssertTrue(err.contains("Read the config again"), err)
    }

    /// An older version is running and cannot be asked to stop writing: the
    /// file must not be replaced under it.
    func testApplyRefusesWhileAnOlderVersionRuns() throws {
        _ = try write(old, "config.json")
        let staged = try write(new, "staged.json")
        let app = FakeApp(running: [FakeApp.instance(pid: 10)])
        app.silent = [AgentIPC.Process(pid: 99, bundleID: "test.app.old")]
        XCTAssertEqual(run(["apply", staged.path], app), 1)
        XCTAssertEqual(current, old)
        XCTAssertTrue(app.calls.contains("abort"), "the copy that did answer writes again")
        XCTAssertFalse(app.calls.contains("commit"))
        XCTAssertTrue(err.contains("pid 99"), err)
        XCTAssertEqual(run(["restart"], app), 1)
    }

    /// The app's flush rewrites a file in its own layout (sorted keys, its own
    /// indentation) even when no setting changed. That is not a change the
    /// user made and must not block the apply. Found by running it for real:
    /// a rollback right after an apply was refused.
    func testTheAppRewritingTheSameSettingsInItsOwnLayoutDoesNotBlock() throws {
        _ = try write(#"{"popup":{"style":"capsule","border":true}}"#, "config.json")
        let staged = try write(new, "staged.json")
        let app = FakeApp(running: [FakeApp.instance(pid: 10)])
        app.onPrepare = {
            try? Data("{\n  \"popup\" : {\n    \"border\" : true,\n    \"style\" : \"capsule\"\n  }\n}\n".utf8).write(to: self.configURL)
        }
        XCTAssertEqual(run(["apply", staged.path], app), 0, err)
        XCTAssertEqual(current, new)
        XCTAssertTrue(app.calls.contains("commit"))
    }

    func testApplyReportsOnlyWhatTheChangeBroughtIn() throws {
        _ = try write(#"{ "popup": { "styel": "x" } }"#, "config.json")
        let staged = try write(#"{ "popup": { "styel": "x", "hotkey": "opt+x" } }"#, "staged.json")
        XCTAssertEqual(run(["apply", staged.path, "--json"], FakeApp()), 0, err)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let warnings = try XCTUnwrap(object["warnings"] as? [[String: Any]])
        XCTAssertEqual(warnings.map { $0["path"] as? String }, ["popup.hotkey"])
        XCTAssertEqual(object["alreadyThere"] as? Int, 1)
    }

    func testApplyWithTheAppNotRunning() throws {
        _ = try write(old, "config.json")
        let staged = try write(new, "staged.json")
        let app = FakeApp()
        XCTAssertEqual(run(["apply", staged.path], app), 0, err)
        XCTAssertEqual(current, new)
        XCTAssertFalse(app.calls.contains("commit"))
        XCTAssertTrue(out.contains("not running"), out)
    }

    func testApplyWhenTheAppDoesNotComeBack() throws {
        _ = try write(old, "config.json")
        let staged = try write(new, "staged.json")
        let app = FakeApp(running: [FakeApp.instance(pid: 10)])
        app.comesBack = false
        XCTAssertEqual(run(["apply", staged.path], app), 1)
        XCTAssertEqual(current, new, "the file is written either way")
        XCTAssertTrue(out.contains("did not come back"), out)
    }

    func testApplyingTheSameContentDoesNothing() throws {
        _ = try write(old, "config.json")
        let staged = try write(old, "staged.json")
        let app = FakeApp(running: [FakeApp.instance(pid: 10)])
        XCTAssertEqual(run(["apply", staged.path], app), 0)
        XCTAssertFalse(app.calls.contains("prepare"))
        XCTAssertTrue(ConfigFiles.backups(env(app).location).isEmpty)
    }

    func testApplyRefusesTheConfigFileItself() throws {
        _ = try write(old, "config.json")
        XCTAssertEqual(run(["apply", configURL.path], FakeApp()), 1)
        XCTAssertTrue(err.contains("cli restart"), err)
    }

    func testRollbackUndoesTheLastApplyAndCanItselfBeUndone() throws {
        _ = try write(old, "config.json")
        let staged = try write(new, "staged.json")
        XCTAssertEqual(run(["apply", staged.path], FakeApp()), 0)
        XCTAssertEqual(current, new)

        XCTAssertEqual(run(["rollback"], FakeApp()), 0, err)
        XCTAssertEqual(current, old)
        XCTAssertEqual(ConfigFiles.backups(env(FakeApp()).location).count, 2, "the rolled-back version is kept too")

        XCTAssertEqual(run(["rollback"], FakeApp()), 0, err)
        XCTAssertEqual(current, new)
    }

    func testRollbackToANamedBackup() throws {
        _ = try write(old, "config.json")
        XCTAssertEqual(run(["apply", try write(new, "a.json").path], FakeApp()), 0)
        XCTAssertEqual(run(["apply", try write(#"{ "popup": { "style": "liquidGlass" } }"#, "b.json").path], FakeApp()), 0)
        let oldest = try XCTUnwrap(ConfigFiles.backups(env(FakeApp()).location).last)
        XCTAssertEqual(run(["rollback", oldest.file], FakeApp()), 0, err)
        XCTAssertEqual(current, old)
        XCTAssertEqual(run(["rollback", "config-nope.json"], FakeApp()), 1)
    }

    func testRestartAfterAnEditInPlaceDoesNotFlush() throws {
        _ = try write(new, "config.json")
        let app = FakeApp(running: [FakeApp.instance(pid: 10)])
        XCTAssertEqual(run(["restart"], app), 0, err)
        XCTAssertEqual(Array(app.calls.prefix(2)), ["prepare-noflush", "commit"])

        _ = try write(#"{ "popup": { "style": 3 } }"#, "config.json")
        let again = FakeApp(running: [FakeApp.instance(pid: 30)])
        XCTAssertEqual(run(["restart"], again), 1)
        XCTAssertFalse(again.calls.contains("commit"))
    }

    func testValidateExitStatusAndJSON() throws {
        _ = try write(old, "config.json")
        XCTAssertEqual(run(["validate"], FakeApp()), 0)
        let bad = try write(#"{ "ocr": { "hotKey": "" } }"#, "bad.json")
        out = ""
        XCTAssertEqual(run(["validate", bad.path, "--json"], FakeApp()), 1)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual((object["errors"] as? [[String: Any]])?.first?["path"] as? String, "ocr.hotKey")
    }

    func testUsageErrors() {
        XCTAssertEqual(run(["frobnicate"], FakeApp()), 2)
        XCTAssertEqual(run(["apply"], FakeApp()), 2)
        XCTAssertEqual(run(["info", "extra"], FakeApp()), 2)
        XCTAssertEqual(run(["install-skill", "--agent", "notepad"], FakeApp()), 2)
        XCTAssertEqual(run([], FakeApp()), 0)
        XCTAssertTrue(out.contains("apply <file>"))
    }

    func testInfoJSON() throws {
        _ = try write(#"{ "models": { "provider": "deepseek", "model": "m" }, "actions": [ { "id": "g", "title": "G", "kind": "group", "children": [ { "id": "c", "title": "C", "kind": "copy" } ] } ] }"#, "config.json")
        let app = FakeApp(running: [FakeApp.instance(pid: 10)])
        XCTAssertEqual(run(["info", "--json"], app), 0)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let config = try XCTUnwrap(object["config"] as? [String: Any])
        XCTAssertEqual(config["actions"] as? Int, 1)
        XCTAssertEqual(config["actionsIncludingGroups"] as? Int, 2)
        XCTAssertEqual(config["check"] as? String, "ok")
        XCTAssertEqual((object["running"] as? [Any])?.count, 1)
    }

    func testPromptCarriesThePaths() {
        XCTAssertEqual(run(["prompt", "--lang", "zh", "--request", "加一个动作"], FakeApp()), 0)
        XCTAssertTrue(out.contains("/Applications/Test.app/Contents/MacOS/Test"))
        XCTAssertTrue(out.contains(configURL.path))
        XCTAssertTrue(out.hasSuffix("我的需求：加一个动作\n"), out)
        out = ""
        XCTAssertEqual(run(["prompt", "--lang", "en"], FakeApp()), 0)
        XCTAssertTrue(out.contains("SKILL.md"))
        XCTAssertTrue(out.contains("My request: \n"))
    }
}

// MARK: - Installing the skill

final class SkillInstallerTests: XCTestCase {

    private var home: URL!
    private var source: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        source = root.appendingPathComponent("bundle/skill")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("references"), withIntermediateDirectories: true)
        try Data("---\nname: demo\ndescription: d\n---\nv1\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        try Data("ref".utf8).write(to: source.appendingPathComponent("references/actions.md"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func testInstallsAndLinksTheAgentsThatAreThere() throws {
        let result = try SkillInstaller.install(source: source, home: home)
        let installed = home.appendingPathComponent(".agents/skills/demo")
        XCTAssertEqual(result.installedDirectory, installed.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("references/actions.md").path))
        XCTAssertEqual(result.linkedAgents, [.claude, .codex])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".claude/skills/demo").path),
                       installed.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".cursor").path),
                       "an agent that is not installed gets nothing")
        XCTAssertEqual(SkillInstaller.linkedAgents(home: home, name: "demo"), [.claude, .codex])
        XCTAssertTrue(SkillInstaller.installedCopyIsCurrent(source: source, home: home))
    }

    func testAnUpdateIsSeenAndReplacesTheCopy() throws {
        _ = try SkillInstaller.install(source: source, home: home)
        try Data("---\nname: demo\ndescription: d\n---\nv2\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        XCTAssertFalse(SkillInstaller.installedCopyIsCurrent(source: source, home: home))
        _ = try SkillInstaller.install(source: source, home: home)
        XCTAssertTrue(SkillInstaller.installedCopyIsCurrent(source: source, home: home))
    }

    func testAFolderOfTheUsersOwnIsLeftAlone() throws {
        let own = home.appendingPathComponent(".claude/skills/demo")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: own.appendingPathComponent("notes.txt"))
        let result = try SkillInstaller.install(source: source, home: home)
        XCTAssertTrue(result.links.contains { $0.agent == .claude && $0.status == .keptExisting })
        XCTAssertTrue(FileManager.default.fileExists(atPath: own.appendingPathComponent("notes.txt").path))

        let other = home.appendingPathComponent(".agents/skills/demo")
        try? FileManager.default.removeItem(at: other)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("---\nname: someone-else\n---\n".utf8).write(to: other.appendingPathComponent("SKILL.md"))
        XCTAssertThrowsError(try SkillInstaller.install(source: source, home: home))
        XCTAssertEqual(BundledSkill.name(of: other), "someone-else", "and it is still there")
    }

    func testAnAgentAskedForByNameGetsItsFolderMade() throws {
        let result = try SkillInstaller.install(agents: [.cursor], source: source, home: home)
        XCTAssertEqual(result.linkedAgents, [.cursor])
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".cursor/skills/demo").path))
    }

    func testTheRepositorySkillIsNamedAndComplete() throws {
        let dir = BundledSkill.directory(bundle: Bundle(for: Self.self))
        XCTAssertEqual(BundledSkill.name(of: dir), "qduo")
        let text = try String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("---\nname: qduo\ndescription: "))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("references/actions.md").path))
        // Every command the skill tells agents about exists.
        for command in ["info", "schema", "validate", "apply", "restart", "backups", "rollback", "providers", "languages", "install-skill", "prompt"] {
            XCTAssertTrue(text.contains("`cli \(command)"), command)
            XCTAssertTrue(AgentCLI.usage.contains("  \(command)"), command)
        }
    }
}
