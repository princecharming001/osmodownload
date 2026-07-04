import Foundation
import Security

/// Supplies the SQLCipher passphrase for the local database, held in the macOS
/// Keychain. On first launch it generates a 256-bit random key, stores it, and
/// returns it; thereafter it returns the same key. The key never leaves the
/// Keychain except to unlock the local file — it's not synced, logged, or shown.
///
/// This is the key half of the "encrypted on your Mac" guarantee: the ciphertext
/// database and its key live on the same machine, but the key is in the Keychain
/// (hardware-protected, gated by the login session) rather than next to the file.
public enum KeychainDBKey {
    public static let service = "com.osmo.app"
    public static let account = "db-passphrase"

    /// Return the existing key, or generate + store one on first use.
    public static func loadOrCreate() throws -> String {
        if let existing = try load() { return existing }
        let key = randomKey()
        try store(key)
        return key
    }

    static func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data,
              let str = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: status)
        }
        return str
    }

    static func store(_ key: String) throws {
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(key.utf8),
            // Available after first unlock, this device only — never in a backup/sync.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw KeychainError(status: status)
        }
    }

    /// A URL-safe 256-bit key from the system CSPRNG.
    static func randomKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    public struct KeychainError: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String {
            "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        }
    }
}
