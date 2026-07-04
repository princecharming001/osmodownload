import Foundation
import OsmoCore

/// Maps a frontmost app (and, for browsers, its active-tab URL) to the platform
/// whose compose field the user is typing in. Pure + table-driven so the typing
/// detector's decisions are unit-testable without any AX plumbing.
public struct AppAllowlist: Sendable {
    /// Native messaging apps → platform (URL irrelevant).
    let nativeApps: [String: Platform]
    /// Browser bundle IDs whose active-tab URL we sniff for a messaging surface.
    let browsers: Set<String>
    /// Ordered (host+path substring → platform) rules for browser URLs.
    let urlRules: [(needle: String, platform: Platform)]

    public static let standard = AppAllowlist(
        nativeApps: [
            "com.apple.MobileSMS": .imessage,        // Messages (NOT com.apple.iChat)
            "com.tinyspeck.slackmacgap": .slack,
            "net.whatsapp.WhatsApp": .whatsapp,
        ],
        browsers: [
            "com.apple.Safari",
            "com.google.Chrome",
            "company.thebrowser.Browser",            // Arc
            "com.microsoft.edgemac",
            "org.mozilla.firefox",
        ],
        urlRules: [
            ("linkedin.com/messaging", .linkedin),
            ("x.com/messages", .x),
            ("twitter.com/messages", .x),
            ("instagram.com/direct", .instagram),
            ("web.whatsapp.com", .whatsapp),
            ("mail.google.com", .gmail),
            ("app.slack.com", .slack),
        ])

    public init(nativeApps: [String: Platform], browsers: Set<String>,
                urlRules: [(needle: String, platform: Platform)]) {
        self.nativeApps = nativeApps
        self.browsers = browsers
        self.urlRules = urlRules
    }

    /// True if this app is worth attaching an AX observer to at all.
    public func isObservable(bundleID: String) -> Bool {
        nativeApps[bundleID] != nil || browsers.contains(bundleID)
    }

    /// True if this app is an Electron/Chromium wrapper that needs
    /// `AXManualAccessibility` set before its tree populates.
    public func needsManualAX(bundleID: String) -> Bool {
        bundleID == "com.tinyspeck.slackmacgap" || bundleID == "net.whatsapp.WhatsApp"
            || browsers.contains(bundleID)
    }

    /// The messaging platform for (app, url), or nil if this isn't a messaging
    /// surface Osmo recognizes.
    public func platform(bundleID: String, url: String?) -> Platform? {
        if let native = nativeApps[bundleID] { return native }
        guard browsers.contains(bundleID), let url = url?.lowercased() else { return nil }
        for rule in urlRules where url.contains(rule.needle) { return rule.platform }
        return nil
    }
}

/// Best-effort partner-name extraction from a window title, per messaging app.
/// Pure so the parsing rules are testable. Returns nil when the title doesn't
/// carry a usable name.
public enum WindowTitleParser {
    public static func partnerName(bundleID: String, windowTitle: String?) -> String? {
        guard let title = windowTitle?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
        switch bundleID {
        case "com.apple.MobileSMS":
            // Messages window title IS the conversation partner (or group name).
            return clean(title)
        case "com.tinyspeck.slackmacgap":
            // "Name (DM) - Workspace - Slack" / "Name - Workspace - Slack"
            let head = title.components(separatedBy: " - ").first ?? title
            return clean(head.replacingOccurrences(of: " (DM)", with: ""))
        case "net.whatsapp.WhatsApp":
            // "Name - WhatsApp" / "WhatsApp - Name"
            let parts = title.components(separatedBy: " - ").filter { $0 != "WhatsApp" }
            guard let head = parts.first else { return nil }
            return clean(head)
        default:
            return nil
        }
    }

    private static func clean(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        // Reject generic app-chrome titles.
        let generic: Set<String> = ["Messages", "Slack", "WhatsApp", "New Message", ""]
        return generic.contains(trimmed) ? nil : trimmed
    }
}
