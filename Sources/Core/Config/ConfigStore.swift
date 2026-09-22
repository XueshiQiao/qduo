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
/// precisely so this file is safe to commit to a public repo.
///
/// The document is held as a `JSONValue` tree rather than a typed struct, so a
/// key this build does not recognise is preserved rather than deleted on the next
/// save — see `JSONValue` for why that matters.
///
/// Main-thread only, like the rest of the UI layer. Disk work happens on a
/// private queue; the tree itself is only ever touched on main.
final class ConfigStore: ObservableObject {

    static let shared = ConfigStore()

    private static let log = FileLog("Config")

    /// The whole file. Read through the typed accessors below.
    @Published private(set) var document: JSONValue = .object([:])

    var fileURL: URL { Brand.configDirectory.appendingPathComponent("config.json") }
    private var schemaURL: URL { Brand.configDirectory.appendingPathComponent("config.schema.json") }

    /// Exactly the bytes we last wrote or read. A filesystem event whose contents
    /// match this is our OWN write coming back, and reloading on it would start a
    /// write → notify → reload → write loop.
    private var lastKnownBytes: Data?

    private var saveWorkItem: DispatchWorkItem?
    private var reloadWorkItem: DispatchWorkItem?
    /// Watches the folder: catches the file being created, replaced or removed.
    private var directorySource: DispatchSourceFileSystemObject?
    /// Watches the file itself: catches an in-place write. Re-armed whenever the
    /// file is replaced, because the descriptor then points at the old inode.
    private var fileSource: DispatchSourceFileSystemObject?
    private let io = DispatchQueue(label: "\(Brand.baseID).config", qos: .userInitiated)

    /// How long to sit on a change before writing. Dragging a slider produces a
    /// change per frame; without this the file would be rewritten sixty times a
    /// second and a file-watching editor would flicker.
    private static let saveDebounce: TimeInterval = 0.4
    /// An editor's save is often several syscalls. Waiting a moment means we read
    /// the finished file rather than a half-written one.
    private static let reloadDebounce: TimeInterval = 0.2

    private init() {
        load()
        writeSchema()
        startWatching()
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
    /// may be no later.
    func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        writeNow()
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.writeNow() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDebounce, execute: item)
    }

    private func writeNow() {
        guard let data = encoded() else { return }
        guard data != lastKnownBytes else { return }          // nothing actually changed
        lastKnownBytes = data
        let url = fileURL
        io.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                // Atomic: a crash mid-write must not leave a truncated config, and
                // an editor watching the file must never see a partial document.
                try data.write(to: url, options: .atomic)
            } catch {
                Self.log.error("could not write \(url.path): \(error)")
            }
        }
    }

    private func encoded() -> Data? {
        let encoder = JSONEncoder()
        // Sorted keys so a save produces a MINIMAL git diff instead of reshuffling
        // the whole file; pretty-printed because a person reads it.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(document)
        } catch {
            Self.log.error("could not encode the config: \(error)")
            return nil
        }
    }

    // MARK: - Loading

    private func load() {
        let url = fileURL
        guard let data = try? Data(contentsOf: url) else {
            // No file yet: build one from the defaults plus whatever the app has
            // already stored in UserDefaults, so nothing is lost on the way over.
            document = ConfigSeed.initialDocument()
            Self.log.info("no config at \(url.path) — seeding a new one")
            writeNow()
            return
        }
        guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              decoded.objectValue != nil else {
            // NEVER overwrite an unreadable file with defaults: it is the user's
            // work, and the mistake in it is probably one typo. Keep a copy, say so
            // loudly, and run from defaults until it is fixed.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = url.appendingPathExtension("bad-\(stamp)")
            try? data.write(to: backup, options: .atomic)
            Self.log.error("\(url.path) is not valid JSON — kept a copy at \(backup.lastPathComponent), running from defaults")
            document = ConfigSeed.initialDocument()
            lastKnownBytes = nil
            return
        }
        document = decoded
        lastKnownBytes = data
        Self.log.info("loaded \(url.path)")
    }

    /// Re-read after an external edit, then tell the app so live surfaces catch up.
    private func reloadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard data != lastKnownBytes else { return }          // our own write echoing back
        guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              decoded.objectValue != nil else {
            // A half-typed file is the normal state of a file being edited. Say it
            // once and keep the last good document — do not clobber, do not crash.
            Self.log.warn("config.json does not parse right now — keeping the last good one")
            return
        }
        guard decoded != document else { lastKnownBytes = data; return }
        document = decoded
        lastKnownBytes = data
        Self.log.info("config.json changed on disk — reloaded")
        NotificationCenter.default.post(name: .configReloadedFromDisk, object: nil)
    }

    // MARK: - Watching

    /// Noticing a hand edit takes TWO watches, because there are two different
    /// ways a file gets saved and each is invisible to the other's watch:
    ///
    ///  - Writing in place (`>`, `json.dump`, many editors) changes the file's
    ///    contents. The DIRECTORY sees nothing — a directory event means an entry
    ///    was added, removed or renamed, not that one of them was written to.
    ///  - Saving atomically (write a temp file, rename it over the target — what
    ///    this app does, and what a careful editor does) replaces the inode. The
    ///    old file descriptor keeps pointing at the file that was replaced, so a
    ///    watch on it goes deaf from that moment on.
    ///
    /// So: watch the directory to learn that the file was replaced, and re-arm the
    /// file watch onto the new inode when it is; watch the file to catch the
    /// in-place writes the directory never reports.
    private func startWatching() {
        let dir = Brand.configDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        directorySource = makeSource(path: dir.path,
                                     mask: [.write, .rename, .delete]) { [weak self] in
            // The file may have just been replaced, so the old descriptor is stale.
            self?.rearmFileWatch()
            self?.scheduleReload()
        }
        if directorySource == nil {
            Self.log.warn("could not watch \(dir.path) — hand edits will need a relaunch")
        }
        rearmFileWatch()
    }

    /// Point the file watch at whatever `config.json` is right now. Safe to call
    /// when there is no file yet: the directory watch will call it again once one
    /// appears.
    private func rearmFileWatch() {
        fileSource?.cancel()
        fileSource = nil
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        fileSource = makeSource(path: fileURL.path,
                                mask: [.write, .extend, .rename, .delete]) { [weak self] in
            self?.scheduleReload()
        }
    }

    private func makeSource(path: String,
                            mask: DispatchSource.FileSystemEvent,
                            handler: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: mask, queue: io)
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    /// Both watches can fire for one save, and an editor's save is often several
    /// syscalls, so coalesce: one reload a beat after things stop moving, reading
    /// a finished file rather than a half-written one.
    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async { self?.reloadFromDisk() }
        }
        reloadWorkItem = item
        io.asyncAfter(deadline: .now() + Self.reloadDebounce, execute: item)
    }

    // MARK: - Schema

    /// Write the schema beside the config and point at it from the document.
    ///
    /// JSON has no comments, which is the one real cost of choosing it. A schema
    /// buys back more than comments would: an editor gives completion for every
    /// key, the allowed values of an enum, and the documentation on hover — and
    /// unlike comments it survives the app rewriting the file.
    private func writeSchema() {
        let url = schemaURL
        io.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try ConfigSchema.json.data(using: .utf8)?.write(to: url, options: .atomic)
            } catch {
                Self.log.error("could not write the schema: \(error)")
            }
        }
    }
}
