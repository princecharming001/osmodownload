import Foundation

/// Sends an approved message on a platform that supports direct send. Red
/// platforms (LinkedIn/Instagram) never get a sender — the app inserts the draft
/// into the compose box instead (an AppKit concern, handled app-side).
public protocol MessageSending: Sendable {
    /// Send `text` to a platform-native target (a handle, channel id, etc.).
    func send(_ text: String, to target: String) async throws
}

public enum SendError: Error, Equatable, Sendable {
    case appleScript(String)
    case http(Int)
    case notConfigured
}

/// Sends iMessages by driving Messages.app via AppleScript (Apple Events / the
/// Automation permission the user grants once). Execution is injectable so the
/// script generation is unit-tested **without ever sending a real message**.
public struct IMessageSender: MessageSending {
    public typealias Exec = @Sendable (String) throws -> Void
    let exec: Exec

    public init(exec: Exec? = nil) {
        self.exec = exec ?? { script in try IMessageSender.runOSA(script) }
    }

    public func send(_ text: String, to handle: String) async throws {
        try exec(Self.script(text: text, handle: handle))
    }

    /// The AppleScript that sends `text` to `handle` over iMessage. Both values
    /// are escaped for AppleScript string literals.
    static func script(text: String, handle: String) -> String {
        """
        tell application "Messages"
            set targetService to 1st service whose service type = iMessage
            set targetBuddy to buddy "\(escape(handle))" of targetService
            send "\(escape(text))" to targetBuddy
        end tell
        """
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func runOSA(_ source: String) throws {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        script?.executeAndReturnError(&error)
        if let error { throw SendError.appleScript(error.description) }
    }
}

/// Sends a Slack message via `chat.postMessage` with the user token. Transport
/// injectable for testing.
public struct SlackSender: MessageSending {
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    let token: String
    let send: Send

    public init(token: String, send: Send? = nil) {
        self.token = token
        self.send = send ?? { req in
            let (d, r) = try await URLSession.shared.data(for: req)
            return (d, (r as? HTTPURLResponse) ?? HTTPURLResponse())
        }
    }

    public func send(_ text: String, to channel: String) async throws {
        let (data, http) = try await send(SlackAPI.postMessageRequest(token: token, channel: channel, text: text))
        guard (200..<300).contains(http.statusCode) else { throw SendError.http(http.statusCode) }
        // Slack returns { ok: false, error } on app-level failures even with 200.
        struct Resp: Decodable { let ok: Bool; let error: String? }
        if let resp = try? JSONDecoder().decode(Resp.self, from: data), !resp.ok {
            throw SendError.appleScript(resp.error ?? "slack error")
        }
    }
}

/// Sends a Gmail reply via `gmail.send`. Builds a minimal RFC 822 message and
/// base64url-encodes it. Transport injectable.
public struct GmailSender: MessageSending {
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    let token: String
    let fromEmail: String
    let send: Send

    public init(token: String, fromEmail: String, send: Send? = nil) {
        self.token = token
        self.fromEmail = fromEmail
        self.send = send ?? { req in
            let (d, r) = try await URLSession.shared.data(for: req)
            return (d, (r as? HTTPURLResponse) ?? HTTPURLResponse())
        }
    }

    /// `target` is the recipient email.
    public func send(_ text: String, to recipient: String) async throws {
        let raw = Self.rfc822(from: fromEmail, to: recipient, body: text)
        let b64 = Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        let (_, http) = try await send(GmailAPI.sendRequest(token: token, rfc822Base64: b64))
        guard (200..<300).contains(http.statusCode) else { throw SendError.http(http.statusCode) }
    }

    static func rfc822(from: String, to: String, body: String) -> String {
        "From: \(from)\r\nTo: \(to)\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n\(body)"
    }
}
