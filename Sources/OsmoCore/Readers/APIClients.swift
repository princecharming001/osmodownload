import Foundation

/// Injected credentials for the official-API readers. All optional/empty by
/// default so the app runs keyless; the real tokens (from the user's own OAuth)
/// drop in last. OAuth flows (Gmail loopback+PKCE, Slack PKCE) live in the app
/// layer; these clients just carry the resulting token.
public struct APICredentials: Sendable, Equatable {
    public var gmailAccessToken: String?
    public var gmailSelfEmail: String?
    public var slackUserToken: String?
    public var slackSelfUserID: String?
    public init(gmailAccessToken: String? = nil, gmailSelfEmail: String? = nil,
                slackUserToken: String? = nil, slackSelfUserID: String? = nil) {
        self.gmailAccessToken = gmailAccessToken
        self.gmailSelfEmail = gmailSelfEmail
        self.slackUserToken = slackUserToken
        self.slackSelfUserID = slackSelfUserID
    }
    public var gmailReady: Bool { !(gmailAccessToken ?? "").isEmpty }
    public var slackReady: Bool { !(slackUserToken ?? "").isEmpty }
}

/// Thin request builders for the official APIs. Verified endpoints (July 2026):
/// Gmail `history.list` polling (no server needed) + `messages.get`; Slack
/// `conversations.history` with a user token. Kept as pure request shaping so the
/// transport is injectable and the auth/URL are unit-tested without a network;
/// live fetch + decode is wired when tokens arrive.
public enum GmailAPI {
    public static let base = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!

    public static func historyListRequest(token: String, startHistoryId: String) -> URLRequest {
        var comps = URLComponents(url: base.appendingPathComponent("history"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "startHistoryId", value: startHistoryId)]
        return authed(comps.url!, token)
    }

    public static func messageGetRequest(token: String, id: String) -> URLRequest {
        var comps = URLComponents(url: base.appendingPathComponent("messages/\(id)"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "format", value: "metadata")]
        return authed(comps.url!, token)
    }

    /// `gmail.send` — the CASA-free send path (send-only is merely a Sensitive scope).
    public static func sendRequest(token: String, rfc822Base64: String) -> URLRequest {
        var req = authed(base.appendingPathComponent("messages/send"), token)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["raw": rfc822Base64])
        return req
    }

    private static func authed(_ url: URL, _ token: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }
}

public enum SlackAPI {
    public static let base = URL(string: "https://slack.com/api/")!

    public static func conversationsHistoryRequest(token: String, channel: String,
                                                   limit: Int = 200) -> URLRequest {
        var comps = URLComponents(url: base.appendingPathComponent("conversations.history"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "channel", value: channel),
                            .init(name: "limit", value: String(limit))]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    public static func postMessageRequest(token: String, channel: String, text: String) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent("chat.postMessage"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["channel": channel, "text": text])
        return req
    }
}
