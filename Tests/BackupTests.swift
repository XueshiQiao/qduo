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
