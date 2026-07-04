import Foundation

/// A handle reduced to a comparable key. Only **phone** and **email** are *global*
/// identifiers that unify a person across platforms; a **username** is platform-
/// scoped (my Slack @id and someone's X @handle live in different namespaces), so
/// usernames never deterministically cross-merge on their own.
public struct NormalizedHandle: Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable { case phone, email, username }
    public var kind: Kind
    public var value: String
    /// Global identifiers cross platforms; platform-scoped ones don't.
    public var isGlobal: Bool { kind == .phone || kind == .email }
    /// A key that includes the platform for non-global handles so they don't
    /// collide across platforms.
    public func key(platform: Platform) -> String {
        isGlobal ? "\(kind.rawValue):\(value)" : "\(platform.rawValue):\(kind.rawValue):\(value)"
    }
}

public enum HandleNormalizer {
    public static func normalize(_ handle: String) -> NormalizedHandle {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@"), trimmed.contains(".") {
            return NormalizedHandle(kind: .email, value: trimmed.lowercased())
        }
        let digits = trimmed.filter(\.isNumber)
        // Phone heuristic: enough digits to be a real number. US-centric last-10
        // canonicalization so +1 (555) 123-4567 and 5551234567 unify.
        if digits.count >= 7 {
            let last10 = String(digits.suffix(10))
            return NormalizedHandle(kind: .phone, value: last10)
        }
        return NormalizedHandle(kind: .username, value: trimmed.lowercased())
    }
}
