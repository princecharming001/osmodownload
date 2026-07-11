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
}

private final class ScriptHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    var value: String? { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ v: String) { lock.lock(); _value = v; lock.unlock() }
}
