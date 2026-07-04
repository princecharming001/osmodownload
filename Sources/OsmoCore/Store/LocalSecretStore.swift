import Foundation

/// A tiny local secret store: values live in `0600` files under Application
/// Support/Osmo, readable only by the user. This deliberately does NOT use the
/// macOS Keychain — the Keychain's per-app ACL fires an access-approval dialog on
/// every code-signature change (i.e. every dev rebuild), which is unusable.
///
/// Security note: the DB-key file sits next to the encrypted database, both owned
/// by the user at `0600`. The encryption still protects the data if the .db file
/// is copied off the machine; the key file is the same on-device trust boundary a
/// Keychain item with an all-apps ACL would give. Honest and prompt-free.
public enum LocalSecretStore {
    private static var dir: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let d = base.appendingPathComponent("Osmo", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func url(_ name: String) -> URL { dir.appendingPathComponent(".\(name)") }

    public static func read(_ name: String) -> String? {
        guard let data = try? Data(contentsOf: url(name)),
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    @discardableResult
    public static func write(_ value: String, _ name: String) -> Bool {
        let u = url(name)
        guard (try? Data(value.utf8).write(to: u, options: .atomic)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
        return true
    }

    public static func delete(_ name: String) {
        try? FileManager.default.removeItem(at: url(name))
    }
}
