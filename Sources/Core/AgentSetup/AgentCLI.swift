import Foundation

/// A model provider as `cli providers` reports it.
struct ProviderInfo: Codable, Equatable {
    let id: String
    let name: String
    let format: String
    let defaultURL: String
    let defaultModel: String
    let needsKey: Bool
    /// nil when the Keychain could not be asked.
    let hasKey: Bool?
    /// The values `models.thinking` / `modelOverride.effort` accept.
    let thinking: [String]
}

/// Everything the command line touches outside itself, so the tests can give
/// it a temporary config file, a fake running app and a fake home folder.
struct AgentCLIEnvironment {
    var location: ConfigLocation = .live
    var ipc: AgentIPCClient = LiveAgentIPCClient()
    var validation: ValidationEnvironment = .fileOnly
    var providers: () -> [ProviderInfo] = { [] }
    /// This executable, as an agent should call it.
    var cliPath: String = Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? ""
    var skillDirectory: URL = BundledSkill.directory()
    var home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    /// How long `apply` waits for a running app to come back after a restart.
    var restartWait: TimeInterval = 15
    var pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var now: () -> Date = Date.init
    /// Running inside an agent's sandbox (`AgentSandbox`): the running app
    /// cannot be seen or told anything, and the config cannot be written.
    var sandboxed: Bool = false
}

/// `<App> cli <command>`: the command line an AI agent (or a person) uses to
/// inspect, check and change the app's config without the settings window.
///
/// It runs inside the app's own executable, before `NSApplication` exists
/// (`main.swift`), so it has the app's Keychain access and always matches the
/// app's version. Nothing here opens a window or starts a monitor.
///
/// Exit status: 0 done, 1 refused or failed (the message says why), 2 the
/// command itself was wrong.
enum AgentCLI {

    static func shouldHandle(_ arguments: [String]) -> Bool {
        arguments.count > 1 && arguments[1] == "cli"
    }

    /// Runs the command and returns the exit status. Output goes to stdout,
    /// problems with the command to stderr.
    static func run(_ arguments: [String], env: AgentCLIEnvironment) -> Int32 {
        let code = execute(Array(arguments.dropFirst(2)), env: env,
                           out: { FileHandle.standardOutput.write(Data($0.utf8)) },
                           err: { FileHandle.standardError.write(Data($0.utf8)) })
        FileLog.waitForPendingWrites()
        return code
    }

    private static let log = FileLog("CLI")

    // MARK: - Dispatch

    static func execute(_ arguments: [String], env: AgentCLIEnvironment,
                        out: @escaping (String) -> Void, err: @escaping (String) -> Void) -> Int32 {
        var env = env
        var args = Arguments(arguments)
        let json = args.flag("--json")
        if let custom = args.value("--config") {
            let url = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath).standardizedFileURL
            env.location = ConfigLocation(configURL: url, backupDirectory: env.location.backupDirectory)
        }
        let io = Output(json: json, out: out, err: err)
        guard let command = args.next() else {
            out(usage)
            return 0
        }
        if args.flag("--help") || args.flag("-h") || ["help", "-h"].contains(command) {
            out(usage)
            return 0
        }

        if env.sandboxed, sandboxRefused.contains(command) {
            return io.failure(sandboxRefusal(command, env))
        }

        switch command {
        case "info":          return info(&args, env, io)
        case "schema":        return schema(&args, env, io)
        case "validate":      return validate(&args, env, io)
        case "apply":         return apply(&args, env, io)
        case "restart":       return restart(&args, env, io)
        case "backups":       return backups(&args, env, io)
        case "rollback":      return rollback(&args, env, io)
        case "providers":     return providers(&args, env, io)
        case "languages":     return languages(&args, env, io)
        case "install-skill": return installSkill(&args, env, io)
        case "prompt":        return prompt(&args, env, io)
        default:
            return io.usageError("unknown command \"\(command)\". Run `cli help` for the list.")
        }
    }

    /// The commands that write files or talk to the running app.
    static let sandboxRefused: Set<String> = ["apply", "restart", "rollback", "install-skill"]

    /// Agents act on this text, so it says what to do: run the same command
    /// again, outside the sandbox. Codex calls that "escalated permissions".
    static func sandboxRefusal(_ command: String, _ env: AgentCLIEnvironment) -> String {
        let what = command == "install-skill"
            ? "it writes into the agents' skills folders under \(env.home.path)"
            : "it writes \(env.location.configURL.path) and restarts the running \(Brand.name)"
        return "`cli \(command)` has to run outside the sandbox: \(what), which the sandbox this command runs in does not allow. "
            + "Nothing was changed. Run the same command again with the sandbox turned off for it "
            + "(in Codex: request escalated permissions; in other agents: ask the user to approve running it outside the sandbox)."
    }

    static var usage: String {
        """
        \(Brand.name) command line — inspect, check and change the config without the settings window.

        Usage: "<\(Brand.name) executable>" cli <command> [options] [--json] [--config <file>]

          info                       Paths, versions, the running app, a check of the current config
          schema                     Print the JSON Schema of the config file
          validate [<file>]          Check a config file (default: the current one) [--strict]
          apply <file>               Check <file>, back up the current config, put <file> in place
                                     and restart the running app so it takes effect [--strict]
          restart                    Restart the running app to read a config edited in place [--force]
          backups                    List the versions apply and rollback kept, newest first
          rollback [<backup>]        Put a backup back (default: the newest), then restart [--force]
          providers                  Model providers: ids, default models, thinking values, key saved?
          languages                  Target languages of the Bilibili translation engine
          install-skill [--agent <name>]...
                                     Install the bundled Agent Skill for local AI agents
                                     (\(SkillAgent.allCases.map(\.rawValue).joined(separator: ", ")))
          prompt [--lang zh|en] [--request <text>]
                                     Print the prompt that sets an AI agent up to configure the app

          --json      Machine-readable output
          --config    Work on another file instead of \(ConfigLocation.live.configURL.path)

        Exit status: 0 done, 1 refused or failed, 2 the command was wrong.

        Inside an AI agent's sandbox, info, validate and the other read-only commands work;
        apply, restart, rollback and install-skill refuse and ask to be run outside it.

        """
    }

    // MARK: - info

    struct InfoOutput: Codable {
        struct App: Codable { let name, version, build, bundleID, cliPath: String }
        struct Config: Codable {
            let path, resolvedPath, schemaPath, backupDirectory: String
            let exists: Bool
            let actions: Int
            let actionsIncludingGroups: Int
            let backups: Int
            let check: String
            let errors: Int
            let warnings: Int
        }
        struct Model: Codable { let provider, model: String; let hasKey: Bool? }
        struct Skill: Codable {
            let bundledDirectory, skillFile, installedDirectory: String
            let installed, current: Bool
            let linkedAgents: [String]
        }
        let app: App
        /// The command ran in a sandbox, so `running` is unknown, not empty.
        let sandboxed: Bool
        let config: Config
        let model: Model?
        let skill: Skill
        let running: [AgentIPC.Instance]
    }

    private static func info(_ args: inout Arguments, _ env: AgentCLIEnvironment, _ io: Output) -> Int32 {
        if let extra = args.leftover() { return io.usageError("info takes no \(extra)") }
        let location = env.location
        let data = ConfigFiles.read(location)
        let document = data.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        let actions = document?[path: "actions"]?.arrayValue ?? []
        let total = actions.reduce(0) { $0 + 1 + ($1[path: "children"]?.arrayValue?.count ?? 0) }
        let report = data.map { ConfigValidator.validate(data: $0, env: env.validation) }
        let check: String = {
            guard let report else { return "missing" }
            if !report.errors.isEmpty { return "errors" }
            return report.warnings.isEmpty ? "ok" : "warnings"
        }()
        let provider = document?[path: "models.provider"]?.stringValue
        let skillName = BundledSkill.name(of: env.skillDirectory)
        let installed = SkillInstaller.installedDirectory(home: env.home, name: skillName)
        let output = InfoOutput(
            app: .init(name: Brand.name, version: Brand.version, build: Brand.build, bundleID: Brand.bundleID, cliPath: env.cliPath),
            sandboxed: env.sandboxed,
            config: .init(path: location.configURL.path, resolvedPath: location.resolvedURL.path,
                          schemaPath: location.schemaURL.path, backupDirectory: location.backupDirectory.path,
                          exists: data != nil, actions: actions.count, actionsIncludingGroups: total,
                          backups: ConfigFiles.backups(location).count, check: check,
                          errors: report?.errors.count ?? 0, warnings: report?.warnings.count ?? 0),
            model: provider.map { .init(provider: $0, model: document?[path: "models.model"]?.stringValue ?? "",
                                        hasKey: env.validation.hasAPIKey($0)) },
            skill: .init(bundledDirectory: env.skillDirectory.path,
                         skillFile: env.skillDirectory.appendingPathComponent("SKILL.md").path,
                         installedDirectory: installed.path,
                         installed: FileManager.default.fileExists(atPath: installed.appendingPathComponent("SKILL.md").path),
                         current: SkillInstaller.installedCopyIsCurrent(source: env.skillDirectory, home: env.home),
                         linkedAgents: SkillInstaller.linkedAgents(home: env.home, name: skillName).map(\.rawValue)),
            running: env.sandboxed ? [] : env.ipc.ping(configPath: AgentIPC.canonicalPath(location.resolvedURL)))

        if io.json { return io.emit(output) }
        var lines = ["\(output.app.name) \(output.app.version) (build \(output.app.build)) — \(output.app.bundleID)",
                     "Command line:  \"\(env.cliPath)\" cli",
                     "Config file:   \(location.configURL.path)" + (location.isSymlink ? "  → \(location.resolvedURL.path)" : "")
                        + (data == nil ? "  (does not exist yet)" : ""),
                     "Schema:        \(location.schemaURL.path)",
                     "Actions:       \(actions.count) in the ring, \(total) counting those inside groups"]
        if let model = output.model {
            let key = model.hasKey.map { $0 ? "API key saved" : "NO API key saved" } ?? "no key needed or unknown"
            lines.append("Default model: \(model.provider) / \(model.model.isEmpty ? "(provider default)" : model.model)  [\(key)]")
        }
        let checkText: String = {
            switch check {
            case "ok":       return "OK"
            case "missing":  return "no config file yet (the app writes one when it starts)"
            default:         return "\(output.config.errors) error(s), \(output.config.warnings) warning(s) — run `cli validate` for details"
            }
        }()
        lines.append("Config check:  \(checkText)")
        lines.append("Backups:       \(output.config.backups) in \(location.backupDirectory.path)")
        lines.append("Skill:         \(output.skill.skillFile)")
        let installedText = output.skill.installed ? (output.skill.current ? "installed, current" : "installed, OUTDATED — run `cli install-skill`") : "not installed"
        let agents = SkillInstaller.linkedAgents(home: env.home, name: skillName).map(\.displayName)
        lines.append("               \(installedText)" + (agents.isEmpty ? "" : "; linked into \(agents.joined(separator: ", "))"))
        let silent = env.sandboxed ? [] : env.ipc.runningProcesses().filter { p in !output.running.contains { $0.pid == p.pid } }
        if env.sandboxed {
            lines.append("Running:       unknown — this command runs inside a sandbox, which hides the running app and the Keychain;")
            lines.append("               apply, rollback, restart and install-skill have to run outside it")
        } else if !silent.isEmpty {
            lines.append("Running:       " + silent.map { "\($0.bundleID) (pid \($0.pid))" }.joined(separator: ", ")
                         + " — NOT answering (an older version?); apply refuses until it is quit")
        } else if output.running.isEmpty {
            lines.append("Running:       no — a new config is read the next time the app starts")
        } else {
            lines.append("Running:       " + output.running.map { "\($0.name) \($0.version) (pid \($0.pid))" }.joined(separator: ", "))
        }
        io.out(lines.joined(separator: "\n") + "\n")
        return 0
    }

    // MARK: - schema

    private static func schema(_ args: inout Arguments, _ env: AgentCLIEnvironment, _ io: Output) -> Int32 {
        if let extra = args.leftover() { return io.usageError("schema takes no \(extra)") }
        io.out(ConfigSchema.json + "\n")
        return 0
    }

    // MARK: - validate

    struct ValidateOutput: Codable {
        let file: String
        let ok: Bool
        let strict: Bool
        let errors: [ConfigIssue]
        let warnings: [ConfigIssue]
        let notes: [ConfigIssue]
    }

    private static func validate(_ args: inout Arguments, _ env: AgentCLIEnvironment, _ io: Output) -> Int32 {
        let strict = args.flag("--strict")
        let file = args.next()
        if let extra = args.leftover() { return io.usageError("validate does not take \(extra)") }
        let url = file.map(fileURL) ?? env.location.resolvedURL
        guard let data = try? Data(contentsOf: url) else { return io.failure("cannot read \(url.path)") }
        let report = ConfigValidator.validate(data: data, env: env.validation)
        let ok = report.passes(strict: strict)
        if io.json {
            _ = io.emit(ValidateOutput(file: url.path, ok: ok, strict: strict, errors: report.errors,
                                       warnings: report.warnings, notes: report.notes))
        } else {
            io.out(describe(report, file: url.path, strict: strict))
        }
        return ok ? 0 : 1
    }

    static func describe(_ report: ConfigValidator.Report, file: String, strict: Bool) -> String {
        var lines: [String] = []
        for issue in report.errors { lines.append("error    \(issue.path): \(issue.message)") }
        for issue in report.warnings { lines.append("warning  \(issue.path): \(issue.message)") }
        for issue in report.notes { lines.append("note     \(issue.path): \(issue.message)") }
        let passes = report.passes(strict: strict)
        let counts = "\(report.errors.count) error(s), \(report.warnings.count) warning(s)"
        lines.append(passes ? "\(file): OK (\(counts))" : "\(file): NOT OK (\(counts)\(strict && report.errors.isEmpty ? ", --strict refuses warnings" : ""))")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - apply / rollback / restart

    struct ChangeOutput: Codable {
        let ok: Bool
        let action: String
        let config: String
        let source: String?
        let backup: String?
        let changed: Bool
        let restarted: [AgentIPC.Instance]
        let notRestarted: [AgentIPC.Instance]
        let running: Bool
        let undo: String?
        /// Only what this change brought in; issues the replaced config already
        /// had are counted in `alreadyThere` and not repeated.
        let warnings: [ConfigIssue]
        let notes: [ConfigIssue]
        var alreadyThere: Int = 0
        let message: String
    }

    private static func apply(_ args: inout Arguments, _ env: AgentCLIEnvironment, _ io: Output) -> Int32 {
        let strict = args.flag("--strict")
        guard let file = args.next() else { return io.usageError("apply needs the file to put in place: cli apply <file>") }
        if let extra = args.leftover() { return io.usageError("apply does not take \(extra)") }
        let url = fileURL(file)
        if AgentIPC.canonicalPath(url) == AgentIPC.canonicalPath(env.location.resolvedURL) {
            return io.failure("\(url.path) IS the config file. Write the edit to a temporary file and apply that, or, having edited the config in place, run `cli restart`.")
        }
        guard let data = try? Data(contentsOf: url) else { return io.failure("cannot read \(url.path)") }
        return replace(with: data, source: url.path, action: "apply", strict: strict, force: false, env, io)
    }

    private static func rollback(_ args: inout Arguments, _ env: AgentCLIEnvironment, _ io: Output) -> Int32 {
        let force = args.flag("--force")
        _ = args.flag("--latest")
        let name = args.next()
        if let extra = args.leftover() { return io.usageError("rollback does not take \(extra)") }
        let url: URL
        if let name {
            guard let found = ConfigFiles.backup(named: name, in: env.location) else {
                return io.failure("no backup named \(name); `cli backups` lists them")
            }
            url = found
        } else {
            guard let newest = ConfigFiles.backups(env.location).first else {
                return io.failure("there are no backups yet in \(env.location.backupDirectory.path)")
            }
            url = URL(fileURLWithPath: newest.path)
        }
        guard let data = try? Data(contentsOf: url) else { return io.failure("cannot read \(url.path)") }
        return replace(with: data, source: url.path, action: "rollback", strict: false, force: force, env, io)
    }

    /// The transaction `apply` and `rollback` share.
    ///
    ///     check the new file → errors (and, with strict, warnings) → refuse, change nothing
    ///     the new file is the current one → nothing to do
    ///     ask each running app to write any pending change, then stop writing
    ///     the file changed in that step (the user just changed a setting)
    ///         → let the app write again, refuse: read the config again and redo the edit
    ///     back up the current file → write the new one (on failure, let the app write again)
    ///     ask the app to restart, and wait for it to come back
    private static func replace(with data: Data, source: String, action: String, strict: Bool, force: Bool,
                                _ env: AgentCLIEnvironment, _ io: Output) -> Int32 {
        let location = env.location
        let report = ConfigValidator.validate(data: data, env: env.validation)
        if !force, !report.passes(strict: strict) {
            if io.json {
                _ = io.emit(ValidateOutput(file: source, ok: false, strict: strict, errors: report.errors,
                                           warnings: report.warnings, notes: report.notes))
            } else {
                io.out(describe(report, file: source, strict: strict))
                io.out("Nothing was changed.\(action == "rollback" ? " Add --force to restore this backup anyway." : "")\n")
            }
            return 1
        }

        let before = ConfigFiles.read(location)
        let configPath = AgentIPC.canonicalPath(location.resolvedURL)
        let baseline = before.map { ConfigValidator.validate(data: $0, env: env.validation).issues } ?? []
        func isNew(_ issue: ConfigIssue) -> Bool { !baseline.contains(issue) }
        let newWarnings = report.warnings.filter(isNew)
        let newNotes = report.notes.filter(isNew)
        let alreadyThere = report.warnings.count + report.notes.count - newWarnings.count - newNotes.count
        if sameSettings(before, data) {
            return finish(ChangeOutput(ok: true, action: action, config: location.configURL.path, source: source,
                                       backup: nil, changed: false, restarted: [], notRestarted: [],
                                       running: !env.ipc.ping(configPath: configPath).isEmpty, undo: nil,
                                       warnings: report.warnings, notes: report.notes,
                                       message: "The config is already exactly this; nothing to do."), io)
        }

        let (requestID, instances) = env.ipc.prepare(configPath: configPath, flush: true)
        if let refusal = silentCopies(answered: instances, env) {
            if !instances.isEmpty { env.ipc.abort(requestID: requestID, configPath: configPath) }
            return io.failure(refusal)
        }
        // Compared as settings, not bytes: the app's flush rewrites a file it
        // did not write itself in its own layout (sorted keys), which is not a
        // change anyone made.
        if !instances.isEmpty, !sameSettings(ConfigFiles.read(location), before) {
            env.ipc.abort(requestID: requestID, configPath: configPath)
            return io.failure("the app had just saved a change made in its settings window, so the config is not what your edit started from. Read the config again, redo the edit on the new version and apply again.")
        }

        let backup: URL?
        do {
            backup = try ConfigFiles.backUpCurrent(location, now: env.now())
            try ConfigFiles.write(data, to: location)
        } catch {
            if !instances.isEmpty { env.ipc.abort(requestID: requestID, configPath: configPath) }
            return io.failure("could not write \(location.resolvedURL.path): \(error.localizedDescription)")
        }
        log.info("\(action): wrote \(location.resolvedURL.path) from \(source)" + (backup.map { ", previous version kept as \($0.lastPathComponent)" } ?? ""))

        var restarted: [AgentIPC.Instance] = []
        var notRestarted: [AgentIPC.Instance] = []
        if !instances.isEmpty {
            env.ipc.commit(requestID: requestID, configPath: configPath)
            (restarted, notRestarted) = waitForRestart(of: instances, configPath: configPath, env)
        }

        let undo = backup.map { "\"\(env.cliPath)\" cli rollback \($0.lastPathComponent)" }
        var message = "\(action == "rollback" ? "Restored" : "Applied") \(source) to \(location.configURL.path)."
        if let backup { message += "\nThe previous version is kept as \(backup.path)." }
        if instances.isEmpty {
            message += "\n\(Brand.name) is not running; it reads the new config the next time it starts."
        } else {
            if !restarted.isEmpty {
                message += "\nRestarted " + restarted.map { "\($0.name) (now pid \($0.pid))" }.joined(separator: ", ") + " — the new config is in effect."
            }
            if !notRestarted.isEmpty {
                message += "\n" + notRestarted.map(\.name).joined(separator: ", ") + " did not come back within \(Int(env.restartWait)) s. Ask the user to open it again; it reads the new config when it starts."
            }
        }
        if let undo { message += "\nTo undo: \(undo)" }
        let output = ChangeOutput(ok: notRestarted.isEmpty, action: action, config: location.configURL.path, source: source,
                                  backup: backup?.path, changed: true, restarted: restarted, notRestarted: notRestarted,
                                  running: !instances.isEmpty, undo: undo, warnings: newWarnings, notes: newNotes,
                                  alreadyThere: alreadyThere, message: message)
        return finish(output, io)
    }

    private static func restart(_ args: inout Arguments, _ env: AgentCLIEnvironment, _ io: Output) -> Int32 {
        let force = args.flag("--force")
        if let extra = args.leftover() { return io.usageError("restart does not take \(extra)") }
        let location = env.location
        guard let data = ConfigFiles.read(location) else { return io.failure("there is no config file at \(location.resolvedURL.path)") }
        let report = ConfigValidator.validate(data: data, env: env.validation)
        if !force, !report.errors.isEmpty {
            io.out(describe(report, file: location.resolvedURL.path, strict: false))
            io.out("Not restarted: fix the errors first (or add --force).\n")
            return 1
        }
        let configPath = AgentIPC.canonicalPath(location.resolvedURL)
        // No flush: the file on disk was edited by hand and is what should win.
        let (requestID, instances) = env.ipc.prepare(configPath: configPath, flush: false)
        if let refusal = silentCopies(answered: instances, env) {
            if !instances.isEmpty { env.ipc.abort(requestID: requestID, configPath: configPath) }
            return io.failure(refusal)
        }
        guard !instances.isEmpty else {
            return finish(ChangeOutput(ok: true, action: "restart", config: location.configURL.path, source: nil, backup: nil,
                                       changed: false, restarted: [], notRestarted: [], running: false, undo: nil,
                                       warnings: report.warnings, notes: report.notes,
                                       message: "\(Brand.name) is not running; it reads the config the next time it starts."), io)
        }
        env.ipc.commit(requestID: requestID, configPath: configPath)
        let (restarted, notRestarted) = waitForRestart(of: instances, configPath: configPath, env)
        var message = restarted.isEmpty ? "" : "Restarted " + restarted.map { "\($0.name) (now pid \($0.pid))" }.joined(separator: ", ") + "."
        if !notRestarted.isEmpty {
            message += (message.isEmpty ? "" : "\n") + notRestarted.map(\.name).joined(separator: ", ") + " did not come back within \(Int(env.restartWait)) s. Ask the user to open it again."
        }
        return finish(ChangeOutput(ok: notRestarted.isEmpty, action: "restart", config: location.configURL.path, source: nil,
                                   backup: nil, changed: false, restarted: restarted, notRestarted: notRestarted, running: true,
                                   undo: nil, warnings: report.warnings, notes: report.notes, message: message), io)
    }

    /// The same JSON document, however it is laid out. Two missing files are
    /// the same; a file that cannot be read as JSON is compared byte for byte.
    static func sameSettings(_ a: Data?, _ b: Data?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        if a == b { return true }
        guard let x = try? JSONDecoder().decode(JSONValue.self, from: a),
              let y = try? JSONDecoder().decode(JSONValue.self, from: b) else { return false }
        return x == y
    }

    /// A copy of the app that is running but did not answer — an older
    /// version, from before the command line. Replacing the file under it is
    /// not safe: it would write its old settings back on its next save.
    private static func silentCopies(answered: [AgentIPC.Instance], _ env: AgentCLIEnvironment) -> String? {
        let silent = env.ipc.runningProcesses().filter { p in !answered.contains { $0.pid == p.pid } }
        guard !silent.isEmpty else { return nil }
        let list = silent.map { "\($0.bundleID) (pid \($0.pid))" }.joined(separator: ", ")
        return "\(list) is running but did not answer — probably a version from before this command line. Nothing was changed. Ask the user to quit it (or update it) and run the command again."
    }

    /// Waits for each old process to exit and a new one of the same build to
    /// answer. Returns the new instances, and the old ones that did not come back.
    private static func waitForRestart(of old: [AgentIPC.Instance], configPath: String,
                                       _ env: AgentCLIEnvironment) -> ([AgentIPC.Instance], [AgentIPC.Instance]) {
        let deadline = env.now().addingTimeInterval(env.restartWait)
        while old.contains(where: { env.ipc.isRunning(pid: $0.pid) }), env.now() < deadline {
            env.pause(0.2)
        }
        var back: [AgentIPC.Instance] = []
        repeat {
            back = env.ipc.ping(configPath: configPath).filter { new in !old.contains { $0.pid == new.pid } }
            if old.allSatisfy({ o in back.contains { $0.bundleID == o.bundleID } }) { break }
            env.pause(0.3)
        } while env.now() < deadline
        let missing = old.filter { o in !back.contains { $0.bundleID == o.bundleID } }
        return (back, missing)
    }

    private static func finish(_ output: ChangeOutput, _ io: Output) -> Int32 {
        if io.json {
            _ = io.emit(output)
        } else {
            var text = output.message + "\n"
            for issue in output.warnings { text += "warning  \(issue.path): \(issue.message)\n" }
            for issue in output.notes { text += "note     \(issue.path): \(issue.message)\n" }
            if output.alreadyThere > 0 {
                text += "(\(output.alreadyThere) warning(s)/note(s) the previous config already had are not repeated; `cli validate` lists every one.)\n"
            }
            io.out(text)
        }
        return output.ok ? 0 : 1
    }

    // MARK: - backups

    private static func backups(_ args: inout Arguments, _ env: AgentCLIEnvironment, _ io: Output) -> Int32 {
        if let extra = args.leftover() { return io.usageError("backups takes no \(extra)") }
        let list = ConfigFiles.backups(env.location)
        if io.json { return io.emit(list) }
        if list.isEmpty {
            io.out("No backups yet. `cli apply` keeps one each time it replaces the config.\n")
        } else {
            io.out("Newest first, in \(env.location.backupDirectory.path):\n"
                   + list.map { "  \($0.file)  \($0.created)  \($0.bytes) bytes" }.joined(separator: "\n")
                   + "\nRestore one with: cli rollback <file>  (no file = the newest)\n")
        }
        return 0
    }

    // MARK: - providers / languages

    private static func providers(_ args: inout Arguments, _ env: AgentCLIEnvironment, _ io: Output) -> Int32 {
        if let extra = args.leftover() { return io.usageError("providers takes no \(extra)") }
        let list = env.providers()
        if io.json { return io.emit(list) }
        var lines: [String] = []
        for p in list {
            let key = !p.needsKey ? "no key needed" : (p.hasKey.map { $0 ? "key saved" : "no key saved" } ?? "key unknown")
            lines.append("\(p.id)  —  \(p.name), \(p.format) format, \(key)")
            lines.append("    default model: \(p.defaultModel.isEmpty ? "(none)" : p.defaultModel)   address: \(p.defaultURL.isEmpty ? "(set custom.apiURL)" : p.defaultURL)")
            lines.append("    thinking: \(p.thinking.map { $0.isEmpty ? "\"\"" : $0 }.joined(separator: ", "))")
        }
        io.out(lines.joined(separator: "\n") + "\n")
        return 0
    }

    private struct LanguageInfo: Codable { let id: String; let name: String }

    private static func languages(_ args: inout Arguments, _ env: AgentCLIEnvironment, _ io: Output) -> Int32 {
        if let extra = args.leftover() { return io.usageError("languages takes no \(extra)") }
        let english = Locale(identifier: "en")
        let list = BilibiliTranslator.languages.map {
            LanguageInfo(id: $0.id, name: english.localizedString(forIdentifier: $0.id) ?? $0.id)
        }
        if io.json { return io.emit(list) }
        io.out("Target languages of the Bilibili engine (\"engine\": \"bilibili\"):\n"
               + list.map { "  \($0.id)\t\($0.name)" }.joined(separator: "\n")
               + "\nWithout an engine, systemTranslate uses macOS's own translator (macOS 15+), which takes the same kind of ids (zh, zh-TW, en, en-GB, ja, fr…).\n")
        return 0
    }

    // MARK: - install-skill

    private static func installSkill(_ args: inout Arguments, _ env: AgentCLIEnvironment, _ io: Output) -> Int32 {
        var agents: [SkillAgent] = []
        while let name = args.value("--agent") {
            guard let agent = SkillAgent(rawValue: name.lowercased()) else {
                return io.usageError("unknown agent \"\(name)\"; one of \(SkillAgent.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            agents.append(agent)
        }
        if let extra = args.leftover() { return io.usageError("install-skill does not take \(extra)") }
        do {
            let result = try SkillInstaller.install(agents: agents.isEmpty ? nil : agents,
                                                    source: env.skillDirectory, home: env.home)
            if io.json { return io.emit(result) }
            var lines = ["Installed the skill at \(result.installedDirectory)"]
            for link in result.links where link.status != .notDetected {
                switch link.status {
                case .linked:       lines.append("  linked for \(link.agent.displayName): \(link.path)")
                case .keptExisting: lines.append("  left alone for \(link.agent.displayName): \(link.path) is a folder that is not a link to it")
                case .notDetected:  break
                }
            }
            if result.linkedAgents.isEmpty { lines.append("  no agent's skills folder was found; agents that read ~/.agents/skills see it there") }
            io.out(lines.joined(separator: "\n") + "\n")
            return 0
        } catch {
            return io.failure(error.localizedDescription)
        }
    }

    // MARK: - prompt

    private struct PromptOutput: Codable { let language: String; let prompt: String }

    private static func prompt(_ args: inout Arguments, _ env: AgentCLIEnvironment, _ io: Output) -> Int32 {
        let lang = args.value("--lang")
        let request = args.value("--request")
        if let extra = args.leftover() { return io.usageError("prompt does not take \(extra)") }
        let language: AgentPrompt.Language
        switch lang?.lowercased() {
        case nil:
            let configured = ConfigFiles.read(env.location)
                .flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }?[path: "general.language"]?.stringValue
            language = .current(configLanguage: configured)
        case "zh", "zh-hans", "zh-cn": language = .zh
        case "en": language = .en
        default: return io.usageError("--lang is zh or en")
        }
        let text = AgentPrompt.build(language, paths: paths(env), request: request)
        if io.json { return io.emit(PromptOutput(language: language.rawValue, prompt: text)) }
        io.out(text + "\n")
        return 0
    }

    static func paths(_ env: AgentCLIEnvironment) -> AgentPrompt.Paths {
        AgentPrompt.Paths(skillFile: env.skillDirectory.appendingPathComponent("SKILL.md").path,
                          cli: env.cliPath, config: env.location.configURL.path)
    }

    // MARK: - Plumbing

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// The arguments left to read. Options may come anywhere.
    struct Arguments {
        private var items: [String]
        init(_ items: [String]) { self.items = items }

        mutating func flag(_ name: String) -> Bool {
            guard let i = items.firstIndex(of: name) else { return false }
            items.remove(at: i)
            return true
        }

        /// `--name value` or `--name=value`.
        mutating func value(_ name: String) -> String? {
            if let i = items.firstIndex(of: name), i + 1 < items.count {
                let value = items[i + 1]
                items.removeSubrange(i...(i + 1))
                return value
            }
            if let i = items.firstIndex(where: { $0.hasPrefix(name + "=") }) {
                let value = String(items[i].dropFirst(name.count + 1))
                items.remove(at: i)
                return value
            }
            return nil
        }

        /// The next positional argument.
        mutating func next() -> String? {
            guard let i = items.firstIndex(where: { !$0.hasPrefix("--") }) else { return nil }
            return items.remove(at: i)
        }

        /// Whatever was not read, as a phrase for an error message.
        func leftover() -> String? {
            items.isEmpty ? nil : items.map { "\"\($0)\"" }.joined(separator: " ")
        }
    }

    struct Output {
        let json: Bool
        let out: (String) -> Void
        let err: (String) -> Void

        func emit<T: Encodable>(_ value: T) -> Int32 {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let text = (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            out(text + "\n")
            return 0
        }

        private struct Failure: Codable { let ok: Bool; let error: String }

        func failure(_ message: String) -> Int32 {
            if json { _ = emit(Failure(ok: false, error: message)) } else { err("error: \(message)\n") }
            return 1
        }

        func usageError(_ message: String) -> Int32 {
            if json { _ = emit(Failure(ok: false, error: message)) } else { err("error: \(message)\n") }
            return 2
        }
    }
}
