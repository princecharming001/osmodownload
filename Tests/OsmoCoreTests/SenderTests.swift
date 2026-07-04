import Testing
import Foundation
@testable import OsmoCore

@Suite("Platform senders (L3)")
struct SenderTests {

    @Test("iMessage AppleScript is generated + escaped, never actually sent in tests")
    func imessageScript() async throws {
        let holder = ScriptHolder()
        let sender = IMessageSender(exec: { script in holder.set(script) })
        try await sender.send("say \"hi\" now", to: "+15551234567")
        let s = try #require(holder.value)
        #expect(s.contains("tell application \"Messages\""))
        #expect(s.contains("buddy \"+15551234567\""))
        #expect(s.contains(#"send "say \"hi\" now""#))   // quotes escaped for AppleScript
        #expect(s.contains("service type = iMessage"))
    }

    @Test("iMessage escaping handles backslashes and quotes")
    func escaping() {
        #expect(IMessageSender.escape(#"a\b"c"#) == #"a\\b\"c"#)
    }

    @Test("Slack sender posts to chat.postMessage with the token")
    func slackSend() async throws {
        let captured = Box()
        let sender = SlackSender(token: "xoxp-1", send: { req in
            await captured.set(req)
            return (Data(#"{"ok":true}"#.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        try await sender.send("shipping it", to: "C123")
        let req = await captured.request!
        #expect(req.url?.absoluteString.contains("chat.postMessage") == true)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer xoxp-1")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["channel"] as? String == "C123")
        #expect(body["text"] as? String == "shipping it")
    }

    @Test("Slack surfaces an app-level ok:false error")
    func slackError() async throws {
        let sender = SlackSender(token: "t", send: { req in
            (Data(#"{"ok":false,"error":"not_in_channel"}"#.utf8),
             HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: SendError.appleScript("not_in_channel")) {
            try await sender.send("x", to: "C1")
        }
    }

    @Test("Gmail sender builds RFC822 + base64url and posts to messages/send")
    func gmailSend() async throws {
        let captured = Box()
        let sender = GmailSender(token: "tok", fromEmail: "me@self.com", send: { req in
            await captured.set(req)
            return (Data(#"{"id":"sent1"}"#.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        try await sender.send("sounds good, 3pm works", to: "client@acme.com")
        let req = await captured.request!
        #expect(req.url?.absoluteString.hasSuffix("messages/send") == true)
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        let raw = body["raw"] as! String
        let decoded = String(decoding: Data(base64Encoded:
            raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"))!, as: UTF8.self)
        #expect(decoded.contains("To: client@acme.com"))
        #expect(decoded.contains("sounds good, 3pm works"))
    }
}

private actor Box {
    var request: URLRequest?
    func set(_ r: URLRequest) { request = r }
}

private final class ScriptHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    var value: String? { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ v: String) { lock.lock(); _value = v; lock.unlock() }
}
