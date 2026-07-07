import Foundation
import Sparkle

/// Wraps Sparkle's updater so the app can offer "Check for Updates…" and run
/// silent background checks. Configure the feed + signing key in Info.plist
/// (SUFeedURL / SUPublicEDKey). Direct-distribution auto-update — the Mac App
/// Store handles this itself, so this is only used for the notarized DMG build.
@MainActor
final class UpdaterController: ObservableObject {
    private let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater: true → schedules the automatic background check per
        // SUEnableAutomaticChecks. A missing/placeholder feed just finds nothing.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    /// Whether the updater can check right now (drives menu-item enablement).
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}
