import Testing
import Foundation
@testable import OsmoShell
import OsmoCore

@Suite("PlatformLinks — deep links into the real conversation")
struct PlatformLinksTests {
    @Test("LinkedIn needs providerThreadID — nil hides the button, present builds the real URL")
    func linkedin() {
        #expect(PlatformLinks.chatURL(platform: .linkedin, platformThreadID: "unipile-chat-1",
                                      providerThreadID: nil, counterpartHandle: nil, isGroup: false) == nil)
        let url = PlatformLinks.chatURL(platform: .linkedin, platformThreadID: "unipile-chat-1",
                                        providerThreadID: "urn:li:conv:123", counterpartHandle: nil, isGroup: false)
        #expect(url?.absoluteString == "https://www.linkedin.com/messaging/thread/urn:li:conv:123/")
    }

    @Test("Instagram needs providerThreadID the same way")
    func instagram() {
        #expect(PlatformLinks.chatURL(platform: .instagram, platformThreadID: "t1",
                                      providerThreadID: nil, counterpartHandle: nil, isGroup: false) == nil)
        let url = PlatformLinks.chatURL(platform: .instagram, platformThreadID: "t1",
                                        providerThreadID: "ig-thread-9", counterpartHandle: nil, isGroup: false)
        #expect(url?.absoluteString == "https://www.instagram.com/direct/t/ig-thread-9/")
    }

    @Test("WhatsApp 1:1 extracts the digits before the JID's @")
    func whatsAppOneToOne() {
        let url = PlatformLinks.chatURL(platform: .whatsapp, platformThreadID: "t1", providerThreadID: nil,
                                        counterpartHandle: "15551234567@s.whatsapp.net", isGroup: false)
        #expect(url?.absoluteString == "https://wa.me/15551234567")
    }

    @Test("WhatsApp tolerates an already-bare digit handle (the local reader's shape)")
    func whatsAppBareDigits() {
        let url = PlatformLinks.chatURL(platform: .whatsapp, platformThreadID: "t1", providerThreadID: nil,
                                        counterpartHandle: "15551234567", isGroup: false)
        #expect(url?.absoluteString == "https://wa.me/15551234567")
    }

    @Test("WhatsApp groups have no deep link — there's no shared group URL scheme")
    func whatsAppGroupHasNoLink() {
        let url = PlatformLinks.chatURL(platform: .whatsapp, platformThreadID: "g1", providerThreadID: nil,
                                        counterpartHandle: "15551234567@g.us", isGroup: true)
        #expect(url == nil)
    }

    @Test("WhatsApp with no handle at all is nil, not a garbage URL")
    func whatsAppNoHandle() {
        let url = PlatformLinks.chatURL(platform: .whatsapp, platformThreadID: "t1", providerThreadID: nil,
                                        counterpartHandle: nil, isGroup: false)
        #expect(url == nil)
    }

    @Test("Slack needs the teamId:channelId providerThreadID shape")
    func slack() {
        #expect(PlatformLinks.chatURL(platform: .slack, platformThreadID: "C123",
                                      providerThreadID: nil, counterpartHandle: nil, isGroup: false) == nil)
        // Malformed (no colon) also hides the button rather than guessing.
        #expect(PlatformLinks.chatURL(platform: .slack, platformThreadID: "C123",
                                      providerThreadID: "justChannelNoTeam", counterpartHandle: nil, isGroup: false) == nil)
        let url = PlatformLinks.chatURL(platform: .slack, platformThreadID: "C123",
                                        providerThreadID: "T111:C123", counterpartHandle: nil, isGroup: false)
        #expect(url?.absoluteString == "slack://channel?team=T111&id=C123")
    }

    @Test("Slack's web app_redirect fallback mirrors the same team/channel split")
    func slackWebFallback() {
        #expect(PlatformLinks.slackWebFallback(providerThreadID: nil) == nil)
        let url = PlatformLinks.slackWebFallback(providerThreadID: "T111:C123")
        #expect(url?.absoluteString == "https://slack.com/app_redirect?team=T111&channel=C123")
    }

    @Test("Gmail's platformThreadID is already the real thread id — always works")
    func gmail() {
        let url = PlatformLinks.chatURL(platform: .gmail, platformThreadID: "17c9f2a1",
                                        providerThreadID: nil, counterpartHandle: nil, isGroup: false)
        #expect(url?.absoluteString == "https://mail.google.com/mail/u/0/#all/17c9f2a1")
    }

    @Test("iMessage and X have no URL — callers fall back to their own special path")
    func noLinkPlatforms() {
        #expect(PlatformLinks.chatURL(platform: .imessage, platformThreadID: "t1",
                                      providerThreadID: nil, counterpartHandle: "+15551234567", isGroup: false) == nil)
        #expect(PlatformLinks.chatURL(platform: .x, platformThreadID: "t1",
                                      providerThreadID: nil, counterpartHandle: nil, isGroup: false) == nil)
    }
}
