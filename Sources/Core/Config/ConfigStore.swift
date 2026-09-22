import Foundation

extension Notification.Name {
    /// Posted after the config file changed ON DISK and was reloaded — i.e. the
    /// user edited it in a text editor. NOT posted for changes the app itself
    /// made, because whoever made those already knows.
    static let configReloadedFromDisk = Notification.Name("ConfigReloadedFromDisk")
}

/// The app's settings, as one file the user is meant to open and edit.
///
///     ~/.config/<slug>/config.json
///
/// `~/.config` rather than Application Support because the point is that this
/// file can be read, diffed, symlinked into a dotfiles repo and committed.
/// Application Support is hidden in Finder by default and is where apps put
/// things people are not supposed to touch; this is the opposite of that.
///
/// **Secrets never go in here.** API keys stay in the Keychain (`LLMKeyStore`)
/// precisely so this file is safe to commit.
///
/// The document is held as a `JSONValue` tree rather than a typed struct, so a
/// key this build does not recognise is preserved rather than deleted on the next
/// save — see `JSONValue` for why that matters.
///
/// **Main thread only, including the disk work.** An earlier version wrote on a
/// background queue and grew a race at every step: the bytes it had promised were
/// on disk were not there yet, a reload could read the old file and undo a change,
/// quitting could kill the process before the write ran, and two file watches were
/// mutated from two threads at once. The file is a few kilobytes and a write is
/// debounced to at most one every 0.4s, so doing it in line costs nothing
/// measurable and removes all of that.
final class ConfigStore: ObservableObject {

    static let shared = ConfigStore()

    private static let log = FileLog("Config")

    /// The whole file. Read through the typed accessors below.
    @Published private(set) var document: JSONValue = .object([:])

    /// The path as configured — which may be a symlink into a dotfiles repo.
    var fileURL: URL { Brand.configDirectory.appendingPathComponent("config.json") }

    /// Where the bytes actually live. Everything that touches the file resolves
    /// this FIRST, because an atomic write to a symlink REPLACES THE SYMLINK with
    /// a regular file: the dotfiles copy would keep the old contents and the two
    /// would silently drift apart. Re-resolved every time, since the link can be
    /// re-pointed while the app is running.
    private var resolvedFileURL: URL { fileURL.resolvingSymlinksInPath() }

    /// Exactly the bytes we last wrote or last successfully read. Content identity
    /// is the loop breaker: a file whose bytes are these is one we already know
    /// about, whoever wrote it.
    private var lastKnownBytes: Data?

    /// Cheap change detector, so the common case costs one `stat` and no read.
    private var lastStamp: FileStamp?

    private var saveWorkItem: DispatchWorkItem?
    private var pollTimer: Timer?

    /// How long to sit on a change before writing. Dragging a slider produces a
    /// change per frame; without this the file would be rewritten sixty times a
    /// second and an editor watching it would flicker.
    private static let saveDebounce: TimeInterval = 0.4

    /// How often to look for a hand edit.
    ///
    /// A poll, not a `DispatchSource`, and that is a deliberate downgrade. Watches
    /// look precise and are full of holes here: a directory source never sees an
    /// in-place write (which is what vim does when the file is a symlink), a file
    /// source is killed by an atomic replace and goes deaf afterwards, and when the
    /// config is a symlink into a dotfiles repo BOTH fire on the wrong directory —
    /// the real file's, not the one holding the link. Covering all of that needs
    /// two sources, re-resolving, re-opening on delete, and handling a file that
    /// does not exist yet. One `stat` a second is a few microseconds against the
    /// vnode cache, is immune to every one of those cases, and is well under the
    /// time it takes to switch from the editor back to what you were doing.
    private static let pollInterval: TimeInterval = 1.0

    private init() {
        load()
        writeSchema()
        startPolling()
    }

    // MARK: - Reading

    func bool(_ path: String, default fallback: Bool) -> Bool {
        document[path: path]?.boolValue ?? fallback
    }

    func double(_ path: String, default fallback: Double) -> Double {
        document[path: path]?.doubleValue ?? fallback
    }

    func string(_ path: String, default fallback: String) -> String {
        document[path: path]?.stringValue ?? fallback
    }

    /// Nil for both "absent" and "explicitly null", which is what the one setting
    /// that needs it means: `general.language: null` is "follow the system".
    func optionalString(_ path: String) -> String? {
        guard let value = document[path: path], !value.isNull else { return nil }
        return value.stringValue
    }

    func value(_ path: String) -> JSONValue? { document[path: path] }

    // MARK: - Writing

    func set(_ path: String, _ value: JSONValue) {
        guard document[path: path] != value else { return }   // no-op writes must not dirty the file
        document.set(path: path, to: value)
        scheduleSave()
    }

    func set(_ path: String, _ value: Bool)   { set(path, .bool(value)) }
    func set(_ path: String, _ value: Double) { set(path, .number(value)) }
    func set(_ path: String, _ value: String) { set(path, .string(value)) }

    /// Clears a setting back to "unset". Used for "follow the system", which is
    /// meaningfully different from any particular value.
    func setNull(_ path: String) { set(path, .null) }

    /// Write now rather than on the debounce. Called at termination, where there
    /// is no later — which is why the write is synchronous: an asynchronous one
    /// would still be sitting in a queue when the process goes away.
    func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        writeNow()
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.saveWorkItem = nil
            self?.writeNow()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDebounce, execute: item)
    }

    private func writeNow() {
        guard let data = encoded() else { return }
        guard data != lastKnownBytes else { return }          // nothing actually changed

        let url = resolvedFileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)

            // Somebody edited the file since we last read it and we are about to
            // overwrite them. Their version is kept, always — losing an edit
            // someone typed is not a thing to trade for tidiness.
            if let onDisk = try? Data(contentsOf: url), onDisk != lastKnownBytes {
                let backup = url.appendingPathExtension("bak-" + Self.timestamp())
                try? onDisk.write(to: backup, options: .atomic)
                Self.log.warn("the config changed underneath us — kept that version as \(backup.lastPathComponent) before writing")
            }

            // Atomic: a crash mid-write must not leave a truncated config, and an
            // editor watching the file must never see a partial document.
            try data.write(to: url, options: .atomic)
            // Only NOW is this true. Recording it before the write meant a failed
            // write left the app believing the file said something it did not, and
            // every later save was skipped as "unchanged".
            lastKnownBytes = data
            lastStamp = FileStamp(url)
        } catch {
            Self.log.error("could not write \(url.path): \(error)")
        }
    }

    private func encoded() -> Data? {
        let encoder = JSONEncoder()
        // Sorted keys so a save produces a MINIMAL git diff instead of reshuffling
        // the whole file; pretty-printed because a person reads it.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            var data = try encoder.encode(document)
            data.append(0x0A)   // POSIX trailing newline, so the last line diffs like any other
            return data
        } catch {
            Self.log.error("could not encode the config: \(error)")
            return nil
        }
    }

    // MARK: - Loading

    private func load() {
        let url = resolvedFileURL
        guard let data = try? Data(contentsOf: url) else {
            // No file yet: build one from the defaults plus whatever the app has
            // already stored in UserDefaults, so nothing is lost on the way over.
            document = ConfigSeed.initialDocument()
            Self.log.info("no config at \(url.path) — seeding a new one")
            writeNow()
            return
        }
        guard let decoded = decode(data) else {
            document = ConfigSeed.initialDocument()
            lastKnownBytes = nil
            return
        }
        document = decoded
        lastKnownBytes = data
        lastStamp = FileStamp(url)
        Self.log.info("loaded \(url.path)")
        retireDeadKeys()
    }

    /// Drop settings that no longer mean anything.
    ///
    /// Unknown keys are preserved on purpose, so this list has to be explicit: a
    /// key is removed only because the app KNOWS it retired it, never because it
    /// failed to recognise it. Leaving this one behind would be worse than
    /// deleting it — `"enabled": false` sitting in the file reads like a switch
    /// that is off, and there is no switch any more.
    private func retireDeadKeys() {
        if document.remove(path: "popup.enabled") {
            Self.log.info("removed popup.enabled — the popup no longer has an on/off setting")
            scheduleSave()
        }
    }

    /// Decode, or keep a copy of what could not be read and return nil.
    ///
    /// NEVER overwrite an unreadable file with defaults: it is the user's work,
    /// and the mistake in it is probably one comma.
    private func decode(_ data: Data) -> JSONValue? {
        guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              decoded.objectValue != nil else {
            let url = resolvedFileURL
            let backup = url.appendingPathExtension("bad-" + Self.timestamp())
            try? data.write(to: backup, options: .atomic)
            Self.log.error("\(url.lastPathComponent) is not valid JSON — kept a copy as \(backup.lastPathComponent), running from the last good settings")
            return nil
        }
        return decoded
    }

    // MARK: - Noticing a hand edit

    private func startPolling() {
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.checkForExternalChange()
        }
        // .common so the check keeps running while a menu is open or a window is
        // being dragged — which is exactly when a background editor's save lands.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        // A local, not `fileURL`: FileLog evaluates its message later, and a
        // property read inside that closure would need to capture self.
        let path = fileURL.path
        Self.log.info("watching \(path) for hand edits, every \(Int(Self.pollInterval))s")
    }

    private func checkForExternalChange() {
        // A change of our own is still on its way to disk. What is on disk is by
        // definition older than what the user just clicked, so reading it now
        // would undo their change. The pending write handles the other side of
        // this: it backs up whatever is on disk before overwriting it.
        guard saveWorkItem == nil else { return }

        let url = resolvedFileURL
        let stamp = FileStamp(url)
        guard stamp != lastStamp else { return }              // the cheap path, once a second
        lastStamp = stamp

        guard let data = try? Data(contentsOf: url) else { return }
        guard data != lastKnownBytes else { return }          // our own write, echoing back
        guard let decoded = decode(data) else { return }      // mid-edit and unparseable: keep what we have
        guard decoded != document else { lastKnownBytes = data; return }

        document = decoded
        lastKnownBytes = data
        Self.log.info("config.json changed on disk — reloaded")
        NotificationCenter.default.post(name: .configReloadedFromDisk, object: nil)
    }

    /// What `stat` says, reduced to the three things that change when a file is
    /// edited. Comparing these is what avoids reading the file every second.
    private struct FileStamp: Equatable {
        let modified: Date
        let size: Int
        let inode: UInt64

        init?(_ url: URL) {
            guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = a[.modificationDate] as? Date,
                  let size = a[.size] as? Int,
                  let inode = a[.systemFileNumber] as? UInt64 else { return nil }
            self.modified = modified
            self.size = size
            self.inode = inode
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    // MARK: - Schema

    /// Write the schema beside the config and point at it from the document.
    ///
    /// JSON has no comments, which is the one real cost of choosing it. A schema
    /// buys back more than comments would: an editor gives completion for every
    /// key, the allowed values of an enum, and the documentation on hover — and
    /// unlike comments it survives the app rewriting the file.
    ///
    /// Written beside the RESOLVED file, so a config symlinked into a dotfiles
    /// repo gets its schema in that repo too, and the relative `$schema` reference
    /// resolves from either path.
    private func writeSchema() {
        let url = resolvedFileURL.deletingLastPathComponent()
            .appendingPathComponent("config.schema.json")
        guard let data = ConfigSchema.json.data(using: .utf8) else { return }
        // Only when it differs, so an unchanged schema does not touch the mtime of
        // a file sitting in a git repo.
        if let existing = try? Data(contentsOf: url), existing == data { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.log.error("could not write the schema: \(error)")
        }
    }
}
