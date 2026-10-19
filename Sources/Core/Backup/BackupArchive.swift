import Foundation

/// Packs a backup folder into a zip, lists what a zip claims to contain, and
/// unpacks one. Listing goes through `/usr/bin/unzip -Z1` and unpacking through
/// `/usr/bin/ditto -x -k`, the same way `ProcessRunner` runs a tool: a real
/// process, both pipes drained while it runs, so a chatty stderr cannot fill
/// its buffer and stall the child.
enum BackupArchive {

    enum Failure: Error {
        case command(String)
    }

    /// Zip `directory` by asking the file coordinator for the upload archive it
    /// builds, then copy that archive to `destination`. The coordinator's file
    /// disappears when the block returns, so the copy happens inside the block.
    static func zip(directory: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: [.forUploading], error: &coordinationError) { zipURL in
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: zipURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }

    /// Every name stored in the zip, one per line as `unzip -Z1` prints them.
    /// Split on `\n` only, and nothing is tidied: a name carrying a `\r`, a
    /// line separator or a leading `./` stays as it is, so `BackupEntryRules`
    /// sees it and refuses the file, rather than it becoming two names that
    /// each look fine.
    static func listEntries(of zip: URL) throws -> [String] {
        let output = try run("/usr/bin/unzip", ["-Z1", "--", zip.path])
        // By scalar: as Characters, "\r\n" is one character and would not split at "\n".
        return output.unicodeScalars.split(separator: "\n").map { String(String.UnicodeScalarView($0)) }
    }

    /// The total size the zip says its files have once unpacked, from the
    /// summary line of `unzip -Zt` ("7 files, 5492 bytes uncompressed, 285 bytes
    /// compressed: 94.8%"). Checked before anything is unpacked, so a small zip
    /// that expands to fill the disk is refused before it is written out. The
    /// sizes on disk are checked again after unpacking, in case the zip lied.
    static func declaredUncompressedSize(of zip: URL) throws -> Int64 {
        let summary = try run("/usr/bin/unzip", ["-Zt", "--", zip.path])
        guard let range = summary.range(of: #"(\d+) bytes uncompressed"#, options: .regularExpression),
              let number = Int64(summary[range].split(separator: " ").first ?? "") else {
            throw Failure.command("unexpected unzip -Zt output")
        }
        return number
    }

    /// Extract `zip` into `directory`. The directory is created if it is missing;
    /// the caller hands over an empty one.
    static func unzip(_ zip: URL, into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", "--", zip.path, directory.path])
    }

    // MARK: - Process

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let outBox = PipeBox(), errBox = PipeBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outBox.set(out.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errBox.set(err.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        process.waitUntilExit()
        group.wait()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errBox.get(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = URL(fileURLWithPath: executable).lastPathComponent
            throw Failure.command(message.isEmpty ? "\(name) exited \(process.terminationStatus)" : message)
        }
        var text = String(decoding: outBox.get(), as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        if text.hasSuffix("\r") { text.removeLast() }
        return text
    }
}

/// Reads a file only when it is a regular file, and never by following a
/// symlink. `FileManager.attributesOfItem` follows links, so a symlink named
/// `manifest.json` would look like the manifest; `lstat` sees the link itself
/// and `open(O_NOFOLLOW)` refuses to open it.
enum BackupFiles {

    /// 1 GB. A backup larger than this, or that unpacks to more than this, is
    /// refused before its bytes are pulled into memory.
    static let maxArchiveBytes: Int64 = 1024 * 1024 * 1024
    /// 1 MB. An icon picture larger than this is not imported.
    static let maxIconBytes = 1024 * 1024
    /// A config, a manifest or a keys file. Far above anything this app writes.
    static let maxDocumentBytes = 32 * 1024 * 1024

    enum Failure: Error {
        case notRegular
        case tooLarge
        case unreadable
    }

    static func isRegularFile(_ url: URL) -> Bool {
        fileType(url) == S_IFREG
    }

    /// A real directory, not a symlink to one.
    static func isDirectory(_ url: URL) -> Bool {
        fileType(url) == S_IFDIR
    }

    static func readRegularFile(at url: URL, maxBytes: Int) throws -> Data {
        guard fileType(url) == S_IFREG else { throw Failure.notRegular }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.notRegular }
        defer { Darwin.close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { throw Failure.unreadable }
            if count > maxBytes || data.count > maxBytes - count { throw Failure.tooLarge }
            data.append(buffer, count: count)
        }
        return data
    }

    /// Every file and directory under `root`, as `R/manifest.json` and `R/icons/`.
    /// A symlink, or anything that is neither a file nor a directory, refuses
    /// the tree. The total of the file sizes is checked against `maxBytes`.
    static func relativeEntries(under root: URL, maxBytes: Int64) throws -> [String] {
        var entries: [String] = []
        var total: Int64 = 0
        try walk(root, prefix: "", entries: &entries, total: &total, maxBytes: maxBytes)
        return entries
    }

    /// True when every file on disk was named by `listed`, and every directory
    /// on disk is a prefix of something that was listed. `ditto` must not have
    /// invented a file `unzip -Z1` did not mention.
    static func isCovered(_ diskEntries: [String], by listed: [String]) -> Bool {
        let listedKeys = Set(listed.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
        for entry in diskEntries {
            let directory = entry.hasSuffix("/")
            let key = directory ? String(entry.dropLast()) : entry
            if directory {
                let ok = listedKeys.contains(key) || listedKeys.contains { $0.hasPrefix(key + "/") }
                if !ok { return false }
            } else if !listedKeys.contains(key) {
                return false
            }
        }
        return true
    }

    // MARK: - Internals

    private static func fileType(_ url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return mode_t(info.st_mode) & S_IFMT
    }

    private static func walk(_ directory: URL, prefix: String, entries: inout [String],
                             total: inout Int64, maxBytes: Int64) throws {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw Failure.unreadable
        }
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard let type = fileType(url) else { throw Failure.unreadable }
            let relative = prefix.isEmpty ? name : prefix + "/" + name
            if type == S_IFLNK { throw Failure.notRegular }
            if type == S_IFDIR {
                entries.append(relative + "/")
                try walk(url, prefix: relative, entries: &entries, total: &total, maxBytes: maxBytes)
            } else if type == S_IFREG {
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw Failure.unreadable }
                let size = Int64(info.st_size)
                if size < 0 || size > maxBytes || total > maxBytes - size { throw Failure.tooLarge }
                total += size
                entries.append(relative)
            } else {
                throw Failure.notRegular
            }
        }
    }
}

/// Hands bytes from a reader thread to the thread that waited for the process.
private final class PipeBox {
    private let lock = NSLock()
    private var data = Data()
    func set(_ data: Data) { lock.lock(); self.data = data; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
