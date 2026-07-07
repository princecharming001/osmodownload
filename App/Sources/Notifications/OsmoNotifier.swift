import Foundation
import UserNotifications
import OsmoCore
import OsmoShell

/// Local notifications — the needs-reply nudges + morning digest + snooze-due.
/// Authorization is requested lazily (after the first sync, never stacked on the
/// onboarding Accessibility prompt). The decision of *whether* to notify lives in
/// OsmoShell.NotificationRules (pure + tested); this is the plumbing.
@MainActor
final class OsmoNotifier: ObservableObject {
    @Published var authorized = false
    private var recentlyNotified: Set<UUID> = []
    private var digestHour = 9

    init() {
        Task { await refreshAuthorization() }
    }

    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorized = settings.authorizationStatus == .authorized
    }

    /// Ask for permission (the lazy prompt, triggered from the Today nudge card).
    func requestAuthorization() async {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        authorized = granted
    }

    /// Consider a fresh inbound message; notify iff the rules say so.
    func considerInbound(_ inbound: RealtimeSyncEngine.NewInbound,
                         focusedThreadID: UUID?, mutedThreadIDs: Set<UUID>,
                         store: OsmoStore) {
        guard authorized else { return }
        let env = NotificationRules.Environment(
            mutedThreadIDs: mutedThreadIDs,
            focusedThreadID: focusedThreadID,
            recentlyNotified: recentlyNotified)
        let signal = NotificationRules.InboundSignal(
            threadID: inbound.threadID, isFromMe: inbound.message.isFromMe,
            sentAt: inbound.message.sentAt)
        guard NotificationRules.decide(signal, env) == .notify else { return }

        recentlyNotified.insert(inbound.threadID)
        // Clear the coalescing mark after a couple minutes.
        Task { try? await Task.sleep(for: .seconds(120)); recentlyNotified.remove(inbound.threadID) }

        let name = threadName(inbound.threadID, store: store)
        post(id: "inbound-\(inbound.threadID)", title: name,
             body: inbound.message.text, threadID: inbound.threadID)
    }

    /// Rebuild the morning digest from the queue (called after each sync).
    func scheduleDigest(owedCount: Int, at hour: Int? = nil) {
        guard authorized, owedCount > 0 else { return }
        digestHour = hour ?? digestHour
        let content = UNMutableNotificationContent()
        content.title = "Good morning"
        content.body = owedCount == 1 ? "1 conversation is waiting on you."
                                      : "\(owedCount) conversations are waiting on you."
        var comps = DateComponents(); comps.hour = digestHour
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let request = UNNotificationRequest(identifier: "osmo.morning", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    /// Fire when a snoozed thread comes due.
    func notifySnoozeDue(threadID: UUID, name: String) {
        guard authorized else { return }
        post(id: "snooze-\(threadID)", title: "Follow up: \(name)",
             body: "You asked to be reminded about this.", threadID: threadID)
    }

    /// Schedule the trial-ending reminder ladder (2 days out, last day, ended).
    /// Idempotent — re-scheduling replaces the prior set, so a refresh that
    /// reports the same trial doesn't stack duplicates.
    func scheduleTrialEnding(endsAt: Date) {
        guard authorized else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["trial.2d", "trial.1d", "trial.0d"])
        scheduleAt("trial.2d", endsAt.addingTimeInterval(-2 * 86_400),
                   "Your Osmo Pro trial ends in 2 days",
                   "Keep unlimited drafts, the Read on everyone, and autodraft.")
        scheduleAt("trial.1d", endsAt.addingTimeInterval(-86_400),
                   "Last day of your Osmo Pro trial",
                   "Subscribe to keep Pro without interruption.")
        scheduleAt("trial.0d", endsAt,
                   "Your Osmo Pro trial has ended",
                   "You're back on Free — upgrade anytime to unlock Pro again.")
    }

    private func scheduleAt(_ id: String, _ date: Date, _ title: String, _ body: String) {
        guard date > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// A provider session dropped (the account went CREDENTIALS/ERROR/STOPPED).
    /// The one-click "Reconnect" already lives in Connections; this is the
    /// proactive half — so a dead connection surfaces the moment it happens
    /// instead of waiting for the user to notice a stale inbox. Caller dedupes
    /// (one notification per drop, cleared on reconnect).
    func notifyConnectionDegraded(platform: Platform) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(platform.displayName) needs a quick re-link"
        content.body = "One click to reconnect — nothing else to set up."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "degraded-\(platform.rawValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Plumbing

    private func post(id: String, title: String, body: String, threadID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["threadID": threadID.uuidString]
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func threadName(_ threadID: UUID, store: OsmoStore) -> String {
        if let thread = try? store.thread(id: threadID), let title = thread.title { return title }
        let contacts = (try? store.contacts(inThread: threadID)) ?? []
        return contacts.first?.displayName ?? contacts.first?.handle ?? "New message"
    }
}
