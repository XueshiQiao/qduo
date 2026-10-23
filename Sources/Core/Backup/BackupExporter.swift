import Foundation

/// Writes one backup zip: a single folder named `<app>-backup-YYYY-MM-DD`
/// holding the parts the person ticked. The app's name comes from `Brand`.
///
/// The long work (stretching the password, the history snapshot, the zip) is
/// done off the main thread. The config file is flushed on the main thread
/// first, because `ConfigStore` only writes there.
enum BackupExporter {

    enum Failure: Error {
        case passwordRequired
        case nothingSelected
        case unreadable
        case badArchive
    }

    private static let log = FileLog("Backup")

    /// `QDuo-backup-2026-10-19`, without the `.zip`.
    static func stem(on date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(Brand.name)-backup-\(formatter.string(from: date))"
    }

    static func suggestedFileName(on date: Date = Date()) -> String {
        stem(on: date) + ".zip"
    }

    /// Icon pictures that are regular PNG files with the PNG signature. The
    /// same list the export writes, so the count the sheet shows is the count
    /// that ends up in the zip.
    static func readableIcons() -> [(name: String, data: Data)] {
        let directory = ActionIconStore.directory.resolvingSymlinksInPath()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var found: [(String, Data)] = []
        for name in names.sorted() {
            guard BackupEntryRules.isIconFileName(name) else { continue }
            let url = directory.appendingPathComponent(name)
            // The same limit the import applies, so every picture that goes out comes back in.
            guard let data = try? BackupFiles.readRegularFile(at: url, maxBytes: BackupFiles.maxIconBytes),
                  ActionIconStore.isPNG(data) else { continue }
            found.append((name, data))
        }
        return found
    }

    static func export(parts: Set<BackupManifest.Part>, password: String?, to destination: URL) async throws -> BackupManifest {
        guard !parts.isEmpty else { throw Failure.nothingSelected }
        if parts.contains(.keys) {
            guard let password, !password.isEmpty else { throw Failure.passwordRequired }
        }
        let configData: Data? = try await MainActor.run {
            guard parts.contains(.config) else { return nil }
            ConfigStore.shared.flush()
            return try BackupFiles.readRegularFile(at: ConfigStore.shared.resolvedFileURL,
                                                    maxBytes: BackupFiles.maxDocumentBytes)
        }
        return try await Task.detached(priority: .userInitiated) {
            let icons = parts.contains(.icons) ? readableIcons() : []
            return try await write(parts: parts, password: password, configData: configData, icons: icons, to: destination)
        }.value
    }

    // MARK: - Off the main thread

    private static func write(parts: Set<BackupManifest.Part>, password: String?, configData: Data?,
                              icons: [(name: String, data: Data)], to destination: URL) async throws -> BackupManifest {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("\(Brand.slug)-backup-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratch) }
        // One clock reading for the folder name and the manifest, so an export
        // that runs across midnight does not get two different dates.
        let now = Date()
        let rootName = stem(on: now)
        let root = scratch.appendingPathComponent(rootName, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let exportedAt = BackupManifest.exportedAtString(now)

        var keys: (items: [String: String], password: String)?
        if parts.contains(.keys) {
            guard let password else { throw Failure.passwordRequired }
            do {
                keys = (try KeychainStore(service: Brand.keychainService).allItems(), password)
            } catch {
                log.error("could not read the keychain: \(error)")
                throw Failure.unreadable
            }
        }
        if parts.contains(.config) && configData == nil { throw Failure.unreadable }
        var historyRecords: Int?
        if parts.contains(.history) {
            historyRecords = try await HistoryStore.shared.snapshot(to: root.appendingPathComponent("history.sqlite"))
        }
        let manifest = try BackupLayout.write(
            into: root, exportedAt: exportedAt,
            app: .init(version: Brand.version, build: Brand.build, bundleID: Brand.bundleID),
            config: parts.contains(.config) ? configData : nil,
            icons: parts.contains(.icons) ? icons : nil,
            keys: keys, historyRecords: historyRecords)

        // Zip beside the folder first and look at the names. The destination is
        // only replaced once the zip is one backup folder — a failed export must
        // not wipe a file the person already had there.
        let staging = scratch.appendingPathComponent("staging.zip")
        try BackupArchive.zip(directory: root, to: staging)
        let entries = try BackupArchive.listEntries(of: staging)
        guard BackupEntryRules.rootDirectory(of: entries) == rootName else {
            log.error("archive entries were not one backup folder: \(entries.joined(separator: ", "))")
            throw Failure.badArchive
        }
        // Read the zip back the way the import will, password included, so a
        // backup that would not import is never handed over.
        do {
            try BackupLayout.verify(staging, password: password)
        } catch {
            log.error("the new backup does not read back: \(error)")
            throw Failure.badArchive
        }
        try place(staging, at: destination)
        log.info("exported \(parts.map(\.rawValue).sorted().joined(separator: ", "))")
        return manifest
    }

    private static func place(_ zip: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
        do {
            try fileManager.copyItem(at: zip, to: partial)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
            } else {
                try fileManager.moveItem(at: partial, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }
}
