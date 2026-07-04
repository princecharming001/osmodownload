import Foundation
import CryptoKit

/// Client-side encryption for the sync oplog. The server only ever stores the
/// opaque `combined` ciphertext, so it can never read the user's messages — this
/// is what keeps "your messages never leave your machine (readably)" true even
/// with cloud sync on.
///
/// Encryption is real (ChaCha20-Poly1305, AEAD). **Key derivation here is a
/// placeholder** (HKDF over the passphrase) so the engine is testable now;
/// production must derive the key with a memory-hard password KDF (Argon2id via
/// libsodium) — that swap is isolated to `key(from:)`.
public struct CryptoBox: Sendable {
    private let key: SymmetricKey

    public init(passphrase: String, salt: Data = CryptoBox.defaultSalt) {
        self.key = CryptoBox.key(from: passphrase, salt: salt)
    }

    public init(key: SymmetricKey) { self.key = key }

    public func seal(_ plaintext: Data) throws -> Data {
        try ChaChaPoly.seal(plaintext, using: key).combined
    }

    public func open(_ ciphertext: Data) throws -> Data {
        let box = try ChaChaPoly.SealedBox(combined: ciphertext)
        return try ChaChaPoly.open(box, using: key)
    }

    /// PLACEHOLDER KDF — replace with Argon2id for production (see type doc).
    static func key(from passphrase: String, salt: Data) -> SymmetricKey {
        let ikm = SymmetricKey(data: Data(passphrase.utf8))
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                             info: Data("osmo.sync.v1".utf8), outputByteCount: 32)
        return derived
    }

    public static let defaultSalt = Data("osmo.static.salt.replace.in.prod".utf8)
}
