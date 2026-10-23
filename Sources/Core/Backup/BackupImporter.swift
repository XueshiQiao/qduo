import AppKit
import Foundation

/// Reads a backup zip and, once the person has confirmed which parts to take,
/// puts them in place.
///
/// History is merged into the file Debug and Release already share; nothing
/// already there is deleted, and history on its own does not need a restart.
/// Settings, icons and API keys do: the running process still has the old
/// settings in memory, and `prepareForRestore` stops that memory from being
/// written back over the imported file when the app quits.
enum BackupImporter {

    enum Failure: Error {
        case tooLarge
        case notABackup
        case newerFormat
        case wrongPassword
        case siblingRunning(String)
        case historyFailed
        /// Something was already written (icons, keys or the settings) when a
        /// later step failed. The running app no longer matches the disk and
        /// the keychain, and the config writes are still off: only a restart
        /// puts it right.
        case partiallyRestored
        case failed(String)
    }

    struct ApplyResult {
        var applied: Set<BackupManifest.Part>
        /// Settings, icons or keys were written. The app has to start again
        /// before it reads them.
        var needsRelaunch: Bool
    }

    private static let log = FileLog("Backup")

    /// Other builds of this app (a Release build while this one is Debug, or
    /// the other way around). They share the config file and the keychain, so
    /// importing under them would have them write their own copy back on quit.
    static func siblingBuildsRunning() -> [NSRunningApplication] {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter { app in
            guard app.processIdentifier != own, let id = app.bundleIdentifier else { return false }
            return id == Brand.baseID || id.hasPrefix(Brand.baseID + ".")
        }
    }

    static func inspect(_ zip: URL) async throws -> BackupInspection {
        let accessing = zip.startAccessingSecurityScopedResource()
        do {
            let inspection = try await Task.detached(priority: .userInitiated) {
                try inspectSync(zip, accessing: accessing)
            }.value
            return inspection
        } catch {
            if accessing { zip.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    static func apply(_ inspection: BackupInspection, parts: Set<BackupManifest.Part>,
                      password: String?) async throws -> ApplyResult {
        let chosen = parts.intersection(inspection.manifest.availableParts)
        guard !chosen.isEmpty else { throw Failure.notABackup }

        // The password is checked before anything is written. A wrong one leaves
        // the sheet up and the files on disk untouched.
        var decrypted: [String: String]?
        if chosen.contains(.keys) {
            let keysURL = inspection.rootURL.appendingPathComponent("keys.enc")
            let aad = inspection.manifest.keysAAD
            let typed = password ?? ""
            do {
                decrypted = try await Task.detached(priority: .userInitiated) {
                    try decryptKeys(at: keysURL, password: typed, aad: aad)
                }.value
            } catch Failure.wrongPassword {
                log.info("backup keys did not open")
                throw Failure.wrongPassword
            }
        }

        // Everything that will be written is read and checked BEFORE anything is
        // written. A broken config.json found after the icons and keys were
        // already in place would leave half a restore behind.
        let root = inspection.rootURL
        let configData: Data? = chosen.contains(.config)
            ? try await Task.detached(priority: .userInitiated) { try readImportedConfig(in: root) }.value
            : nil
        let icons: [(name: String, data: Data)] = chosen.contains(.icons)
            ? try await Task.detached(priority: .userInitiated) { try readImportedIcons(in: root) }.value
            : []

        let structural = chosen.intersection([.config, .icons, .keys])
        if !structural.isEmpty {
            let sibling = await MainActor.run { siblingBuildsRunning().first }
            if let sibling {
                throw Failure.siblingRunning(sibling.localizedName ?? Brand.name)
            }
            await MainActor.run { ConfigStore.shared.prepareForRestore() }
        }

        // History first: it merges through the store's own lock, needs no
        // restart, and a failure here has changed nothing else yet.
        if chosen.contains(.history) {
            let file = root.appendingPathComponent("history.sqlite")
            if case .failure = await HistoryStore.shared.merge(from: file) {
                if !structural.isEmpty { await MainActor.run { ConfigStore.shared.resumeWrites() } }
                throw Failure.historyFailed
            }
        }

        var wroteSomething = false
        do {
            if !icons.isEmpty {
                wroteSomething = true
                try await Task.detached(priority: .userInitiated) { try writeIcons(icons) }.value
            }
            if chosen.contains(.keys), let decrypted {
                let items = decrypted
                wroteSomething = true
                try await Task.detached(priority: .userInitiated) { try writeKeys(items) }.value
            }
            if let configData {
                wroteSomething = true
                try await MainActor.run { try ConfigStore.shared.replaceWithImported(configData) }
            }
        } catch {
            // Nothing landed: the document in memory still matches the disk, so
            // saving may resume. Once anything landed, the app has to restart.
            if !wroteSomething {
                await MainActor.run { ConfigStore.shared.resumeWrites() }
                throw error
            }
            log.error("restore stopped part way: \(error)")
            throw Failure.partiallyRestored
        }

        log.info("restored \(chosen.map(\.rawValue).sorted().joined(separator: ", "))")
        return ApplyResult(applied: chosen, needsRelaunch: !structural.isEmpty)
    }

    // MARK: - Inspect

    private static func inspectSync(_ zip: URL, accessing: Bool) throws -> BackupInspection {
        let attributes = try FileManager.default.attributesOfItem(atPath: zip.path)
        let type = attributes[.type] as? FileAttributeType
        guard type == .typeRegular else { throw Failure.notABackup }
        let zipSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard zipSize <= BackupFiles.maxArchiveBytes else { throw Failure.tooLarge }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Brand.slug)-import-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let (root, manifest) = try BackupLayout.unpack(zip, into: scratch)
            let titles = localKeyTitles()
            return BackupInspection(zipURL: zip, accessing: accessing, scratch: scratch,
                                    root: root, manifest: manifest, localKeyTitles: titles)
        } catch BackupLayout.Failure.tooLarge {
            try? FileManager.default.removeItem(at: scratch)
            throw Failure.tooLarge
        } catch BackupLayout.Failure.newerFormat {
            try? FileManager.default.removeItem(at: scratch)
            throw Failure.newerFormat
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw Failure.notABackup
        }
    }

    private static func localKeyTitles() -> [String] {
        guard let items = try? KeychainStore(service: Brand.keychainService).allItems() else { return [] }
        return items.keys.sorted().map(BackupKeyTitles.title(for:))
    }

    // MARK: - Apply

    private static func decryptKeys(at url: URL, password: String, aad: Data) throws -> [String: String] {
        let data: Data
        do {
            data = try BackupFiles.readRegularFile(at: url, maxBytes: BackupFiles.maxDocumentBytes)
        } catch {
            throw Failure.notABackup
        }
        do {
            return try BackupKeysFile.decode(data, password: password, aad: aad)
        } catch BackupKeysFile.Failure.wrongPassword {
            throw Failure.wrongPassword
        } catch {
            throw Failure.notABackup
        }
    }

    /// The backup's config, read and decoded before anything is written. It has
    /// to be a JSON object, as `ConfigStore` requires of any config it loads.
    private static func readImportedConfig(in root: URL) throws -> Data {
        let data: Data
        do {
            data = try BackupFiles.readRegularFile(at: root.appendingPathComponent("config.json"),
                                                   maxBytes: BackupFiles.maxDocumentBytes)
        } catch BackupFiles.Failure.tooLarge {
            throw Failure.tooLarge
        } catch {
            throw Failure.notABackup
        }
        guard let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any] else {
            throw Failure.notABackup
        }
        return data
    }

    /// Each regular PNG of at most 1 MB in the backup's icons folder, read into
    /// memory before anything is written. Anything else in the folder is
    /// skipped, as it was skipped on the way out.
    private static func readImportedIcons(in root: URL) throws -> [(name: String, data: Data)] {
        do {
            return try BackupLayout.icons(in: root)
        } catch {
            throw Failure.notABackup
        }
    }

    /// Write the pictures into the icons folder, resolving a symlink so the
    /// link itself is not replaced. A picture of the same name is replaced.
    private static func writeIcons(_ icons: [(name: String, data: Data)]) throws {
        let destination = ActionIconStore.directory.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for (name, data) in icons {
            try data.write(to: destination.appendingPathComponent(name), options: .atomic)
        }
    }

    /// Merge. A key this Mac already has is replaced; a key the file does not
    /// mention is left where it is. The accessibility is the one `KeychainStore.set`
    /// already uses.
    private static func writeKeys(_ items: [String: String]) throws {
        let store = KeychainStore(service: Brand.keychainService)
        for account in items.keys.sorted() {
            guard let value = items[account] else { continue }
            do {
                try store.set(value, account: account)
            } catch {
                log.error("could not write keychain account \(account): \(error)")
                throw Failure.failed("")
            }
        }
    }
}

/// The unpacked backup the sheet is showing. Cleaning it up deletes the temp
/// directory; that is safe to call more than once, and it also runs if the
/// sheet is released without an explicit cleanup.
final class BackupInspection {
    let manifest: BackupManifest
    let root: String
    let localKeyTitles: [String]
    let scratch: URL
    private let zipURL: URL
    private let accessing: Bool
    private let lock = NSLock()
    private var cleaned = false

    fileprivate init(zipURL: URL, accessing: Bool, scratch: URL, root: String,
                     manifest: BackupManifest, localKeyTitles: [String]) {
        self.zipURL = zipURL
        self.accessing = accessing
        self.scratch = scratch
        self.root = root
        self.manifest = manifest
        self.localKeyTitles = localKeyTitles
    }

    var rootURL: URL { scratch.appendingPathComponent(root, isDirectory: true) }

    func cleanup() {
        lock.lock()
        let should = !cleaned
        cleaned = true
        lock.unlock()
        guard should else { return }
        try? FileManager.default.removeItem(at: scratch)
        if accessing { zipURL.stopAccessingSecurityScopedResource() }
    }

    deinit { cleanup() }
}

/// A keychain account (`llm-key-deepseek`, `tts-key-minimax`) shown as the
/// provider's name. The sheet lists these so the person can see which keys
/// already on this Mac a restore would replace.
enum BackupKeyTitles {
    static func title(for account: String) -> String {
        let llm = "llm-key-"
        let tts = "tts-key-"
        if account.hasPrefix(llm) {
            return LLMConfig.displayName(String(account.dropFirst(llm.count)))
        }
        if account.hasPrefix(tts) {
            let id = String(account.dropFirst(tts.count))
            return SpeechProviders.find(id)?.displayName ?? id
        }
        return account
    }
}
