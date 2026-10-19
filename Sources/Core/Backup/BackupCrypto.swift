import CommonCrypto
import CryptoKit
import Foundation

/// Seals the API keys for a backup. Only the keys are encrypted; the config,
/// the icons and the history sit in the zip as ordinary files.
///
/// The password is stretched with PBKDF2-HMAC-SHA256 (600,000 rounds, a fresh
/// 16-byte salt, a 32-byte key). The rounds are stored in the file so a future
/// build can raise them. On the way back in, a file that asks for more than
/// 5,000,000 rounds is refused: import must not be able to pin the machine for
/// minutes just by naming a huge number. The ciphertext is AES-256-GCM. The
/// manifest's format and timestamp are the extra authenticated data, so a
/// `keys.enc` lifted into another backup does not open.
enum BackupCrypto {

    static let saltLength = 16
    static let keyLength = 32
    static let nonceLength = 12
    static let tagLength = 16
    static let defaultIterations = 600_000
    static let maxIterations = 5_000_000

    private static let kdfName = "pbkdf2-hmac-sha256"
    private static let cipherName = "aes-256-gcm"

    struct Envelope: Codable, Equatable {
        var kdf: String
        var iterations: Int
        /// 16 bytes, base64.
        var salt: String
        var cipher: String
        /// `nonce || ciphertext || tag`, base64. The nonce is 12 bytes.
        var box: String
    }

    enum Failure: Error {
        case passwordRequired
        case badIterations
        case badSalt
        case badNonce
        case badEnvelope
        case derivationFailed
        case authentication
    }

    static func seal(_ plaintext: Data, password: String, aad: Data) throws -> Envelope {
        let salt = randomSalt()
        let key = try deriveKey(password: password, salt: salt, iterations: defaultIterations)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        guard let combined = sealed.combined else { throw Failure.authentication }
        return Envelope(kdf: kdfName, iterations: defaultIterations,
                        salt: salt.base64EncodedString(), cipher: cipherName,
                        box: combined.base64EncodedString())
    }

    static func open(_ envelope: Envelope, password: String, aad: Data) throws -> Data {
        guard envelope.kdf == kdfName, envelope.cipher == cipherName else { throw Failure.badEnvelope }
        guard (1...maxIterations).contains(envelope.iterations) else { throw Failure.badIterations }
        guard let salt = Data(base64Encoded: envelope.salt), salt.count == saltLength else { throw Failure.badSalt }
        guard let combined = Data(base64Encoded: envelope.box) else { throw Failure.badNonce }
        let box = try sealedBox(from: combined)
        let key = try deriveKey(password: password, salt: salt, iterations: envelope.iterations)
        do {
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw Failure.authentication
        }
    }

    /// PBKDF2-HMAC-SHA256. `iterations` above `maxIterations`, or a salt that is
    /// not 16 bytes, is rejected before any stretching happens.
    static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        guard !password.isEmpty else { throw Failure.passwordRequired }
        guard (1...maxIterations).contains(iterations) else { throw Failure.badIterations }
        guard salt.count == saltLength else { throw Failure.badSalt }
        var key = Data(count: keyLength)
        let status: Int32 = password.withCString { passwordPointer in
            salt.withUnsafeBytes { saltRaw -> Int32 in
                key.withUnsafeMutableBytes { keyRaw -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPointer,
                        password.utf8.count,
                        saltRaw.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        keyRaw.bindMemory(to: UInt8.self).baseAddress,
                        keyLength)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.derivationFailed }
        return SymmetricKey(data: key)
    }

    // MARK: - Internals

    private static func randomSalt() -> Data {
        SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
    }

    /// CryptoKit's combined blob is a 12-byte nonce, the ciphertext, and a
    /// 16-byte tag. Anything shorter does not have a 12-byte nonce, and is
    /// refused before it is handed to the cipher.
    private static func sealedBox(from combined: Data) throws -> AES.GCM.SealedBox {
        guard combined.count >= nonceLength + tagLength else { throw Failure.badNonce }
        let nonceData = combined.prefix(nonceLength)
        let tag = combined.suffix(tagLength)
        guard nonceData.count == nonceLength, tag.count == tagLength else { throw Failure.badNonce }
        let ciphertext = combined.dropFirst(nonceLength).dropLast(tagLength)
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            return try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        } catch {
            throw Failure.badNonce
        }
    }
}
