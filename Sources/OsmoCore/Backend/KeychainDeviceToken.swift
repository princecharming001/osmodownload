import Foundation

/// Where the app keeps its backend device credentials.
public protocol DeviceTokenStoring: Sendable {
    func load() throws -> DeviceCredentials?
    func store(_ creds: DeviceCredentials) throws
    func clear() throws
}

/// File-backed credentials (mirrors KeychainDBKey — a local `0600` file, not the
/// Keychain, so there's no per-rebuild access-approval prompt). The device token
/// is a backend session identifier, not a high-value secret.
public struct KeychainDeviceToken: DeviceTokenStoring {
    /// DEBUG builds talk to localhost and re-register freely against throwaway
    /// mock servers — writing those credentials into the SAME file the Release
    /// app uses would clobber the real production device identity (it did:
    /// the installed app silently became a fresh device, orphaning its
    /// server-side connections). Per-build-flavor files keep them apart.
    #if DEBUG
    static let secretName = "device-dev"
    #else
    static let secretName = "device"
    #endif
    public init() {}

    public func load() throws -> DeviceCredentials? {
        guard let json = LocalSecretStore.read(Self.secretName),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DeviceCredentials.self, from: data)
    }

    public func store(_ creds: DeviceCredentials) throws {
        let data = try JSONEncoder().encode(creds)
        LocalSecretStore.write(String(decoding: data, as: UTF8.self), Self.secretName)
    }

    public func clear() throws { LocalSecretStore.delete(Self.secretName) }
}

/// In-memory device-token store for tests.
public final class MemoryDeviceToken: DeviceTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var creds: DeviceCredentials?
    public init() {}
    public func load() throws -> DeviceCredentials? { lock.lock(); defer { lock.unlock() }; return creds }
    public func store(_ c: DeviceCredentials) throws { lock.lock(); defer { lock.unlock() }; creds = c }
    public func clear() throws { lock.lock(); defer { lock.unlock() }; creds = nil }
}
