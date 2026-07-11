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

/// Per-sender display names for a GROUP thread's messages, keyed by contact id —
/// nil for 1:1 threads so `ThreadTurn.senderName` stays nil there ("Them" is
/// unambiguous). Feed the result into `ThreadTurn(senderName:)` so the AI layer
/// (drafts, dossier, insights, judge) knows WHICH person said what in a group.
func groupSenderNames(store: OsmoStore, threadID: UUID) -> [UUID: String]? {
    guard let thread = try? store.thread(id: threadID), thread.isGroup else { return nil }
    let contacts = (try? store.contacts(inThread: threadID)) ?? []
    var names: [UUID: String] = [:]
    for c in contacts { names[c.id] = c.displayLabel }
    return names.isEmpty ? nil : names
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
