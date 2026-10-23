import Foundation

/// `keys.enc`: the API keys as one JSON object, sealed with the backup's
/// password. The export writes it with `encode` and the import reads it with
/// `decode`, so both sides run the same code, and the tests run it too.
enum BackupKeysFile {

    enum Failure: Error, Equatable {
        /// The password does not open the file, or the file was changed.
        case wrongPassword
        /// Not a keys file this build can read.
        case unreadable
    }

    /// `items` maps a keychain account to its secret.
    static func encode(_ items: [String: String], password: String, aad: Data) throws -> Data {
        let plaintext = try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
        let envelope = try BackupCrypto.seal(plaintext, password: password, aad: aad)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var encoded = try encoder.encode(envelope)
        encoded.append(0x0A)
        return encoded
    }

    static func decode(_ data: Data, password: String, aad: Data) throws -> [String: String] {
        let envelope: BackupCrypto.Envelope
        do {
            envelope = try JSONDecoder().decode(BackupCrypto.Envelope.self, from: data)
        } catch {
            throw Failure.unreadable
        }
        let plaintext: Data
        do {
            plaintext = try BackupCrypto.open(envelope, password: password, aad: aad)
        } catch BackupCrypto.Failure.authentication, BackupCrypto.Failure.passwordRequired {
            throw Failure.wrongPassword
        } catch {
            throw Failure.unreadable
        }
        guard let object = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            throw Failure.unreadable
        }
        var items: [String: String] = [:]
        for (account, value) in object {
            guard let value = value as? String, !account.isEmpty, !account.contains("\u{0}") else {
                throw Failure.unreadable
            }
            items[account] = value
        }
        return items
    }
}
