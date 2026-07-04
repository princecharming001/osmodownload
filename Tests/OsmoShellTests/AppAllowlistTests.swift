import Testing
import Foundation
import OsmoCore
@testable import OsmoShell

@Suite("App allowlist + window-title parsing")
struct AppAllowlistTests {
    let list = AppAllowlist.standard

    @Test("Native messaging apps map by bundle id, url ignored")
    func nativeApps() {
        #expect(list.platform(bundleID: "com.apple.MobileSMS", url: nil) == .imessage)
        #expect(list.platform(bundleID: "com.tinyspeck.slackmacgap", url: nil) == .slack)
        #expect(list.platform(bundleID: "net.whatsapp.WhatsApp", url: nil) == .whatsapp)
    }

    @Test("Browsers map only via a recognized messaging URL")
    func browserURLs() {
        #expect(list.platform(bundleID: "com.apple.Safari", url: "https://www.linkedin.com/messaging/thread/123") == .linkedin)
        #expect(list.platform(bundleID: "com.google.Chrome", url: "https://x.com/messages/456") == .x)
        #expect(list.platform(bundleID: "company.thebrowser.Browser", url: "https://www.instagram.com/direct/t/9") == .instagram)
        #expect(list.platform(bundleID: "com.apple.Safari", url: "https://mail.google.com/mail/u/0") == .gmail)
        // A browser on a non-messaging page → no platform.
        #expect(list.platform(bundleID: "com.apple.Safari", url: "https://news.ycombinator.com") == nil)
        // A browser with no URL → no platform.
        #expect(list.platform(bundleID: "com.apple.Safari", url: nil) == nil)
    }

    @Test("Non-messaging apps (Xcode, Terminal) are never observable")
    func nonMessaging() {
        #expect(list.platform(bundleID: "com.apple.dt.Xcode", url: nil) == nil)
        #expect(!list.isObservable(bundleID: "com.apple.Terminal"))
        #expect(list.isObservable(bundleID: "com.apple.MobileSMS"))
        #expect(list.isObservable(bundleID: "com.apple.Safari"))
    }

    @Test("Electron/browser apps are flagged for manual AX; Messages is not")
    func manualAX() {
        #expect(list.needsManualAX(bundleID: "com.tinyspeck.slackmacgap"))
        #expect(list.needsManualAX(bundleID: "com.apple.Safari"))
        #expect(!list.needsManualAX(bundleID: "com.apple.MobileSMS"))
    }

    @Test("Window titles yield the conversation partner per app")
    func titleParsing() {
        #expect(WindowTitleParser.partnerName(bundleID: "com.apple.MobileSMS", windowTitle: "Maya Chen") == "Maya Chen")
        #expect(WindowTitleParser.partnerName(bundleID: "com.tinyspeck.slackmacgap", windowTitle: "Priya Patel - Acme - Slack") == "Priya Patel")
        #expect(WindowTitleParser.partnerName(bundleID: "com.tinyspeck.slackmacgap", windowTitle: "Priya (DM) - Acme - Slack") == "Priya")
        #expect(WindowTitleParser.partnerName(bundleID: "net.whatsapp.WhatsApp", windowTitle: "Dad - WhatsApp") == "Dad")
        // Generic chrome titles produce nil, not a bogus partner.
        #expect(WindowTitleParser.partnerName(bundleID: "com.apple.MobileSMS", windowTitle: "Messages") == nil)
        #expect(WindowTitleParser.partnerName(bundleID: "com.apple.MobileSMS", windowTitle: "") == nil)
    }
}
