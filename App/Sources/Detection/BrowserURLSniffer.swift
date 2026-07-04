import AppKit
import ApplicationServices

/// Reads the active-tab URL of a browser so the allow-list can recognize
/// web-based messaging (LinkedIn/X/Instagram/Gmail). AppleScript for the
/// scriptable browsers; the Automation prompt fires lazily on first use.
@MainActor
struct BrowserURLSniffer {
    func activeTabURL(bundleID: String) -> String? {
        let script: String?
        switch bundleID {
        case "com.apple.Safari":
            script = "tell application \"Safari\" to return URL of front document"
        case "com.google.Chrome":
            script = "tell application \"Google Chrome\" to return URL of active tab of front window"
        case "company.thebrowser.Browser":
            script = "tell application \"Arc\" to return URL of active tab of front window"
        case "com.microsoft.edgemac":
            script = "tell application \"Microsoft Edge\" to return URL of active tab of front window"
        default:
            script = nil
        }
        guard let script else { return nil }
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        return result?.stringValue
    }
}
