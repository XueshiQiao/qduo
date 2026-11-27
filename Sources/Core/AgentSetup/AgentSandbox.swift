import Foundation

/// Whether the command line runs inside a sandbox, as an AI agent's command
/// tool often runs it: Codex runs every command in a macOS sandbox unless the
/// user approves running it outside, and Cursor and Claude Code can do the
/// same.
///
/// Such a sandbox lets the command line read files (the skill, the config,
/// the schema) but not write the config, and it blocks or misleads the system
/// services the command line asks about the running app:
///
///     posting a distributed notification (cli → app) → the process is killed
///     drawing an SF Symbol (connects to the window server) → the process is killed
///     "is this app installed?" (Launch Services)       → always "no"
///     "is there a key?" (Keychain)                      → an error
///     "which copies are running?" (NSRunningApplication) → none
///
/// So inside a sandbox the command line skips those questions, and the
/// commands that change something stop with a message telling the agent to run
/// them again outside the sandbox, instead of being killed without a word.
enum AgentSandbox {

    /// `sandbox_check(getpid(), NULL, 0)` from libsystem_sandbox: non-zero when
    /// this process runs under any sandbox profile. Looked up at run time, as
    /// the function has no public header.
    static let isActive: Bool = {
        typealias Check = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "sandbox_check") else { return false }
        return unsafeBitCast(symbol, to: Check.self)(getpid(), nil, 0) != 0
    }()
}
