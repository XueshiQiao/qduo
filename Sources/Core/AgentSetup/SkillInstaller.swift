import Foundation

/// The Agent Skill bundled with the app: a folder with `SKILL.md` that teaches
/// an AI coding agent (Claude Code, Codex, Cursor…) how this app's config file
/// works and how to change it with the command line.
///
/// In the repository it is `skill/`; in the built app it is
/// `Contents/Resources/skill/`.
enum BundledSkill {

    /// The folder name agents know the skill by: the `name:` in the skill's
    /// own SKILL.md, so the folder and the file can never disagree.
    static var name: String { name(of: directory()) }

    static func name(of skill: URL) -> String {
        guard let text = try? String(contentsOf: skill.appendingPathComponent("SKILL.md"), encoding: .utf8) else {
            return Brand.slug
        }
        for line in text.components(separatedBy: .newlines).prefix(10) where line.hasPrefix("name:") {
            let value = line.dropFirst("name:".count).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return Brand.slug
    }

    static func directory(bundle: Bundle = .main) -> URL {
        if let resources = bundle.resourceURL {
            let bundled = resources.appendingPathComponent("skill", isDirectory: true)
            if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("SKILL.md").path) {
                return bundled
            }
        }
        // Unbundled (the unit tests): the repository's copy, found from this file.
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AgentSetup
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("skill", isDirectory: true)
    }

    static func skillFile(bundle: Bundle = .main) -> URL {
        directory(bundle: bundle).appendingPathComponent("SKILL.md")
    }
}

/// A coding agent the skill can be linked into.
enum SkillAgent: String, Codable, CaseIterable {
    case claude, codex, cursor, gemini, windsurf, cline, copilot

    /// Shown in the settings page.
    var displayName: String {
        switch self {
        case .claude:   return "Claude Code"
        case .codex:    return "Codex"
        case .cursor:   return "Cursor"
        case .gemini:   return "Gemini / Antigravity"
        case .windsurf: return "Windsurf"
        case .cline:    return "Cline"
        case .copilot:  return "GitHub Copilot"
        }
    }

    /// (the folder that shows the agent is installed, its skills folder),
    /// relative to the home folder.
    var locations: [(detect: String, skills: String)] {
        switch self {
        case .claude:   return [(".claude", ".claude/skills")]
        case .codex:    return [(".codex", ".codex/skills")]
        case .cursor:   return [(".cursor", ".cursor/skills")]
        case .gemini:   return [(".gemini/config", ".gemini/config/skills"),
                                (".gemini/antigravity", ".gemini/antigravity/skills")]
        case .windsurf: return [(".codeium/windsurf", ".codeium/windsurf/skills")]
        case .cline:    return [(".cline", ".cline/skills")]
        case .copilot:  return [(".copilot", ".copilot/skills")]
        }
    }
}

struct SkillInstallResult: Codable, Equatable {
    struct Link: Codable, Equatable {
        enum Status: String, Codable {
            /// A symlink to the installed copy is there now.
            case linked
            /// The agent is not on this Mac (no config folder), so nothing was made.
            case notDetected
            /// Something that is not ours is already at that path — a folder the
            /// user put there — and was left alone.
            case keptExisting
        }
        let agent: SkillAgent
        let path: String
        let status: Status
    }
    /// The copy every agent links to: `~/.agents/skills/<name>`.
    let installedDirectory: String
    let links: [Link]

    var linkedAgents: [SkillAgent] {
        var seen: [SkillAgent] = []
        for link in links where link.status == .linked && !seen.contains(link.agent) { seen.append(link.agent) }
        return seen
    }
}

enum SkillInstallError: LocalizedError {
    case bundledSkillMissing(String)
    case notOurs(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .bundledSkillMissing(let path): return "the bundled skill is missing (looked in \(path))"
        case .notOurs(let path): return "\(path) already exists and is not this app's skill; move it away first"
        case .io(let message): return message
        }
    }
}

/// Copies the bundled skill to `~/.agents/skills/<name>` (the shared location
/// several agents read), then links it into each agent's own skills folder.
///
///     ~/.agents/skills/<name>:
///         missing, a symlink, or a folder holding this app's SKILL.md
///             → replaced by this build's copy
///         anything else (a folder of the user's own) → error, left alone
///     each agent's skills/<name>:
///         agent not installed (no config folder) and not asked for by name
///             → nothing made, notDetected
///         missing or a symlink → symlink to the copy above, linked
///         a real folder → left alone, keptExisting
///
/// Installing again replaces the copy, which is how an app update reaches the
/// agents: the page offers it again when the copy is older than the app's.
enum SkillInstaller {

    static func install(agents requested: [SkillAgent]? = nil,
                        source: URL = BundledSkill.directory(),
                        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) throws -> SkillInstallResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else {
            throw SkillInstallError.bundledSkillMissing(source.path)
        }
        let name = BundledSkill.name(of: source)
        let installed = installedDirectory(home: home, name: name)

        do {
            try fm.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
            if exists(installed) {
                guard isSymlink(installed) || isSkill(installed, named: name) else { throw SkillInstallError.notOurs(installed.path) }
            }
            let staging = installed.deletingLastPathComponent()
                .appendingPathComponent(".\(name)-staging-\(UUID().uuidString)", isDirectory: true)
            try fm.copyItem(at: source, to: staging)
            if exists(installed) { try fm.removeItem(at: installed) }
            try fm.moveItem(at: staging, to: installed)
        } catch let error as SkillInstallError {
            throw error
        } catch {
            throw SkillInstallError.io("could not install the skill to \(installed.path): \(error.localizedDescription)")
        }

        var links: [SkillInstallResult.Link] = []
        for agent in requested ?? SkillAgent.allCases {
            for location in agent.locations {
                let link = home.appendingPathComponent(location.skills, isDirectory: true)
                    .appendingPathComponent(name)
                let detected = fm.fileExists(atPath: home.appendingPathComponent(location.detect).path)
                // Without a list, only agents that are installed get a link; an
                // agent asked for by name gets its skills folder made.
                guard requested != nil || detected else {
                    links.append(.init(agent: agent, path: link.path, status: .notDetected))
                    continue
                }
                if exists(link), !isSymlink(link) {
                    links.append(.init(agent: agent, path: link.path, status: .keptExisting))
                    continue
                }
                do {
                    try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if exists(link) { try fm.removeItem(at: link) }
                    try fm.createSymbolicLink(at: link, withDestinationURL: installed)
                    links.append(.init(agent: agent, path: link.path, status: .linked))
                } catch {
                    throw SkillInstallError.io("could not link \(link.path): \(error.localizedDescription)")
                }
            }
        }
        return SkillInstallResult(installedDirectory: installed.path, links: links)
    }

    static func installedDirectory(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
                                   name: String = BundledSkill.name) -> URL {
        home.appendingPathComponent(".agents/skills", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    /// Whether the installed copy is the same as the one in this build — false
    /// when it is missing or was installed by an older version of the app.
    static func installedCopyIsCurrent(source: URL = BundledSkill.directory(),
                                       home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> Bool {
        let installed = installedDirectory(home: home, name: BundledSkill.name(of: source))
        return contents(of: source) == contents(of: installed) && !contents(of: source).isEmpty
    }

    /// The agents that have the skill linked right now.
    static func linkedAgents(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
                             name: String = BundledSkill.name) -> [SkillAgent] {
        let installed = installedDirectory(home: home, name: name).standardizedFileURL.path
        return SkillAgent.allCases.filter { agent in
            agent.locations.contains { location in
                let link = home.appendingPathComponent(location.skills).appendingPathComponent(name)
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return false }
                return URL(fileURLWithPath: target).standardizedFileURL.path == installed
            }
        }
    }

    // MARK: - Helpers

    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil   // true for a dangling link too
    }

    private static func isSymlink(_ url: URL) -> Bool {
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        return type == .typeSymbolicLink
    }

    /// A folder whose SKILL.md says `name: <name>` — a copy this app installed.
    private static func isSkill(_ url: URL, named name: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("SKILL.md").path)
            && BundledSkill.name(of: url) == name
    }

    /// Every file under a folder, by relative path, with its bytes.
    private static func contents(of directory: URL) -> [String: Data] {
        let fm = FileManager.default
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var files: [String: Data] = [:]
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  url.lastPathComponent != ".DS_Store",
                  let data = try? Data(contentsOf: url) else { continue }
            let relative = url.standardizedFileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            files[relative] = data
        }
        return files
    }
}
