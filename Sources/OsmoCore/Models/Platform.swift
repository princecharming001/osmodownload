import Foundation

/// The messaging surfaces Osmo unifies. Raw values are stable wire identifiers —
/// they appear in the DB, in deterministic-ID derivation, and in sync payloads,
/// so **never rename a raw value** (add a new case + migrate instead).
public enum Platform: String, Codable, Sendable, CaseIterable, Hashable {
    case imessage
    case gmail
    case slack
    case whatsapp
    case linkedin
    case x
    case instagram

    /// How Osmo reaches this platform today (drives the integration-health UI and
    /// the send-capability split — see the plan's Sending section).
    public enum Access: String, Codable, Sendable {
        /// Own-device local data, no ban surface (iMessage chat.db, WhatsApp local DB).
        case localData
        /// Official API with the user's own auth (Gmail, Slack).
        case officialAPI
        /// No safe background read — the overlay screen-reads the visible thread.
        case overlayOnly
    }

    public var access: Access {
        switch self {
        case .imessage, .whatsapp: return .localData
        case .gmail, .slack: return .officialAPI
        case .linkedin, .x, .instagram: return .overlayOnly
        }
    }

    /// Platforms Osmo lists but can't reliably connect yet — X's Unipile provider
    /// is mid-refactor ("no longer maintained") and the official X API is paid with
    /// no free tier. Shown as "Coming soon" rather than a connect flow that fails.
    public var comingSoon: Bool {
        switch self {
        case .x: return true
        default: return false
        }
    }

    /// Whether Osmo can send directly (true one-click) vs. draft-and-insert.
    /// The red platforms permanently ban auto-send, so there the app inserts the
    /// draft into the real compose box and the user presses Return.
    public var supportsDirectSend: Bool {
        switch self {
        case .imessage, .gmail, .slack, .whatsapp, .x: return true
        case .linkedin, .instagram: return false
        }
    }

    public var displayName: String {
        switch self {
        case .imessage: return "iMessage"
        case .gmail: return "Gmail"
        case .slack: return "Slack"
        case .whatsapp: return "WhatsApp"
        case .linkedin: return "LinkedIn"
        case .x: return "X"
        case .instagram: return "Instagram"
        }
    }
}
