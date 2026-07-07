import Foundation
import OsmoCore

/// Deep links into the REAL conversation on its home platform. Pure —
/// everything the URL needs is passed in, nothing reaches into the store.
/// A wrong/404ing link is worse than no button at all, so every branch that
/// lacks what it needs returns nil rather than guessing.
public enum PlatformLinks {
    /// - Parameters:
    ///   - platformThreadID: Unipile's internal chat id (Gmail: the real thread id).
    ///   - providerThreadID: the provider's OWN thread id (nil until the chat
    ///     index has run once, or on a webhook-only bundle) — required for
    ///     linkedin/instagram/slack; absent means "hide the button".
    ///   - counterpartHandle: the 1:1 partner's raw handle (a WhatsApp JID's
    ///     number part, digits either side of "@" tolerated).
    ///   - isGroup: WhatsApp has no group deep link (no shared group URL scheme).
    public static func chatURL(platform: Platform, platformThreadID: String, providerThreadID: String?,
                               counterpartHandle: String?, isGroup: Bool) -> URL? {
        switch platform {
        case .linkedin:
            guard let providerThreadID, !providerThreadID.isEmpty else { return nil }
            return URL(string: "https://www.linkedin.com/messaging/thread/\(providerThreadID)/")
        case .instagram:
            guard let providerThreadID, !providerThreadID.isEmpty else { return nil }
            return URL(string: "https://www.instagram.com/direct/t/\(providerThreadID)/")
        case .whatsapp:
            guard !isGroup, let handle = counterpartHandle else { return nil }
            let digits = String(handle.prefix { $0 != "@" }).filter(\.isNumber)
            guard !digits.isEmpty else { return nil }
            return URL(string: "https://wa.me/\(digits)")
        case .slack:
            guard let ids = Self.splitTeamChannel(providerThreadID) else { return nil }
            return URL(string: "slack://channel?team=\(ids.team)&id=\(ids.channel)")
        case .gmail:
            return URL(string: "https://mail.google.com/mail/u/0/#all/\(platformThreadID)")
        case .imessage, .x:
            // iMessage has no URL scheme worth trusting — the caller falls back
            // to an AppleScript reveal. X has no DM deep link support (yet).
            return nil
        }
    }

    /// Slack's web `app_redirect` fallback, for when `slack://` isn't handled
    /// (no desktop app installed) — the caller can open this alongside/instead.
    public static func slackWebFallback(providerThreadID: String?) -> URL? {
        guard let ids = Self.splitTeamChannel(providerThreadID) else { return nil }
        return URL(string: "https://slack.com/app_redirect?team=\(ids.team)&channel=\(ids.channel)")
    }

    private static func splitTeamChannel(_ providerThreadID: String?) -> (team: String, channel: String)? {
        guard let providerThreadID, let sep = providerThreadID.firstIndex(of: ":") else { return nil }
        let team = String(providerThreadID[..<sep])
        let channel = String(providerThreadID[providerThreadID.index(after: sep)...])
        guard !team.isEmpty, !channel.isEmpty else { return nil }
        return (team, channel)
    }
}
