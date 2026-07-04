import Foundation
import OsmoCore

/// How a contact/thread should read in the UI: a real name when we have one,
/// otherwise the phone/email itself — never "Unknown".
extension OsmoContact {
    var displayLabel: String {
        if let name = displayName, !name.isEmpty { return name }
        return HandleFormat.pretty(handle)
    }
}

enum HandleFormat {
    /// Prettify a raw handle for display. Emails pass through; US phone numbers
    /// get (xxx) xxx-xxxx formatting; anything else is shown as-is.
    static func pretty(_ handle: String) -> String {
        if handle.contains("@") { return handle }
        let digits = Array(handle.filter(\.isNumber))
        let core: [Character]
        if digits.count == 11, digits.first == "1" { core = Array(digits.dropFirst()) }
        else if digits.count == 10 { core = digits }
        else { return handle }   // international / short code → leave raw
        let area = String(core[0..<3]), mid = String(core[3..<6]), last = String(core[6..<10])
        return "(\(area)) \(mid)-\(last)"
    }
}
