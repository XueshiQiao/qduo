import AppKit
import AIModelKit

/// The answers about this Mac that the unit tests cannot give: which SF
/// Symbols exist, which apps are installed, which API keys are saved, what
/// each provider accepts. Kept out of the files the test target compiles,
/// because they need AppKit, the Keychain and AIModelKit.
///
/// Inside an agent's sandbox (`AgentSandbox`) Launch Services answers "not
/// installed" for every app and the Keychain answers with an error, so those
/// two questions get "cannot tell" (nil) there instead of a wrong answer.
extension ValidationEnvironment {
    static var live: ValidationEnvironment { live(sandboxed: AgentSandbox.isActive) }

    static func live(sandboxed: Bool) -> ValidationEnvironment {
        let keys = LLMKeyStore()
        return ValidationEnvironment(
            symbolExists: { SymbolCatalog.exists($0) },
            appInstalled: { id in
                sandboxed ? nil : NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
            },
            hasAPIKey: { id in
                guard !sandboxed, let provider = Provider.named(id), provider.needsKey else { return nil }
                return keys.hasKey(for: id)
            },
            thinkingValues: { id in
                // A custom provider's choices depend on its format, and a gateway
                // passes any level on; neither has a fixed list.
                guard let provider = Provider.named(id), id != Provider.custom.id,
                      provider.dialect(for: provider.format) != .gateway else { return nil }
                return provider.thinkingOptions().map(\.tag)
            })
    }
}

/// The SF Symbol names this Mac has, read from the system's own list.
///
/// Not `NSImage(systemSymbolName:)`: drawing a symbol connects the process to
/// the window server, which a sandbox forbids — the command line was killed
/// there. The list is the one SF Symbols itself ships in CoreGlyphs; when it
/// cannot be read, the answer is "cannot tell" (nil) and nothing is reported.
enum SymbolCatalog {
    private static let resources = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources")

    /// Every name and every older alias of a name.
    private static let names: Set<String>? = {
        func plist(_ file: String) -> Any? {
            (try? Data(contentsOf: resources.appendingPathComponent(file)))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
        }
        guard let symbols = (plist("name_availability.plist") as? [String: Any])?["symbols"] as? [String: Any],
              !symbols.isEmpty else { return nil }
        let aliases = (plist("name_aliases.strings") as? [String: String]) ?? [:]
        return Set(symbols.keys).union(aliases.keys)
    }()

    static func exists(_ name: String) -> Bool? {
        names.map { $0.contains(name) }
    }
}

extension AgentCLIEnvironment {
    static var live: AgentCLIEnvironment {
        var env = AgentCLIEnvironment()
        env.sandboxed = AgentSandbox.isActive
        env.validation = .live(sandboxed: env.sandboxed)
        // Release is the base id, Debug the base id + ".debug" (project.yml).
        // Both read the same config file.
        var ipc = LiveAgentIPCClient()
        ipc.processes = {
            // NSRunningApplication sees nothing in a sandbox; the CLI does not ask there.
            [Brand.baseID, Brand.baseID + ".debug"].flatMap { id in
                NSRunningApplication.runningApplications(withBundleIdentifier: id)
                    .filter { !$0.isTerminated && $0.processIdentifier != getpid() }
                    .map { AgentIPC.Process(pid: $0.processIdentifier, bundleID: id) }
            }
        }
        env.ipc = ipc
        let sandboxed = env.sandboxed
        env.providers = {
            let keys = LLMKeyStore()
            return Provider.all.map { p in
                ProviderInfo(id: p.id, name: p.displayName, format: p.format.rawValue,
                             defaultURL: p.defaultURL, defaultModel: p.defaultModel, needsKey: p.needsKey,
                             hasKey: p.needsKey && !sandboxed ? keys.hasKey(for: p.id) : nil,
                             thinking: p.thinkingOptions().map(\.tag))
            }
        }
        return env
    }
}
