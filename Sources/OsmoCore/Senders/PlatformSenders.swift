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

    /// Best-effort "reveal this conversation" for a deep-link click: there is
    /// no public AppleScript API to select a specific chat by identifier, so
    /// this activates Messages (bringing the app forward) as the honest half
    /// of the assist — the caller pairs it with an `imessage://` URL attempt.
    public func activateMessages() throws {
        try exec(#"tell application "Messages" to activate"#)
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
