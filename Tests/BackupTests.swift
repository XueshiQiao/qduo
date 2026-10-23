import XCTest
import SQLite3

/// Backup and restore (issue #22): the password envelope, which names a backup
/// zip may contain, the manifest, the zip round trip, and the history snapshot
/// and merge. The Keychain and the running app are not touched.
final class BackupCryptoTests: XCTestCase {

    private let aad = BackupManifest.keysAAD(format: 1, exportedAt: "2026-10-19T07:28:00Z")
    private let secret = Data(#"{"llm-key-deepseek":"sk-test"}"#.utf8)

    func testRoundTrip() throws {
        let envelope = try BackupCrypto.seal(secret, password: "hunter2", aad: aad)
        XCTAssertEqual(envelope.iterations, BackupCrypto.defaultIterations)
        XCTAssertEqual(Data(base64Encoded: envelope.salt)?.count, BackupCrypto.saltLength)
        XCTAssertEqual(try BackupCrypto.open(envelope, password: "hunter2", aad: aad), secret)
    }

    func testTheSecretIsNotInTheEnvelope() throws {
        let envelope = try BackupCrypto.seal(secret, password: "hunter2", aad: aad)
        let encoded = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
        XCTAssertFalse(encoded.contains("sk-test"))
    }

    func testWrongPasswordFails() throws {
        let envelope = try BackupCrypto.seal(secret, password: "hunter2", aad: aad)
        XCTAssertThrowsError(try BackupCrypto.open(envelope, password: "hunter3", aad: aad)) {
            XCTAssertEqual($0 as? BackupCrypto.Failure, .authentication)
        }
    }

    func testEmptyPasswordIsRefused() {
        XCTAssertThrowsError(try BackupCrypto.seal(secret, password: "", aad: aad)) {
            XCTAssertEqual($0 as? BackupCrypto.Failure, .passwordRequired)
        }
    }

    func testAFlippedCiphertextByteFails() throws {
        var envelope = try BackupCrypto.seal(secret, password: "hunter2", aad: aad)
        var box = Data(base64Encoded: envelope.box)!
        box[BackupCrypto.nonceLength] ^= 0x01
        envelope.box = box.base64EncodedString()
        XCTAssertThrowsError(try BackupCrypto.open(envelope, password: "hunter2", aad: aad))
    }

    /// keys.enc lifted into a backup with a different timestamp does not open.
    func testDifferentAADFails() throws {
        let envelope = try BackupCrypto.seal(secret, password: "hunter2", aad: aad)
        let other = BackupManifest.keysAAD(format: 1, exportedAt: "2026-10-20T07:28:00Z")
        XCTAssertThrowsError(try BackupCrypto.open(envelope, password: "hunter2", aad: other))
    }

    func testTooManyIterationsAreRefusedBeforeStretching() throws {
        var envelope = try BackupCrypto.seal(secret, password: "hunter2", aad: aad)
        envelope.iterations = BackupCrypto.maxIterations + 1
        XCTAssertThrowsError(try BackupCrypto.open(envelope, password: "hunter2", aad: aad)) {
            XCTAssertEqual($0 as? BackupCrypto.Failure, .badIterations)
        }
    }

    func testZeroOrNegativeIterationsAreRefused() throws {
        for n in [0, -1] {
            var envelope = try BackupCrypto.seal(secret, password: "hunter2", aad: aad)
            envelope.iterations = n
            XCTAssertThrowsError(try BackupCrypto.open(envelope, password: "hunter2", aad: aad)) {
                XCTAssertEqual($0 as? BackupCrypto.Failure, .badIterations)
            }
        }
    }

    func testBadSaltAndNonceAreRefused() throws {
        var envelope = try BackupCrypto.seal(secret, password: "hunter2", aad: aad)
        envelope.salt = Data(count: 8).base64EncodedString()
        XCTAssertThrowsError(try BackupCrypto.open(envelope, password: "hunter2", aad: aad)) {
            XCTAssertEqual($0 as? BackupCrypto.Failure, .badSalt)
        }
        envelope = try BackupCrypto.seal(secret, password: "hunter2", aad: aad)
        envelope.box = Data(count: 10).base64EncodedString()
        XCTAssertThrowsError(try BackupCrypto.open(envelope, password: "hunter2", aad: aad)) {
            XCTAssertEqual($0 as? BackupCrypto.Failure, .badNonce)
        }
    }
}

final class BackupEntryRulesTests: XCTestCase {

    func testRefusesNamesThatLeaveTheFolder() {
        for name in ["../a", "/a", "R/../x", "a\u{0}b", "R\\manifest.json", "R/icons/../x.png",
                     "R/icons/.hidden.png", "R/icons/a/b.png", "R/unknown.txt", "R//config.json",
                     "R/./config.json", "manifest.json", "R/icons/x.jpg", "R/icons/x.png/"] {
            XCTAssertFalse(BackupEntryRules.isAcceptable(entryName: name), name)
        }
    }

    func testAcceptsTheBackupShape() {
        for name in ["R/", "R", "R/manifest.json", "R/config.json", "R/keys.enc", "R/history.sqlite",
                     "R/icons/", "R/icons/icon-1a2b3c4d.png"] {
            XCTAssertTrue(BackupEntryRules.isAcceptable(entryName: name), name)
        }
    }

    func testOneRootOnly() {
        XCTAssertEqual(BackupEntryRules.rootDirectory(of: ["R/", "R/manifest.json"]), "R")
        XCTAssertNil(BackupEntryRules.rootDirectory(of: ["R/manifest.json", "S/config.json"]))
        XCTAssertNil(BackupEntryRules.rootDirectory(of: ["R/manifest.json", "R/../evil"]))
        XCTAssertNil(BackupEntryRules.rootDirectory(of: []))
    }
}

final class BackupManifestTests: XCTestCase {

    private func manifest(format: Int = BackupManifest.format) -> BackupManifest {
        var parts = BackupManifest.Parts()
        parts.config = .init(file: "config.json")
        parts.history = .init(file: "history.sqlite", records: 3)
        return BackupManifest(format: format, app: .init(version: "26.10.24", build: "1", bundleID: "x"),
                              exportedAt: "2026-10-19T07:28:00Z", parts: parts)
    }

    func testRoundTripLeavesAbsentPartsOut() throws {
        let data = try JSONEncoder().encode(manifest())
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("\"keys\""))
        XCTAssertFalse(json.contains("\"icons\""))
        XCTAssertEqual(try JSONDecoder().decode(BackupManifest.self, from: data), manifest())
    }

    func testAvailablePartsAndNewerFormat() {
        XCTAssertEqual(manifest().availableParts, [.config, .history])
        XCTAssertFalse(manifest().isNewerThanThisBuild)
        XCTAssertTrue(manifest(format: BackupManifest.format + 1).isNewerThanThisBuild)
    }
}

final class BackupArchiveTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("backup-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testZipListUnzipKeepsTheBytes() throws {
        let root = dir.appendingPathComponent("QDuo-backup-2026-10-19", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("icons"), withIntermediateDirectories: true)
        let manifest = Data(#"{"format":1}"#.utf8)
        let icon = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        try manifest.write(to: root.appendingPathComponent("manifest.json"))
        try icon.write(to: root.appendingPathComponent("icons/icon-1a2b3c4d.png"))

        let zip = dir.appendingPathComponent("out.zip")
        try BackupArchive.zip(directory: root, to: zip)
        let entries = try BackupArchive.listEntries(of: zip)
        XCTAssertEqual(BackupEntryRules.rootDirectory(of: entries), "QDuo-backup-2026-10-19")
        XCTAssertTrue(entries.contains("QDuo-backup-2026-10-19/manifest.json"))

        let out = dir.appendingPathComponent("out", isDirectory: true)
        try BackupArchive.unzip(zip, into: out)
        let unpacked = out.appendingPathComponent("QDuo-backup-2026-10-19")
        XCTAssertEqual(try Data(contentsOf: unpacked.appendingPathComponent("manifest.json")), manifest)
        XCTAssertEqual(try Data(contentsOf: unpacked.appendingPathComponent("icons/icon-1a2b3c4d.png")), icon)

        let disk = try BackupFiles.relativeEntries(under: out, maxBytes: BackupFiles.maxArchiveBytes)
        XCTAssertTrue(BackupFiles.isCovered(disk, by: entries))
    }

    /// A symlink in the unpacked tree refuses it, and is never read through.
    func testSymlinksAreRefused() throws {
        let root = dir.appendingPathComponent("R", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("manifest.json").path,
                                                   withDestinationPath: "/etc/hosts")
        XCTAssertThrowsError(try BackupFiles.relativeEntries(under: dir, maxBytes: 1 << 20))
        XCTAssertThrowsError(try BackupFiles.readRegularFile(at: root.appendingPathComponent("manifest.json"),
                                                             maxBytes: 1 << 20))
    }

    func testReadingStopsAtTheLimit() throws {
        let file = dir.appendingPathComponent("big")
        try Data(count: 2048).write(to: file)
        XCTAssertThrowsError(try BackupFiles.readRegularFile(at: file, maxBytes: 1024)) {
            XCTAssertEqual($0 as? BackupFiles.Failure, .tooLarge)
        }
        XCTAssertEqual(try BackupFiles.readRegularFile(at: file, maxBytes: 4096).count, 2048)
    }

    /// The size is read from the zip's own summary, before anything is unpacked.
    func testDeclaredSizeIsReadBeforeUnpacking() throws {
        let root = dir.appendingPathComponent("R", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(count: 50_000).write(to: root.appendingPathComponent("history.sqlite"))
        let zip = dir.appendingPathComponent("z.zip")
        try BackupArchive.zip(directory: root, to: zip)
        XCTAssertEqual(try BackupArchive.declaredUncompressedSize(of: zip), 50_000)
    }

    /// A name with a carriage return is not tidied into a clean one.
    func testListingDoesNotTidyNames() throws {
        XCTAssertFalse(BackupEntryRules.isAcceptable(entryName: "R/config.json\r"))
        XCTAssertFalse(BackupEntryRules.isAcceptable(entryName: "./R/config.json"))
    }

    func testFilesUnzipDidNotListAreCaught() {
        XCTAssertFalse(BackupFiles.isCovered(["R/", "R/manifest.json", "R/extra"], by: ["R/", "R/manifest.json"]))
        XCTAssertTrue(BackupFiles.isCovered(["R/", "R/icons/", "R/icons/a.png"], by: ["R/icons/a.png"]))
    }
}

/// Export then import of the API keys, through the same functions the app
/// calls: `BackupKeysFile.encode` and `BackupManifest.fileData` on the way out,
/// the zip, then the manifest decode and `BackupKeysFile.decode` on the way in.
final class BackupKeysRoundTripTests: XCTestCase {

    private var dir: URL!
    private let keys = ["llm-key-deepseek": "sk-deepseek-test", "llm-key-openai": "sk-openai-test",
                        "speech-key-elevenlabs": "el-test", "speech-key-qwen": "密钥-非ASCII-✓"]

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("backup-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Writes a backup zip holding only keys.enc, the way the export does, and
    /// returns the unpacked folder and its manifest, the way the import reads them.
    private func exportAndUnpack(password: String) throws -> (root: URL, manifest: BackupManifest) {
        let root = dir.appendingPathComponent("QDuo-backup-2026-10-23", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let exportedAt = BackupManifest.exportedAtString(Date())
        let sealed = try BackupKeysFile.encode(keys, password: password,
                                               aad: BackupManifest.keysAAD(format: BackupManifest.format,
                                                                           exportedAt: exportedAt))
        try sealed.write(to: root.appendingPathComponent("keys.enc"))
        var parts = BackupManifest.Parts()
        parts.keys = .init(file: "keys.enc", encrypted: true, count: keys.count)
        let manifest = BackupManifest(format: BackupManifest.format,
                                      app: .init(version: "26.10.25", build: "25", bundleID: "x"),
                                      exportedAt: exportedAt, parts: parts)
        try manifest.fileData().write(to: root.appendingPathComponent("manifest.json"))

        let zip = dir.appendingPathComponent("backup.zip")
        try BackupArchive.zip(directory: root, to: zip)
        let out = dir.appendingPathComponent("unpacked", isDirectory: true)
        try BackupArchive.unzip(zip, into: out)
        let unpacked = out.appendingPathComponent("QDuo-backup-2026-10-23", isDirectory: true)
        let read = try JSONDecoder().decode(BackupManifest.self,
                                            from: Data(contentsOf: unpacked.appendingPathComponent("manifest.json")))
        return (unpacked, read)
    }

    private func importKeys(from root: URL, manifest: BackupManifest, password: String) throws -> [String: String] {
        try BackupKeysFile.decode(Data(contentsOf: root.appendingPathComponent("keys.enc")),
                                  password: password, aad: manifest.keysAAD)
    }

    func testTheSamePasswordGivesBackTheSameKeys() throws {
        for password in ["hunter2", "correct horse battery staple", "密码-中文-🔑", " spaces around "] {
            let (root, manifest) = try exportAndUnpack(password: password)
            XCTAssertEqual(try importKeys(from: root, manifest: manifest, password: password), keys, password)
            try FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    func testAnotherPasswordIsWrongPassword() throws {
        let (root, manifest) = try exportAndUnpack(password: "hunter2")
        for other in ["hunter3", "Hunter2", "hunter2 ", ""] {
            XCTAssertThrowsError(try importKeys(from: root, manifest: manifest, password: other), other) {
                XCTAssertEqual($0 as? BackupKeysFile.Failure, .wrongPassword)
            }
        }
    }

    /// The manifest's timestamp is part of the check; it has to survive the
    /// write and the read unchanged, or every password would be "wrong".
    func testTheTimestampSurvivesTheManifestRoundTrip() throws {
        let (_, manifest) = try exportAndUnpack(password: "hunter2")
        XCTAssertEqual(manifest.keysAAD,
                       BackupManifest.keysAAD(format: BackupManifest.format, exportedAt: manifest.exportedAt))
        XCTAssertNotNil(ISO8601DateFormatter().date(from: manifest.exportedAt))
    }

    /// Precomposed and decomposed é are different bytes; each opens only with itself.
    func testUnicodeFormsAreNotTidied() throws {
        let composed = "caf\u{E9}", decomposed = "cafe\u{301}"
        let (root, manifest) = try exportAndUnpack(password: composed)
        XCTAssertEqual(try importKeys(from: root, manifest: manifest, password: composed), keys)
        XCTAssertThrowsError(try importKeys(from: root, manifest: manifest, password: decomposed))
    }

    func testAGarbledFileIsNotAWrongPassword() {
        XCTAssertThrowsError(try BackupKeysFile.decode(Data("{}".utf8), password: "x", aad: Data())) {
            XCTAssertEqual($0 as? BackupKeysFile.Failure, .unreadable)
        }
    }
}

/// The whole folder, export then import, through `BackupLayout` — the code the
/// app's export writes with and the app's import checks with — and the real zip.
final class BackupLayoutRoundTripTests: XCTestCase {

    private var dir: URL!
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])
    private let keys = ["llm-key-deepseek": "sk-test", "speech-key-elevenlabs": "el-test"]
    private let app = BackupManifest.AppInfo(version: "26.10.25", build: "25", bundleID: "me.xueshi.qduo")

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("backup-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Export: writes the folder and zips it. Returns the zip.
    private func export(config: Data? = nil, icons: [(name: String, data: Data)]? = nil,
                        keys: (items: [String: String], password: String)? = nil,
                        history: Data? = nil) throws -> URL {
        let work = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = work.appendingPathComponent("QDuo-backup-2026-10-23", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let history { try history.write(to: root.appendingPathComponent("history.sqlite")) }
        _ = try BackupLayout.write(into: root, exportedAt: BackupManifest.exportedAtString(Date()), app: app,
                                   config: config, icons: icons, keys: keys,
                                   historyRecords: history == nil ? nil : 7)
        let zip = work.appendingPathComponent("backup.zip")
        try BackupArchive.zip(directory: root, to: zip)
        return zip
    }

    /// Import: unpacks and checks the zip the way the import sheet does.
    private func unpack(_ zip: URL) throws -> (folder: URL, manifest: BackupManifest) {
        let scratch = dir.appendingPathComponent("in-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let (root, manifest) = try BackupLayout.unpack(zip, into: scratch)
        return (scratch.appendingPathComponent(root, isDirectory: true), manifest)
    }

    func testEverythingComesBack() throws {
        let config = Data(#"{"actions":[]}"#.utf8)
        let zip = try export(config: config, icons: [("icon-1a2b3c4d.png", png)],
                             keys: (keys, "hunter2"), history: Data("sqlite".utf8))
        let (folder, manifest) = try unpack(zip)
        XCTAssertEqual(manifest.availableParts, [.config, .icons, .keys, .history])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("config.json")), config)
        XCTAssertEqual(try BackupLayout.icons(in: folder).map(\.name), ["icon-1a2b3c4d.png"])
        XCTAssertEqual(try BackupLayout.icons(in: folder).map(\.data), [png])
        XCTAssertEqual(try BackupKeysFile.decode(Data(contentsOf: folder.appendingPathComponent("keys.enc")),
                                                 password: "hunter2", aad: manifest.keysAAD), keys)
        XCTAssertEqual(manifest.parts.history?.records, 7)
        XCTAssertNoThrow(try BackupLayout.verify(zip, password: "hunter2"))
    }

    /// Icons ticked but there are none: the zip keeps no empty folder, and the
    /// import used to call that "not a backup".
    func testNoIconPicturesStillImports() throws {
        let zip = try export(config: Data("{}".utf8), icons: [], keys: (keys, "hunter2"))
        let (folder, manifest) = try unpack(zip)
        XCTAssertEqual(manifest.parts.icons?.count, 0)
        XCTAssertEqual(try BackupLayout.icons(in: folder).count, 0)
        XCTAssertNoThrow(try BackupLayout.verify(zip, password: "hunter2"))
    }

    /// Every combination of parts the export sheet allows imports again.
    func testEveryChoiceOfPartsImports() throws {
        for mask in 1..<16 {
            let zip = try export(config: mask & 1 != 0 ? Data("{}".utf8) : nil,
                                 icons: mask & 2 != 0 ? [] : nil,
                                 keys: mask & 4 != 0 ? (keys, "pw") : nil,
                                 history: mask & 8 != 0 ? Data("db".utf8) : nil)
            XCTAssertNoThrow(try BackupLayout.verify(zip, password: "pw"), "parts \(mask)")
        }
    }

    func testVerifyCatchesAnotherPassword() throws {
        let zip = try export(keys: (keys, "hunter2"))
        XCTAssertThrowsError(try BackupLayout.verify(zip, password: "hunter3")) {
            XCTAssertEqual($0 as? BackupKeysFile.Failure, .wrongPassword)
        }
    }

    /// A manifest that names pictures with no icons folder is still refused.
    func testMissingIconsFolderWithPicturesIsRefused() throws {
        let root = dir.appendingPathComponent("QDuo-backup-2026-10-23", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var parts = BackupManifest.Parts()
        parts.icons = .init(dir: "icons", count: 2)
        try BackupManifest(format: BackupManifest.format, app: app, exportedAt: "2026-10-23T14:09:16Z", parts: parts)
            .fileData().write(to: root.appendingPathComponent("manifest.json"))
        let zip = dir.appendingPathComponent("bad.zip")
        try BackupArchive.zip(directory: root, to: zip)
        XCTAssertThrowsError(try unpack(zip)) {
            XCTAssertEqual($0 as? BackupLayout.Failure, .notABackup)
        }
    }
}
