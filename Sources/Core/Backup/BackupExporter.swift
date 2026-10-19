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
        var manifestParts = BackupManifest.Parts()

        if parts.contains(.config) {
            guard let configData else { throw Failure.unreadable }
            try configData.write(to: root.appendingPathComponent("config.json"), options: .atomic)
            manifestParts.config = .init(file: "config.json")
        }
        if parts.contains(.icons) {
            let iconsDir = root.appendingPathComponent("icons", isDirectory: true)
            try fileManager.createDirectory(at: iconsDir, withIntermediateDirectories: true)
            for (name, data) in icons {
                try data.write(to: iconsDir.appendingPathComponent(name), options: .atomic)
            }
            manifestParts.icons = .init(dir: "icons", count: icons.count)
        }
        if parts.contains(.keys) {
            guard let password else { throw Failure.passwordRequired }
            let items: [String: String]
            do {
                items = try KeychainStore(service: Brand.keychainService).allItems()
            } catch {
                log.error("could not read the keychain: \(error)")
                throw Failure.unreadable
            }
            let plaintext = try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
            let envelope = try BackupCrypto.seal(plaintext, password: password,
                                                  aad: BackupManifest.keysAAD(format: BackupManifest.format,
                                                                               exportedAt: exportedAt))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var encoded = try encoder.encode(envelope)
            encoded.append(0x0A)
            try encoded.write(to: root.appendingPathComponent("keys.enc"), options: .atomic)
            manifestParts.keys = .init(file: "keys.enc", encrypted: true, count: items.count)
        }
        if parts.contains(.history) {
            let snapshot = root.appendingPathComponent("history.sqlite")
            let records = try await HistoryStore.shared.snapshot(to: snapshot)
            manifestParts.history = .init(file: "history.sqlite", records: records)
        }

        let manifest = BackupManifest(
            format: BackupManifest.format,
            app: .init(version: Brand.version, build: Brand.build, bundleID: Brand.bundleID),
            exportedAt: exportedAt,
            parts: manifestParts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var manifestData = try encoder.encode(manifest)
        manifestData.append(0x0A)
        try manifestData.write(to: root.appendingPathComponent("manifest.json"), options: .atomic)

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
