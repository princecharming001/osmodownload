import Foundation
import Security

/// Where the app keeps its backend device credentials.
public protocol DeviceTokenStoring: Sendable {
    func load() throws -> DeviceCredentials?
    func store(_ creds: DeviceCredentials) throws
    func clear() throws
}

/// Keychain-backed credentials (mirrors KeychainDBKey: this-device-only,
/// available after first unlock, never synced).
public struct KeychainDeviceToken: DeviceTokenStoring {
    public static let service = "com.osmo.app"
    public static let account = "backend-device"

    public init() {}

    public func load() throws -> DeviceCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else {
            throw KeychainDBKey.KeychainError(status: status)
        }
        return try? JSONDecoder().decode(DeviceCredentials.self, from: data)
    }

    public func store(_ creds: DeviceCredentials) throws {
        let data = try JSONEncoder().encode(creds)
        try? clear()   // replace-not-update keeps the logic one-path
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw KeychainDBKey.KeychainError(status: status)
        }
    }

    public func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// In-memory credentials for tests and the keyless E2E harness.
public final class MemoryDeviceToken: DeviceTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var creds: DeviceCredentials?
    public init() {}
    public func load() throws -> DeviceCredentials? { lock.lock(); defer { lock.unlock() }; return creds }
    public func store(_ c: DeviceCredentials) throws { lock.lock(); defer { lock.unlock() }; creds = c }
    public func clear() throws { lock.lock(); defer { lock.unlock() }; creds = nil }
}
