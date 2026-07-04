import Foundation

/// Supplies the SQLCipher passphrase for the local database. Backed by a local
/// `0600` file (see [LocalSecretStore]) rather than the macOS Keychain, because
/// the Keychain prompts for approval on every code-signature change. On first
/// launch it generates a 256-bit random key, writes it, and returns it;
/// thereafter it returns the same key. No approval dialog, ever.
///
/// This is the key half of the "encrypted on your Mac" guarantee: the ciphertext
/// database and its key both live on this machine, owned by the user.
public enum KeychainDBKey {
    static let secretName = "dbkey"

    /// Return the existing key, or generate + store one on first use.
    public static func loadOrCreate() throws -> String {
        if let existing = LocalSecretStore.read(secretName) { return existing }
        let key = randomKey()
        LocalSecretStore.write(key, secretName)
        return key
    }

    static func load() throws -> String? { LocalSecretStore.read(secretName) }
    static func store(_ key: String) throws { LocalSecretStore.write(key, secretName) }

    /// A URL-safe 256-bit key from the system CSPRNG.
    static func randomKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
    }

    /// Kept for API compatibility with the device-token store's error path.
    public struct KeychainError: Error, CustomStringConvertible {
        public let status: OSStatus
        public init(status: OSStatus) { self.status = status }
        public var description: String { "secret store error \(status)" }
    }
}
