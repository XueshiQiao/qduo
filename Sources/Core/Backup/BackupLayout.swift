import Foundation

/// What is inside a backup folder, written by the export and checked by the
/// import. Both sides call this file, and so do the tests, so a backup the
/// export writes is a backup the import accepts. Nothing here touches the
/// keychain, the config store or the history database: the callers read those
/// and pass the bytes in.
enum BackupLayout {

    enum Failure: Error, Equatable {
        case notABackup
        case newerFormat
        case tooLarge
    }

    /// Writes the chosen parts and `manifest.json` into `root`. A part that is
    /// nil is left out. `historyRecords` is non-nil only when the caller has
    /// already put `history.sqlite` in `root`.
    static func write(into root: URL, exportedAt: String, app: BackupManifest.AppInfo,
                      config: Data?, icons: [(name: String, data: Data)]?,
                      keys: (items: [String: String], password: String)?,
                      historyRecords: Int?) throws -> BackupManifest {
        let fileManager = FileManager.default
        var parts = BackupManifest.Parts()
        if let config {
            try config.write(to: root.appendingPathComponent("config.json"), options: .atomic)
            parts.config = .init(file: "config.json")
        }
        if let icons {
            let dir = root.appendingPathComponent("icons", isDirectory: true)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, data) in icons {
                try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            }
            parts.icons = .init(dir: "icons", count: icons.count)
        }
        if let keys {
            let sealed = try BackupKeysFile.encode(
                keys.items, password: keys.password,
                aad: BackupManifest.keysAAD(format: BackupManifest.format, exportedAt: exportedAt))
            try sealed.write(to: root.appendingPathComponent("keys.enc"), options: .atomic)
            parts.keys = .init(file: "keys.enc", encrypted: true, count: keys.items.count)
        }
        if let historyRecords {
            guard BackupFiles.isRegularFile(root.appendingPathComponent("history.sqlite")) else {
                throw Failure.notABackup
            }
            parts.history = .init(file: "history.sqlite", records: historyRecords)
        }
        let manifest = BackupManifest(format: BackupManifest.format, app: app,
                                      exportedAt: exportedAt, parts: parts)
        try manifest.fileData().write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        return manifest
    }

    /// Checks a backup zip and unpacks it into `scratch`, which must exist and
    /// be empty. Returns the name of the one folder inside and its manifest.
    static func unpack(_ zip: URL, into scratch: URL) throws -> (root: String, manifest: BackupManifest) {
        let listed: [String]
        do {
            listed = try BackupArchive.listEntries(of: zip)
        } catch {
            throw Failure.notABackup
        }
        guard let root = BackupEntryRules.rootDirectory(of: listed),
              listed.contains("\(root)/manifest.json") else { throw Failure.notABackup }

        // What the zip says it unpacks to, before it is unpacked: a small file
        // that expands to fill the disk is refused here, not after.
        guard let declared = try? BackupArchive.declaredUncompressedSize(of: zip) else { throw Failure.notABackup }
        guard declared <= BackupFiles.maxArchiveBytes else { throw Failure.tooLarge }

        do {
            try BackupArchive.unzip(zip, into: scratch)
        } catch {
            throw Failure.notABackup
        }
        let disk: [String]
        do {
            disk = try BackupFiles.relativeEntries(under: scratch, maxBytes: BackupFiles.maxArchiveBytes)
        } catch BackupFiles.Failure.tooLarge {
            throw Failure.tooLarge
        } catch {
            throw Failure.notABackup
        }
        guard BackupEntryRules.rootDirectory(of: disk) == root,
              BackupFiles.isCovered(disk, by: listed),
              disk.contains("\(root)/manifest.json") else { throw Failure.notABackup }
        let folder = scratch.appendingPathComponent(root, isDirectory: true)
        let manifest = try readManifest(in: folder)
        try requireFiles(namedBy: manifest, in: folder)
        return (root, manifest)
    }

    static func readManifest(in folder: URL) throws -> BackupManifest {
        let data: Data
        do {
            data = try BackupFiles.readRegularFile(at: folder.appendingPathComponent("manifest.json"),
                                                   maxBytes: BackupFiles.maxDocumentBytes)
        } catch BackupFiles.Failure.tooLarge {
            throw Failure.tooLarge
        } catch {
            throw Failure.notABackup
        }
        let manifest: BackupManifest
        do {
            manifest = try JSONDecoder().decode(BackupManifest.self, from: data)
        } catch {
            throw Failure.notABackup
        }
        if manifest.isNewerThanThisBuild { throw Failure.newerFormat }
        guard manifest.format == BackupManifest.format, !manifest.exportedAt.isEmpty,
              !manifest.availableParts.isEmpty else { throw Failure.notABackup }
        if let config = manifest.parts.config, config.file != "config.json" { throw Failure.notABackup }
        if let icons = manifest.parts.icons, icons.dir != "icons" || icons.count < 0 { throw Failure.notABackup }
        if let keys = manifest.parts.keys,
           keys.file != "keys.enc" || keys.encrypted != true || keys.count < 0 { throw Failure.notABackup }
        if let history = manifest.parts.history,
           history.file != "history.sqlite" || history.records < 0 { throw Failure.notABackup }
        return manifest
    }

    /// Every file the manifest names is there. The icons folder may be missing
    /// when the manifest says it holds no pictures: a zip does not keep an
    /// empty folder.
    private static func requireFiles(namedBy manifest: BackupManifest, in folder: URL) throws {
        if manifest.parts.config != nil && !BackupFiles.isRegularFile(folder.appendingPathComponent("config.json")) {
            throw Failure.notABackup
        }
        if manifest.parts.keys != nil && !BackupFiles.isRegularFile(folder.appendingPathComponent("keys.enc")) {
            throw Failure.notABackup
        }
        if manifest.parts.history != nil && !BackupFiles.isRegularFile(folder.appendingPathComponent("history.sqlite")) {
            throw Failure.notABackup
        }
        if let icons = manifest.parts.icons, icons.count > 0,
           !BackupFiles.isDirectory(folder.appendingPathComponent("icons")) {
            throw Failure.notABackup
        }
    }

    /// The icon pictures in an unpacked backup: regular PNG files with an icon
    /// file name, at most `maxIconBytes` each. No folder means no pictures.
    static func icons(in folder: URL) throws -> [(name: String, data: Data)] {
        let source = folder.appendingPathComponent("icons", isDirectory: true)
        guard BackupFiles.isDirectory(source) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: source.path)
        var icons: [(String, Data)] = []
        for name in names.sorted() {
            guard BackupEntryRules.isIconFileName(name),
                  let data = try? BackupFiles.readRegularFile(at: source.appendingPathComponent(name),
                                                              maxBytes: BackupFiles.maxIconBytes),
                  ActionIconStore.isPNG(data) else { continue }
            icons.append((name, data))
        }
        return icons
    }

    /// Reads a zip back the way the import will, before the export hands it
    /// over: it must unpack, its manifest must check out, and when it holds
    /// keys, `password` must open them. Thrown errors are the import's.
    static func verify(_ zip: URL, password: String?) throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-verify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (root, manifest) = try unpack(zip, into: scratch)
        if manifest.parts.keys != nil {
            let file = scratch.appendingPathComponent(root).appendingPathComponent("keys.enc")
            // Read the way the import reads it: a regular file, under the size limit.
            let data = try BackupFiles.readRegularFile(at: file, maxBytes: BackupFiles.maxDocumentBytes)
            _ = try BackupKeysFile.decode(data, password: password ?? "", aad: manifest.keysAAD)
        }
    }
}
