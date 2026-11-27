import Foundation

/// Where the command line finds the config file and keeps its backups, and the
/// file operations `cli apply` and `cli rollback` are made of.
///
/// The app's own `ConfigStore` is not used here: it loads the file and seeds a
/// new one when there is none, which is right for the app and wrong for a
/// command that is only asked to check or replace it.
struct ConfigLocation: Equatable {
    /// The config file as configured — possibly a symlink into a dotfiles repo.
    let configURL: URL
    /// Where `cli apply` keeps the versions it replaced.
    let backupDirectory: URL

    /// The real file. Everything that writes resolves this first, because an
    /// atomic write to a symlink replaces the symlink with a regular file
    /// (the same rule `ConfigStore.resolvedFileURL` follows).
    var resolvedURL: URL { configURL.resolvingSymlinksInPath() }

    var isSymlink: Bool { resolvedURL.standardizedFileURL.path != configURL.standardizedFileURL.path }

    /// The schema the app writes beside the resolved file.
    var schemaURL: URL { resolvedURL.deletingLastPathComponent().appendingPathComponent("config.schema.json") }

    /// `~/.config/<slug>/config.json`, with backups in Application Support —
    /// app-owned files, kept out of a config folder that may be a git repo.
    static var live: ConfigLocation {
        ConfigLocation(configURL: Brand.configDirectory.appendingPathComponent("config.json"),
                       backupDirectory: Brand.sharedSupportDirectory.appendingPathComponent("config-backups", isDirectory: true))
    }
}

/// One saved version of the config.
struct ConfigBackup: Codable, Equatable {
    let file: String
    let path: String
    let created: String
    let bytes: Int
}

enum ConfigFiles {

    /// How many backups are kept. The oldest go first.
    static let keepBackups = 50

    static func read(_ location: ConfigLocation) -> Data? {
        try? Data(contentsOf: location.resolvedURL)
    }

    /// Copy the current file into the backup folder. Returns the copy, or nil
    /// when there was no file to copy.
    @discardableResult
    static func backUpCurrent(_ location: ConfigLocation, now: Date = Date()) throws -> URL? {
        guard let current = read(location) else { return nil }
        let fm = FileManager.default
        try fm.createDirectory(at: location.backupDirectory, withIntermediateDirectories: true)
        let stem = "config-\(timestamp(now))"
        var url = location.backupDirectory.appendingPathComponent("\(stem).json")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = location.backupDirectory.appendingPathComponent("\(stem)-\(n).json")
            n += 1
        }
        try current.write(to: url, options: .atomic)
        prune(location)
        return url
    }

    /// Put `data` in place of the config, atomically, at the resolved path so a
    /// symlinked config stays a symlink.
    static func write(_ data: Data, to location: ConfigLocation) throws {
        let url = location.resolvedURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Newest first.
    static func backups(_ location: ConfigLocation) -> [ConfigBackup] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: location.backupDirectory.path) else { return [] }
        return names
            .filter { $0.hasPrefix("config-") && $0.hasSuffix(".json") }
            .sorted(by: >)
            .map { name in
                let url = location.backupDirectory.appendingPathComponent(name)
                let attributes = try? fm.attributesOfItem(atPath: url.path)
                let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
                return ConfigBackup(file: name, path: url.path, created: createdText(name), bytes: size)
            }
    }

    /// The backup a `rollback` argument names: a file name in the backup
    /// folder, or a path to one.
    static func backup(named name: String, in location: ConfigLocation) -> URL? {
        let fm = FileManager.default
        let direct = location.backupDirectory.appendingPathComponent(name)
        if !name.contains("/"), fm.fileExists(atPath: direct.path) { return direct }
        let expanded = URL(fileURLWithPath: (name as NSString).expandingTildeInPath)
        return fm.fileExists(atPath: expanded.path) ? expanded : nil
    }

    private static func prune(_ location: ConfigLocation) {
        for old in backups(location).dropFirst(keepBackups) {
            try? FileManager.default.removeItem(atPath: old.path)
        }
    }

    // MARK: - Names

    /// Milliseconds included, so two applies in one second still sort in the
    /// order they happened.
    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    /// `config-20261127-153012-123.json` → `2026-11-27 15:30:12`.
    private static func createdText(_ name: String) -> String {
        let parts = name.dropFirst("config-".count).split(separator: "-")
        guard parts.count >= 2, parts[0].count == 8, parts[1].count == 6 else { return "" }
        let d = Array(parts[0]), t = Array(parts[1])
        return "\(String(d[0..<4]))-\(String(d[4..<6]))-\(String(d[6..<8])) \(String(t[0..<2])):\(String(t[2..<4])):\(String(t[4..<6]))"
    }
}
