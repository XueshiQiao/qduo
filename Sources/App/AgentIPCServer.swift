import AppKit

/// The running app's side of `AgentIPC`: answers `cli info`, and lets
/// `cli apply` replace the config file safely and restart the app.
///
///     ping    → answer pong (pid, version, config path, settings window open?)
///     prepare → if flush: write any change not yet in the file
///               stop writing the config, answer prepared; with no commit
///               within `AgentIPC.prepareTimeout`, start writing again
///     commit  → restart the app; when the settings window was open, the
///               restarted app opens it on the same page
///     abort   → start writing the config again
///
/// Every request names the config file it is about; one for a different file
/// (a CLI run with `--config`) is ignored.
final class AgentIPCServer {

    private static let log = FileLog("AgentIPC")

    private let appState: AppState
    private var observers: [NSObjectProtocol] = []
    /// The request this app was prepared by, and the timer that gives up on it.
    private var prepared: (id: String, timer: Timer)?

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        let center = DistributedNotificationCenter.default()
        func on(_ name: Notification.Name, _ handle: @escaping (AgentIPC.Request) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let request = AgentIPC.decode(AgentIPC.Request.self, note),
                      request.configPath == self.configPath else { return }
                handle(request)
            })
        }
        on(AgentIPC.Wire.ping) { [weak self] in self?.reply(AgentIPC.Wire.pong, to: $0) }
        on(AgentIPC.Wire.prepare) { [weak self] in self?.prepare($0) }
        on(AgentIPC.Wire.commit) { [weak self] in self?.commit($0) }
        on(AgentIPC.Wire.abort) { [weak self] in self?.abort($0) }
    }

    deinit {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    }

    private var configPath: String { AgentIPC.canonicalPath(ConfigStore.shared.resolvedFileURL) }

    /// The settings window, not a popup panel or the onboarding guide.
    private var settingsWindowVisible: Bool {
        NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue == MainWindowController.windowIdentifier }
    }

    private func instance() -> AgentIPC.Instance {
        AgentIPC.Instance(pid: ProcessInfo.processInfo.processIdentifier,
                          bundleID: Brand.bundleID, name: Brand.name,
                          version: Brand.version, build: Brand.build,
                          executable: Bundle.main.executableURL?.path ?? "",
                          configPath: configPath, windowVisible: settingsWindowVisible)
    }

    private func reply(_ name: Notification.Name, to request: AgentIPC.Request) {
        AgentIPC.post(name, AgentIPC.userInfo(AgentIPC.Reply(requestID: request.requestID, instance: instance())))
    }

    private func prepare(_ request: AgentIPC.Request) {
        if request.flush { ConfigStore.shared.flush() }
        prepared?.timer.invalidate()
        if prepared == nil { ConfigStore.shared.prepareForRestore() }
        let timer = Timer.scheduledTimer(withTimeInterval: AgentIPC.prepareTimeout, repeats: false) { [weak self] _ in
            Self.log.warn("prepared for a config replacement that never came — writing the config again")
            self?.prepared = nil
            ConfigStore.shared.resumeWrites()
        }
        prepared = (request.requestID, timer)
        Self.log.info("prepared for a config replacement from the command line")
        reply(AgentIPC.Wire.prepared, to: request)
    }

    private func commit(_ request: AgentIPC.Request) {
        guard let prepared, prepared.id == request.requestID else { return }
        prepared.timer.invalidate()
        let arguments = settingsWindowVisible ? ["--settings", "--page", appState.selection.rawValue] : []
        Self.log.info("the command line replaced the config — restarting to read it")
        AppRelaunch.relaunch(arguments: arguments)
    }

    private func abort(_ request: AgentIPC.Request) {
        guard let prepared, prepared.id == request.requestID else { return }
        prepared.timer.invalidate()
        self.prepared = nil
        ConfigStore.shared.resumeWrites()
        Self.log.info("the command line did not replace the config after all")
    }
}
