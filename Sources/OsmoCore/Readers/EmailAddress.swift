import Foundation

/// Pull a bare email out of a header value like `Sarah Lee <sarah@x.com>` or
/// `sarah@x.com`. Lowercased.
public enum EmailAddress {
    public static func extract(_ raw: String) -> String? {
        if let open = raw.firstIndex(of: "<"), let close = raw.firstIndex(of: ">"), open < close {
            let inner = raw[raw.index(after: open)..<close]
                .trimmingCharacters(in: .whitespaces).lowercased()
            return inner.contains("@") ? inner : nil
        }
        let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return t.contains("@") ? t : nil
    }

    /// The display name portion, if present (`Sarah Lee <…>` → "Sarah Lee").
    public static func displayName(_ raw: String) -> String? {
        guard let open = raw.firstIndex(of: "<") else { return nil }
        let name = raw[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        return name.isEmpty ? nil : name
    }
}
