import Foundation

/// How the command line talks to a running copy of the app, over
/// `DistributedNotificationCenter`.
///
/// The app reads its config once, at launch (see `ConfigStore`), so a new
/// config takes effect by restarting the app. Replacing the file under a
/// running app is not safe on its own: the app keeps the old settings in
/// memory, and its next save — or the save at quit — would move the new file
/// aside and write the old settings back. So `cli apply` goes in three steps:
///
///     CLI sends prepare → each running app writes any pending change to the
///                         file, then stops writing it, and answers prepared
///     CLI backs up the current file and writes the new one
///     CLI sends commit  → each app quits and starts again, reading the new file
///     (on a failure in between: abort → the app writes again; nothing changed)
///
/// Release and Debug builds read the same config file, so both answer. Every
/// message carries the config file's resolved path, and an app whose file is a
/// different one ignores it. An app that was prepared and then hears nothing
/// resumes writing by itself after `prepareTimeout`.
enum AgentIPC {

    static let prepareTimeout: TimeInterval = 20

    enum Wire {
        static var ping: Notification.Name { name("ping") }
        static var pong: Notification.Name { name("pong") }
        static var prepare: Notification.Name { name("prepare") }
        static var prepared: Notification.Name { name("prepared") }
        static var commit: Notification.Name { name("commit") }
        static var abort: Notification.Name { name("abort") }

        private static func name(_ suffix: String) -> Notification.Name {
            Notification.Name("\(Brand.baseID).agent.\(suffix)")
        }
    }

    struct Request: Codable, Equatable {
        let requestID: String
        let configPath: String
        /// `prepare` only: write any pending change first. False when the file
        /// was already edited on disk and is what should win.
        var flush: Bool = true
    }

    /// A running copy of the app, as it describes itself.
    struct Instance: Codable, Equatable {
        let pid: Int32
        let bundleID: String
        let name: String
        let version: String
        let build: String
        let executable: String
        let configPath: String
        /// The settings window is open, so the restarted app opens it again.
        let windowVisible: Bool
    }

    // MARK: - Encoding

    static func userInfo<T: Encodable>(_ payload: T) -> [String: Any] {
        let json = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ["payload": json]
    }

    static func decode<T: Decodable>(_ type: T.Type, _ note: Notification) -> T? {
        guard let json = note.userInfo?["payload"] as? String, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    struct Reply: Codable {
        let requestID: String
        let instance: Instance
    }

    static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func post(_ name: Notification.Name, _ info: [String: Any]) {
        // In a sandbox, posting kills the process (`AgentSandbox`); the CLI
        // does not get here then, and this keeps it that way.
        guard !AgentSandbox.isActive else { return }
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: info,
                                                                     deliverImmediately: true)
    }
}

/// The command line's side. A protocol so the CLI tests can stand in for the
/// running app.
protocol AgentIPCClient {
    /// Every running copy of the app that reads `configPath`.
    func ping(configPath: String) -> [AgentIPC.Instance]
    /// Ask them to stop writing the file. Returns those that did.
    func prepare(configPath: String, flush: Bool) -> (requestID: String, instances: [AgentIPC.Instance])
    func commit(requestID: String, configPath: String)
    func abort(requestID: String, configPath: String)
    /// Whether a process is still alive.
    func isRunning(pid: Int32) -> Bool
    /// Every copy of the app the system sees running, Release and Debug,
    /// whether or not it answers — an older version cannot.
    func runningProcesses() -> [AgentIPC.Process]
}

extension AgentIPC {
    struct Process: Codable, Equatable {
        let pid: Int32
        let bundleID: String
    }
}

struct LiveAgentIPCClient: AgentIPCClient {

    /// How long to collect answers. Both builds answer within a few
    /// milliseconds when they are running; a quiet window means none is.
    var window: TimeInterval = 0.6

    /// Set by the live environment, which has AppKit (`NSRunningApplication`).
    var processes: () -> [AgentIPC.Process] = { [] }

    func runningProcesses() -> [AgentIPC.Process] { processes() }

    func ping(configPath: String) -> [AgentIPC.Instance] {
        exchange(send: AgentIPC.Wire.ping, reply: AgentIPC.Wire.pong,
                 request: AgentIPC.Request(requestID: UUID().uuidString, configPath: configPath))
    }

    func prepare(configPath: String, flush: Bool) -> (requestID: String, instances: [AgentIPC.Instance]) {
        let request = AgentIPC.Request(requestID: UUID().uuidString, configPath: configPath, flush: flush)
        return (request.requestID, exchange(send: AgentIPC.Wire.prepare, reply: AgentIPC.Wire.prepared, request: request))
    }

    func commit(requestID: String, configPath: String) {
        AgentIPC.post(AgentIPC.Wire.commit, AgentIPC.userInfo(AgentIPC.Request(requestID: requestID, configPath: configPath)))
    }

    func abort(requestID: String, configPath: String) {
        AgentIPC.post(AgentIPC.Wire.abort, AgentIPC.userInfo(AgentIPC.Request(requestID: requestID, configPath: configPath)))
    }

    func isRunning(pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func exchange(send: Notification.Name, reply: Notification.Name,
                          request: AgentIPC.Request) -> [AgentIPC.Instance] {
        let center = DistributedNotificationCenter.default()
        var found: [AgentIPC.Instance] = []
        let observer = center.addObserver(forName: reply, object: nil, queue: nil) { note in
            guard let answer = AgentIPC.decode(AgentIPC.Reply.self, note),
                  answer.requestID == request.requestID,
                  !found.contains(where: { $0.pid == answer.instance.pid }) else { return }
            found.append(answer.instance)
        }
        defer { center.removeObserver(observer) }
        AgentIPC.post(send, AgentIPC.userInfo(request))
        let deadline = Date().addingTimeInterval(window)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.03)))
        }
        return found.sorted { $0.pid < $1.pid }
    }
}
