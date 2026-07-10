import Foundation
import SwiftUI
import AppKit
import Combine
import OsmoCore
import OsmoBrain
import OsmoShell

/// A person as the UI shows them: identity + where the conversation stands.
struct PersonRow: Identifiable, Sendable {
    var id: UUID
    var name: String
    var avatar: Data?
    var status: TextingStatus
    var platforms: [Platform]
    /// Public-profile headline (enrichment) — list-row subtitle + Ask directory.
    var headline: String?
}

/// The signed-in user's own profile. Device-local for now (edited in the
/// account page, persisted next to config); real auth — Sign in with Apple /
/// email — replaces `isSignedIn`/`email` when the accounts backend lands, at
/// which point this becomes the local cache of the server identity.
struct UserAccount: Codable, Equatable {
    var displayName: String
    var email: String
    var avatarData: Data?
    var memberSince: Date
    var isSignedIn: Bool
    /// Stable Sign in with Apple user id (never the email) — the future server
    /// account key. nil until the user signs in.
    var appleUserID: String?

    static func fresh() -> UserAccount {
        UserAccount(displayName: "", email: "", avatarData: nil, memberSince: Date(),
                    isSignedIn: false, appleUserID: nil)
    }
}

/// The app's single source of truth. Owns the store, suggestion service, backend
/// client, connections manager, realtime sync engine, and notifier — every
/// surface hangs off this. `@MainActor` so views bind directly.
@MainActor
final class AppModel: ObservableObject {
    /// Every app-level modal, presented through ONE `.sheet(item:)` in
    /// MainWindow. A single `@Published` source of truth — never a computed
    /// Binding recreated on every body evaluation — so a rapid republish
    /// (the realtime poll, every ~3s) can't tear down/rebuild the presented
    /// sheet's identity mid-interaction and wedge its event routing.
    enum AppSheet: Int, Identifiable {
        case consent, whatsNew, paywall, feedback, help, account
        var id: Int { rawValue }
    }
    @Published var activeSheet: AppSheet?

    /// Close the current sheet, then present `next` shortly after — so SwiftUI
    /// fully tears the first one down before standing up the next. Never
    /// present a sheet directly from within another sheet's view tree.
    func handoff(to next: AppSheet) {
        activeSheet = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.activeSheet = next
        }
    }

    // Projects is gone as a destination — a goal lives ON the person (set from
    // the person page), which is how the pitch frames it: "a goal for every
    // relationship", not a separate project manager.
    enum Section: String, CaseIterable, Identifiable {
        case today = "Today"
        case inbox = "Inbox"
        case people = "People"
        case you = "You"
        case connections = "Connections"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .today: return "sun.max"
            case .inbox: return "tray"
            case .people: return "person.2"
            case .you: return "person.crop.circle"
            case .connections: return "link"
            }
        }
    }

    let store: OsmoStore
    let backend: BackendClient
    let connections: ConnectionsManager
    private let realtime: RealtimeSyncEngine
    let notifier: OsmoNotifier

    @Published private(set) var service: SuggestionService
    /// The Ask-path service (network errors PROPAGATE, no silent mock answer) —
    /// used ONLY by `askOsmo`. `service` stays the draft/intel/dossier path.
    @Published private(set) var askService: SuggestionService
    @Published var config: RuntimeConfig

    @Published var section: Section = .today
    @Published var people: [PersonRow] = []
    @Published var queue: [QueueCard] = []
    @Published var projects: [Project] = []
    @Published var threads: [OsmoThread] = []
    @Published var searchText: String = ""
    @Published var searchResults: [OsmoMessage] = []
    @Published var syncing = false
    @Published var lastSyncSummary: String?
    @Published var isMockMode = true
    @Published var mergeSuggestions: [MergeSuggestion] = []
    /// Thread currently open in the detail pane (suppresses its notifications).
    @Published var focusedThreadID: UUID?
    /// Inbox selection (also set by Today's "Draft" to deep-link a thread).
    @Published var selectedThreadID: UUID? {
        didSet {
            // A deep-link must never land on a filtered-out thread — clear the
            // platform filter if it would hide the selection.
            if let id = selectedThreadID, let filter = inboxPlatformFilter,
               let thread = threads.first(where: { $0.id == id }), thread.platform != filter {
                inboxPlatformFilter = nil
            }
        }
    }
    /// Inbox platform filter (nil = all). Lives here, not in view @State, so it
    /// survives section switches and view identity churn.
    @Published var inboxPlatformFilter: Platform?
    /// When false (default) the app shows only genuine human conversations and
    /// hides automated ones (OTP codes, marketing, no-reply notifications). The
    /// user flips this to see everything. Never deletes — a pure view filter.
    @Published var showNonHuman = false { didSet { reload() } }
    /// Demo mode: per platform, the 5 most recent conversations from the last 15
    /// days — a uniformly tiny dataset for demos. Pure view filter (nothing is
    /// deleted); persisted so it survives relaunch.
    @Published var demoMode = UserDefaults.standard.bool(forKey: "demoScope") {
        didSet { UserDefaults.standard.set(demoMode, forKey: "demoScope"); reload() }
    }
    /// Armed follow-up reminders, split by dueness on every reload.
    @Published private(set) var dueFollowups: [ThreadFollowup] = []
    @Published private(set) var pendingFollowups: [ThreadFollowup] = []
    /// Inbox ordering: recency (default) or attention-priority (who needs you
    /// first — the Kinso-style ranked view, computed locally).
    enum InboxSort: String { case recent, priority }
    @Published var inboxSort: InboxSort = .recent
    /// Fast filters: only threads awaiting YOUR reply / only one topic label.
    @Published var unansweredOnly = false
    @Published var topicFilter: String?
    /// Deeper filters over the Action/Time intel layers (nil = no filter).
    @Published var urgencyFilter: IntelUrgency?
    @Published var actionFilter: IntelAction?
    /// Texting status per thread (from the latest snapshots) — drives priority.
    @Published private(set) var statusByThread: [UUID: TextingStatus] = [:]
    /// Per-thread human verdict + reason, so the inbox can filter/annotate live.
    @Published private(set) var humanByThread: [UUID: Bool] = [:]
    @Published private(set) var nonHumanReasonByThread: [UUID: String] = [:]
    /// How many threads are currently hidden as non-human (for the toggle label).
    @Published private(set) var hiddenNonHumanCount = 0
    /// Today-header pulse: inbound messages in the last 24h + threads active this week.
    @Published private(set) var newInbound24h = 0
    @Published private(set) var activeThreads7d = 0
    /// Person detail selection.
    @Published var selectedPersonID: UUID?
    /// A transient toast surfaced by any surface.
    @Published var toast: String?
    /// Monotonic store-generation signal, bumped at the end of every `reload()`.
    /// Views holding local @State (e.g. an open thread transcript) observe this to
    /// re-read the store on ANY change — a pill send, an incoming message, or a
    /// background poll — not just their own actions.
    @Published private(set) var dataVersion = 0

    // MARK: Entitlements (free / trial / pro)

    /// The TAMPER-RESISTANT tier: a server-signed entitlement verified locally
    /// against a bundled public key. Editing the cached file breaks the
    /// signature and drops to free — unlike the old editable tier field. The
    /// local `entitlements` state below is now ONLY the free-draft UX meter.
    @Published private(set) var verifiedEntitlement: VerifiedEntitlement? = AppModel.loadVerifiedEntitlement()
    /// Local free-tier meter (snappy UX). The SERVER also enforces the quota, so
    /// this can't be gamed to burn the AI budget — it just avoids a round-trip.
    @Published private(set) var entitlements: Entitlements.State = AppModel.loadEntitlements()
    /// Whether Pro-only surfaces are unlocked — from the verified entitlement.
    var isPro: Bool { verifiedEntitlement?.tier.isPaid ?? false }

    /// Whether to OFFER a trial (free + never trialed). A brand-new device with
    /// no entitlement yet also qualifies.
    var trialAvailable: Bool { !isPro && verifiedEntitlement?.trialStartedAt == nil }

    /// Ask permission to run one AI draft. Pro/trial pass through; free is
    /// metered locally (and again server-side). Returns whether it may proceed.
    func requestDraftAllowance() -> Bool {
        guard flag("aiDrafting") else {
            toast = "AI drafting is briefly paused for maintenance — back shortly."
            return false
        }
        if isPro { return true }
        let decision = Entitlements.decideDraft(entitlements, now: Date())
        entitlements = decision.newState
        Self.saveEntitlements(decision.newState)
        if !decision.allowed { activeSheet = .paywall }
        return decision.allowed
    }

    /// Drafts left this week (nil = unlimited on pro/trial).
    var draftsRemaining: Int? {
        if isPro { return nil }
        return Entitlements.decideDraft(entitlements, now: Date(), consume: false).remaining
    }

    /// Re-fetch the signed entitlement from the server (launch / foreground /
    /// after any billing action), optionally redeeming a license key. Verifies
    /// the signature + device binding + expiry before trusting it.
    func refreshEntitlement(licenseKey: String? = nil) async {
        guard let wire = try? await backend.validateLicense(licenseKey: licenseKey),
              let deviceID = try? await backend.deviceID() else { return }
        applyEntitlement(wire, deviceID: deviceID)
    }

    private func applyEntitlement(_ wire: WireEntitlement, deviceID: String) {
        guard let verified = EntitlementVerifier.verify(
            entitlementB64: wire.entitlement, signatureB64: wire.signature,
            expectedDeviceID: deviceID) else {
            // Bad signature / wrong device / expired → treat as unverified (free).
            verifiedEntitlement = nil
            Self.clearVerifiedEntitlement()
            return
        }
        verifiedEntitlement = verified
        Self.saveVerifiedEntitlement(wire)
        // Schedule the trial-ending reminder ladder while on trial.
        if verified.tier == .trial, let endsAt = verified.trialEndsAt {
            notifier.scheduleTrialEnding(endsAt: endsAt)
        }
    }

    /// The user trialed and lapsed to Free — drives a one-time win-back nudge.
    var trialLapsed: Bool { !isPro && verifiedEntitlement?.trialStartedAt != nil }

    // MARK: Referral + promo

    /// This device's shareable referral code + link (generated once, persisted).
    @Published private(set) var referralCode: String = AppModel.loadReferralCode()
    var referralLink: String { "https://osmo.app/r/\(referralCode)" }

    private static func loadReferralCode() -> String {
        if let c = UserDefaults.standard.string(forKey: "referralCode") { return c }
        let c = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased()
        UserDefaults.standard.set(c, forKey: "referralCode")
        return c
    }

    /// Redeem a referral/promo code (may extend the trial).
    func redeemPromo(_ code: String) {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            let wire = try? await self.backend.redeemPromo(code: c)
            let id = try? await self.backend.deviceID()
            await MainActor.run {
                if let wire, let id {
                    self.applyEntitlement(wire, deviceID: id)
                    self.toast = "Code applied."
                } else {
                    self.toast = "That code wasn't recognized."
                }
            }
        }
    }

    // MARK: Feature flags (remote kill-switch)

    @Published private(set) var featureFlags: [String: Bool] = [:]
    /// A remote flag, defaulting to `def` when the config hasn't loaded / omits it.
    func flag(_ key: String, default def: Bool = true) -> Bool { featureFlags[key] ?? def }

    private func refreshFlags() async {
        if let flags = try? await backend.featureFlags() { featureFlags = flags }
    }

    // MARK: Service health (incident banner)

    /// Non-nil when the backend reports a degraded/down status — drives the
    /// app-wide incident banner.
    @Published var serviceStatusMessage: String?
    /// Set when the realtime pull has failed several times in a row (the sync
    /// service is unreachable) — surfaced in the incident banner as a fallback
    /// when the health endpoint itself hasn't flagged anything.
    @Published var backendUnreachable = false

    private func refreshHealth() async {
        if let h = try? await backend.health(), h.status != "operational" {
            serviceStatusMessage = h.message ?? "Osmo is having a brief service hiccup — some features may be slow."
        } else {
            serviceStatusMessage = nil
        }
    }

    // MARK: What's New

    /// Show the changelog once per version bump (never on the very first launch —
    /// onboarding covers that).
    private func checkWhatsNew() {
        let last = UserDefaults.standard.string(forKey: "lastSeenVersion")
        if let last, last != appVersion { activeSheet = .whatsNew }
        else if last == nil { UserDefaults.standard.set(appVersion, forKey: "lastSeenVersion") }
    }
    /// Persist the seen version. Presentation is NOT touched here — the sheet's
    /// own dismissal (button or swipe-to-close) is the single source that clears
    /// `activeSheet`; re-entrant writes from here caused a double-publish into
    /// the same presenter.
    func markWhatsNewSeen() {
        UserDefaults.standard.set(appVersion, forKey: "lastSeenVersion")
    }

    private static func entitlementsURL() -> URL { supportDir().appendingPathComponent("entitlements.json") }
    private static func loadEntitlements() -> Entitlements.State {
        guard let data = try? Data(contentsOf: entitlementsURL()),
              let s = try? JSONDecoder().decode(Entitlements.State.self, from: data) else {
            return Entitlements.State(weekStartedAt: Date())
        }
        return s
    }
    private static func saveEntitlements(_ s: Entitlements.State) {
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: entitlementsURL(), options: .atomic) }
    }

    private static func verifiedEntitlementURL() -> URL { supportDir().appendingPathComponent("entitlement.signed.json") }
    private static func loadVerifiedEntitlement() -> VerifiedEntitlement? {
        guard let data = try? Data(contentsOf: verifiedEntitlementURL()),
              let wire = try? JSONDecoder().decode(WireEntitlement.self, from: data) else { return nil }
        // Signature + expiry now; device-binding is re-checked on the async
        // refresh (closes the copy-someone-else's-cache window once online).
        return EntitlementVerifier.verify(entitlementB64: wire.entitlement,
                                          signatureB64: wire.signature, expectedDeviceID: nil)
    }
    private static func saveVerifiedEntitlement(_ wire: WireEntitlement) {
        if let data = try? JSONEncoder().encode(wire) { try? data.write(to: verifiedEntitlementURL(), options: .atomic) }
    }
    private static func clearVerifiedEntitlement() {
        try? FileManager.default.removeItem(at: verifiedEntitlementURL())
    }

    // MARK: Account (profile)

    /// The user's own profile. Device-local until the accounts backend lands.
    @Published var account: UserAccount = AppModel.loadAccount()

    /// Save an edited profile field (name/email/avatar). Passing `avatar` as
    /// `.some(nil)` clears the photo; omitting it leaves the photo untouched.
    func updateAccount(displayName: String? = nil, email: String? = nil, avatar: Data?? = nil) {
        if let displayName { account.displayName = displayName }
        if let email { account.email = email }
        if case let .some(data) = avatar { account.avatarData = data }
        Self.saveAccount(account)
    }

    /// Finish a Sign in with Apple. Apple returns the name/email only on the
    /// FIRST authorization, so only overwrite when we actually got a value and
    /// don't already have one. The stable `userID` becomes the server account
    /// key when the accounts backend lands.
    func completeSignInWithApple(userID: String, email: String?, fullName: String?) {
        account.appleUserID = userID
        account.isSignedIn = true
        if let email, account.email.isEmpty { account.email = email }
        if let fullName, !fullName.isEmpty, account.displayName.isEmpty { account.displayName = fullName }
        Self.saveAccount(account)
        toast = "Signed in."

        // Link this device to the shared server account so the SAME account +
        // subscription is used on the app and the website. Apple only sends the
        // email/name on the FIRST authorization, so pass whatever we have.
        Task { [weak self] in
            guard let self else { return }
            guard let link = try? await self.backend.linkAccount(
                appleUserID: userID, email: email ?? self.account.email, fullName: fullName),
                  let deviceID = try? await self.backend.deviceID() else { return }
            await MainActor.run {
                // Adopt any email/name the server resolved (e.g. from an existing
                // account the user made on the web with the same address).
                if self.account.email.isEmpty, !link.user.email.isEmpty { self.account.email = link.user.email }
                if self.account.displayName.isEmpty, let dn = link.user.displayName, !dn.isEmpty { self.account.displayName = dn }
                Self.saveAccount(self.account)
                self.applyEntitlement(link.entitlement, deviceID: deviceID)   // subscription now via the account
            }
        }
    }

    func signOut() {
        account.isSignedIn = false
        account.appleUserID = nil
        Self.saveAccount(account)
        toast = "Signed out."
    }

    /// Permanently delete the account: purge the server-side device record
    /// (license, usage, connections, tokens, synced rows), then wipe everything
    /// local and return to a fresh install. Irreversible.
    func deleteAccount() {
        Task { [weak self] in
            guard let self else { return }
            try? await self.backend.deleteAccount()
            await MainActor.run {
                self.account = .fresh()
                Self.saveAccount(self.account)
                Self.clearVerifiedEntitlement()
                self.verifiedEntitlement = nil
                self.deleteAllData()          // local wipe + reset onboarding
                self.toast = "Your account and all local data were deleted."
            }
        }
    }

    /// A human plan label for the profile/billing UI (from the verified tier).
    var planName: String {
        switch verifiedEntitlement?.tier {
        case .pro: return "Pro"
        case .trial: return "Pro — trial"
        default: return "Free"
        }
    }
    var trialDaysLeft: Int? {
        guard verifiedEntitlement?.tier == .trial, let end = verifiedEntitlement?.trialEndsAt else { return nil }
        let left = end.timeIntervalSinceNow / 86_400
        return left > 0 ? Int(left.rounded(.up)) : 0
    }
    var draftsUsedThisWeek: Int { entitlements.draftsThisWeek }

    /// App marketing version (Info.plist), shown in profile/feedback.
    var appVersion: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0" }

    /// Send a feedback / bug report. Diagnostics (version + OS, no message
    /// content) are opt-in.
    func submitFeedback(_ message: String, includeDiagnostics: Bool) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let meta = includeDiagnostics
            ? "Osmo \(appVersion) · \(ProcessInfo.processInfo.operatingSystemVersionString)"
            : nil
        Task { [weak self] in
            guard let self else { return }
            let ok = (try? await self.backend.sendFeedback(message: trimmed, meta: meta)) ?? false
            await MainActor.run {
                self.toast = ok ? "Thanks — your feedback was sent." : "Couldn't send. Please email hi@osmo.app."
            }
        }
    }

    // MARK: Billing actions — all route through the signed-entitlement flow.

    /// Start the 14-day trial, server-recorded so it can't be reset locally.
    func startTrial() {
        Task { [weak self] in
            guard let self else { return }
            let wire = try? await self.backend.startServerTrial()
            let deviceID = try? await self.backend.deviceID()
            await MainActor.run {
                if let wire, let deviceID {
                    self.applyEntitlement(wire, deviceID: deviceID)
                    if self.activeSheet == .paywall { self.activeSheet = nil }
                    self.toast = self.isPro
                        ? "Osmo Pro trial started — unlocked for \(Entitlements.trialDays) days."
                        : "Couldn't start the trial — please try again."
                } else {
                    self.toast = "Couldn't start the trial — check your connection."
                }
            }
        }
    }

    /// Open Stripe checkout (or the mock-complete page in keyless mode).
    func subscribe(to plan: BillingPlan) {
        Task { [weak self] in
            guard let self else { return }
            let checkout = try? await self.backend.createCheckout(plan: plan.id)
            await MainActor.run {
                if let checkout, let url = URL(string: checkout.url) {
                    NSWorkspace.shared.open(url)
                    self.toast = "Opening checkout for \(plan.name) · \(plan.perPeriodText)…"
                } else {
                    self.toast = "Couldn't open checkout — please try again."
                }
            }
        }
    }

    /// Redeem a license key (activates Pro if valid).
    func redeemLicense(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.refreshEntitlement(licenseKey: trimmed)
            await MainActor.run {
                self.toast = self.isPro ? "License activated — welcome to Pro."
                                        : "That license key wasn't recognized."
            }
        }
    }

    /// Manage or cancel an active subscription — the Stripe billing portal.
    func manageSubscription() {
        if let url = URL(string: "https://osmo.app/account/billing") { NSWorkspace.shared.open(url) }
    }

    /// Restore: re-validate this device's entitlement against the server.
    func restorePurchases() {
        Task { [weak self] in
            guard let self else { return }
            await self.refreshEntitlement()
            await MainActor.run {
                self.toast = self.isPro ? "Your Pro subscription is active."
                                        : "No active subscription found for this device."
            }
        }
    }

    /// Developer/testing only: activate Pro via a dev license key (exercises the
    /// real signed-entitlement path). Backend disables this once Stripe is live.
    func activateProLocally() { redeemLicense("OSMO-DEV-PRO") }
    func resetToFree() {
        Task { [weak self] in
            guard let self else { return }
            let wire = try? await self.backend.resetLicense()
            let deviceID = try? await self.backend.deviceID()
            await MainActor.run {
                if let wire, let deviceID { self.applyEntitlement(wire, deviceID: deviceID) }
                self.toast = "Reset to Free (testing)."
            }
        }
    }

    private static func accountURL() -> URL { supportDir().appendingPathComponent("account.json") }
    private static func loadAccount() -> UserAccount {
        guard let data = try? Data(contentsOf: accountURL()),
              let a = try? JSONDecoder().decode(UserAccount.self, from: data) else { return .fresh() }
        return a
    }
    private static func saveAccount(_ a: UserAccount) {
        if let data = try? JSONEncoder().encode(a) { try? data.write(to: accountURL(), options: .atomic) }
    }

    private let syncCoordinator: SyncCoordinator
    private var cancellables = Set<AnyCancellable>()

    /// Contact count at the last identity-graph rebuild + a force flag, so reload
    /// only re-runs the expensive graph pass when contacts changed or a merge/
    /// reject asks for it. See `reload()`.
    private var lastGraphContactCount = -1
    var forceGraphRebuild = false

    init() {
        let url = Self.storeURL()
        let key = try? KeychainDBKey.loadOrCreate()
        let store = Self.openEncrypted(url: url, key: key)
        self.store = store
        var config = Self.loadConfig()
        let backend = BackendClient(baseURL: config.backendOrigin)
        self.backend = backend
        // Authenticate the proxy generator with the CURRENT registered device
        // token (and re-register on a 401) so drafts/ask reach the live model
        // instead of the mock. Set BEFORE building the services — the closures
        // are excluded from Codable, so a loaded config never carries them.
        config.tokenProvider = { [backend] in await backend.registeredToken() }
        config.refreshCredentials = { [backend] in await backend.refreshRegistration() }
        self.config = config
        self.service = config.makeService()
        self.askService = config.makeAskService()
        self.syncCoordinator = SyncCoordinator(store: store)

        self.connections = ConnectionsManager(
            client: backend, persistURL: Self.connectionsURL())
        self.realtime = RealtimeSyncEngine(
            store: store, client: backend,
            cursorStore: FileCursorStore(url: Self.cursorURL()))
        self.notifier = OsmoNotifier()

        reload()
        startRealtime()
    }

    // MARK: - Realtime

    /// Fractional import progress per platform (0…1). Present + < 1 = "Importing".
    @Published var importProgress: [Platform: Double] = [:]
    private var lastImportReload = Date.distantPast

    private func startRealtime() {

        // Pausing/disconnecting iMessage stops the chat.db poller; resuming
        // restarts it. Driven off the connection phase so the button "sticks".
        connections.$phases
            .map { ($0[.imessage] == .paused) || ($0[.imessage] == .disconnected) }
            .removeDuplicates()
            .sink { [weak self] muted in
                Task { await self?.realtime.setLocalMuted(muted); self?.reload() }
            }
            .store(in: &cancellables)

        // Proactive reconnect: the moment a provider session drops, notify —
        // don't wait for the user to notice a stale inbox. Deduped per
        // platform so a flapping connection doesn't spam; cleared once it's
        // active again (or explicitly reset by the user) so a later drop
        // re-notifies.
        connections.$phases
            .sink { [weak self] phases in self?.handleConnectionPhases(phases) }
            .store(in: &cancellables)

        Task { [weak self] in
            guard let self else { return }
            isMockMode = await backend.isMockMode()
            await refreshEntitlement()   // pull the fresh signed tier on launch
            await refreshFlags()         // remote feature flags / kill-switch
            await refreshHealth()        // incident banner
            await MainActor.run { self.checkWhatsNew() }
            await realtime.setOnEvent { [weak self] event in
                Task { @MainActor in self?.connections.handle(event) }
            }
            await realtime.setOnImportProgress { [weak self] platform, fraction in
                Task { @MainActor in self?.handleImportProgress(platform, fraction) }
            }
            await realtime.setOnPullHealth { [weak self] consecutiveFailures in
                Task { @MainActor in self?.backendUnreachable = consecutiveFailures >= 3 }
            }
            await realtime.start()
            await connections.reconcile()
            await deepenHistoryOnce()

            // Fresh inbound → notify (rules) + refresh UI. Ends when the engine
            // finishes the stream (stop()), releasing this task. AppModel is a
            // root object (app lifetime), so the loop's strong hold is fine.
            for await inbound in realtime.inbound {
                // Coalesced: a backfill can yield hundreds of inbounds in a
                // burst — one reload per message re-runs snapshots/classifier
                // per message and makes the whole window janky (drag stutter).
                reloadSoon()
                notifier.considerInbound(inbound, focusedThreadID: focusedThreadID,
                                         mutedThreadIDs: mutedThreadIDs(), store: store)
                considerAutodraft(inbound)
            }
        }
    }

    /// Platforms currently notified as degraded — one notification per drop;
    /// cleared once the platform is active again so a later drop re-fires.
    private var notifiedDegraded: Set<Platform> = []

    /// How many connections need a re-link right now — the Connections
    /// sidebar badge reads this.
    var degradedCount: Int {
        connections.phases.values.filter {
            if case .degraded = $0 { return true }
            return false
        }.count
    }

    private func handleConnectionPhases(_ phases: [Platform: ConnectionPhase]) {
        for (platform, phase) in phases {
            if case .degraded = phase {
                guard notifiedDegraded.insert(platform).inserted else { continue }
                notifier.notifyConnectionDegraded(platform: platform)
            } else {
                notifiedDegraded.remove(platform)
            }
        }
    }

    /// Import progress from the sync engine: update the per-platform bar and
    /// refresh the UI as messages stream in (throttled). At 100% we hold "Done"
    /// briefly, then clear so the row reads a settled "Connected".
    private func handleImportProgress(_ platform: Platform, _ fraction: Double) {
        importProgress[platform] = min(fraction, 1.0)
        // The progress bar (above) updates every tick — cheap. The full reload
        // (rebuild threads + identity graph + snapshots + queue over EVERY thread)
        // is expensive, so throttle it to ~every 2s while importing. Filling the
        // list a touch less often is imperceptible; hammering it pegged the CPU
        // through a large first import.
        if fraction >= 1.0 || Date().timeIntervalSince(lastImportReload) > 2.0 {
            lastImportReload = Date()
            reload()
        }
        if fraction >= 1.0 {
            connections.probeLocal()   // flip iMessage to a real "Connected"
            Task { try? await Task.sleep(for: .seconds(2)); importProgress[platform] = nil }
        }
    }

    /// User tapped "Stop" on an importing platform: halt the import mid-way,
    /// clear the progress bar immediately, and settle the row to Connected with
    /// whatever's already been pulled in.
    func stopImport(_ platform: Platform) {
        importProgress[platform] = nil
        Task { await connections.stopBackfill(platform); reload() }
    }

    /// One-time (per install): re-import 2 months for any live backend platform
    /// that was connected BEFORE the deeper backfill window shipped — so e.g. a
    /// WhatsApp account connected earlier auto-deepens to the full 2 months
    /// without the user having to reconnect. iMessage is always full, so skipped.
    private func deepenHistoryOnce() async {
        let key = "didDeepBackfill.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        for platform in Platform.allCases where platform != .imessage {
            if connections.phases[platform]?.isActive == true {
                await connections.reimportHistory(platform)
            }
        }
    }

    /// Called on foreground/wake to catch up + re-probe local access.
    func onForeground() {
        connections.probeLocal()
        // If the FDA grant propagated live (some macOS versions do), the button
        // flips to Connected on its own and no relaunch prompt is needed.
        if connections.phases[.imessage] == .live { iMessageAwaitingRelaunch = false }
        Task {
            await connections.reconcile(verify: true)
            await realtime.pullNow()
            await drainSendQueue()
            await refreshEntitlement()   // catch a purchase/cancel made elsewhere
            await refreshHealth()
        }
    }

    /// Retry any sends queued while offline. Called on foreground, after a sync,
    /// and after a successful live send. Dequeues on success; drops after too
    /// many attempts so a permanently-failing send can't wedge the queue.
    func drainSendQueue() async {
        let pending = (try? store.queuedSends()) ?? []
        guard !pending.isEmpty else { return }
        var sent = 0
        for item in pending {
            guard let id = item.id else { continue }
            guard connections.canDirectSend(item.platform) else { continue }
            do {
                let message = try await backend.send(
                    platform: item.platform, platformThreadID: item.platformThreadID, text: item.text)
                let normalized = BackendBatchNormalizer.normalize(
                    WireBatch(contacts: [], threads: [], messages: [message], cursor: "", hasMore: false))
                for m in normalized.batch.messages { _ = try? store.ingest(m) }
                try? store.dequeueSend(id: id)
                sent += 1
            } catch {
                try? store.bumpSendAttempt(id: id)
                if item.attempts + 1 >= 5 { try? store.dequeueSend(id: id) }  // give up, don't wedge
            }
        }
        if sent > 0 { reload(); toast = "Sent \(sent) queued message\(sent == 1 ? "" : "s")." }
    }

    private func mutedThreadIDs() -> Set<UUID> {
        // Threads whose platform connection is paused.
        var muted = Set<UUID>()
        for thread in threads {
            if case .paused = connections.phases[thread.platform] { muted.insert(thread.id) }
        }
        return muted
    }

    // MARK: - Config

    func updateConfig(_ new: RuntimeConfig) {
        var new = new
        // A decoded/passed config lost the runtime closures (they're excluded
        // from Codable + Equatable) — re-attach them before building services.
        let backend = self.backend
        new.tokenProvider = { [backend] in await backend.registeredToken() }
        new.refreshCredentials = { [backend] in await backend.refreshRegistration() }
        config = new
        Self.saveConfig(new)
        service = new.makeService()
        askService = new.makeAskService()
    }

    // MARK: - Connect

    /// True after the user tapped "Enable" for iMessage and we sent them to Full
    /// Disk Access, but this running process still can't read chat.db. macOS
    /// caches the FDA decision for a NON-sandboxed process's entire lifetime, so a
    /// grant made while Osmo is running only takes effect after a relaunch. We
    /// surface a one-click Relaunch instead of leaving a dead "Enable" button —
    /// which is exactly why iMessage stayed on "Enable" after enabling it.
    @Published var iMessageAwaitingRelaunch = false

    /// Begin connecting a platform: mint the hosted-auth link and open it.
    func connect(_ platform: Platform) {
        if platform == .imessage {
            // Reconnect/enable: clear any user pause/disconnect + re-probe, then
            // only bounce to Settings if Full Disk Access still isn't granted.
            connections.enableLocal()
            if connections.phases[.imessage] != .live {
                openFullDiskAccessSettings()
                iMessageAwaitingRelaunch = true   // grant needs a relaunch to take effect
            }
            return
        }
        Task {
            do {
                let url = try await connections.beginConnect(platform)
                // The AX probe harness (scripts/ui-probe*) exercises the
                // Connect→linking→Cancel cycle headlessly; opening the real
                // browser there spams tabs and steals focus. The flag is a
                // TIMESTAMP so it can never wedge real connects: it expires on
                // its own even if a killed probe never cleans up.
                let suppressUntil = UserDefaults.standard.double(forKey: "uiProbeSuppressBrowserUntil")
                if Date().timeIntervalSince1970 >= suppressUntil {
                    NSWorkspace.shared.open(url)
                }
            } catch {
                toast = "Couldn't start the \(platform.displayName) connection."
            }
        }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Relaunch Osmo — the only reliable way to pick up a Full-Disk-Access grant
    /// made while this (non-sandboxed) process was already running. Spawns a
    /// detached shell that waits for THIS pid to exit, then reopens the bundle.
    func relaunchApp() {
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"\(bundlePath)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Autodraft on arrival

    /// User toggle (Settings → AI). Default ON — gated by Pro + a live key
    /// regardless, so flipping this on free/mock has no visible effect.
    @Published var autodraftEnabled: Bool =
        (UserDefaults.standard.object(forKey: "autodraftEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autodraftEnabled, forKey: "autodraftEnabled") }
    }
    private var autodraftInFlight = Set<UUID>()

    /// The onboarding context layer (why they're here · self-described style ·
    /// what they struggle with · key people), persisted and injected into every
    /// draft + Ask prompt so Osmo caters to the user from message one. The AI
    /// still learns their ACTUAL style from synced conversations separately.
    @Published var onboardingProfile: OnboardingProfile = AppModel.loadOnboardingProfile() {
        didSet { AppModel.saveOnboardingProfile(onboardingProfile) }
    }
    private static func loadOnboardingProfile() -> OnboardingProfile {
        guard let data = UserDefaults.standard.data(forKey: "onboardingProfile"),
              let p = try? JSONDecoder().decode(OnboardingProfile.self, from: data)
        else { return OnboardingProfile() }
        return p
    }
    private static func saveOnboardingProfile(_ p: OnboardingProfile) {
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: "onboardingProfile")
        }
    }
    /// The platformMessageID Osmo last auto-drafted a reply FOR, per thread —
    /// so a duplicate or late-arriving copy of the same message never re-fires.
    private var autodraftedFor: [UUID: String] = [:]
    private lazy var autodraftCap: AutodraftCapState = Self.loadAutodraftCap()

    private static func autodraftCapURL() -> URL { supportDir().appendingPathComponent("autodraftCap.json") }
    private static func loadAutodraftCap() -> AutodraftCapState {
        guard let data = try? Data(contentsOf: autodraftCapURL()),
              let cap = try? JSONDecoder().decode(AutodraftCapState.self, from: data) else { return .empty }
        return cap
    }
    private static func saveAutodraftCap(_ cap: AutodraftCapState) {
        if let data = try? JSONEncoder().encode(cap) { try? data.write(to: autodraftCapURL(), options: .atomic) }
    }

    /// Consider auto-drafting a reply for one freshly-arrived inbound message —
    /// called from the realtime inbound loop, right after `reload()`. Deliberately
    /// never routes through `requestDraftAllowance` (that pops the paywall as a
    /// side effect; a background task must not do that) — Pro is checked directly,
    /// same as every other background AI call in this file.
    private func considerAutodraft(_ inbound: RealtimeSyncEngine.NewInbound) {
        let threadID = inbound.threadID
        guard flag("autodraft"), flag("aiDrafting"),
              !autodraftInFlight.contains(threadID),
              autodraftedFor[threadID] != inbound.message.platformMessageID,
              !isMockMode, let thread = try? store.thread(id: threadID) else { return }

        let existingDraft = (try? store.draftRecord(forThread: threadID))
            .map { (text: $0.text, isAuto: $0.isAuto) }
        let decision = AutodraftPolicy.decide(
            enabled: autodraftEnabled, isPro: isPro, isGroup: thread.isGroup,
            isHuman: isHuman(threadID), status: statusByThread[threadID] ?? .sayHi,
            existingDraft: existingDraft, cap: autodraftCap, now: Date())
        autodraftCap = decision.newCap
        Self.saveAutodraftCap(decision.newCap)
        guard decision.go else { return }

        autodraftedFor[threadID] = inbound.message.platformMessageID
        autodraftInFlight.insert(threadID)
        let contacts = (try? store.contacts(inThread: threadID)) ?? []
        let name = threadTitle(thread, members: contacts)
        let ctx = ContextAssembler(store: store, projects: projects,
                                   selfPreamble: onboardingProfile.promptPreamble)
            .context(threadID: threadID, platform: thread.platform, personName: name)
        Task { [weak self] in
            guard let self else { return }
            let result = try? await self.service.suggest(ctx, count: 1)
            await MainActor.run {
                self.autodraftInFlight.remove(threadID)
                guard let text = result?.set.takes.first?.text, !text.isEmpty else { return }
                try? self.store.saveDraft(text, forThread: threadID, isAuto: true)
                self.reload()
            }
        }
    }

    // MARK: - Sync + reload

    func sync() async {
        syncing = true; defer { syncing = false }
        let summary = await syncCoordinator.syncAll()
        lastSyncSummary = summary
        await realtime.pullNow()
        reload()
    }

    /// Per-platform message counts for the Connections subtitles. Cached here
    /// because ConnectionRow re-renders constantly under AX/accessibility load —
    /// a SQLCipher COUNT per row per render starves the main thread (the
    /// "Connect click takes minutes to reflect" wedge).
    @Published private(set) var messageCountByPlatform: [Platform: Int] = [:]

    /// Everything a queue row needs that would otherwise be a SQLCipher read
    /// per row PER RENDER (snippet, timestamp, draft flag, open question).
    /// Rebuilt once per reload — rows just index the dictionary.
    struct QueueRowMeta {
        var snippet: String?
        var when: String?
        var draftReady: Bool
        var lastInboundQuestion: String?
    }
    @Published private(set) var queueRowMeta: [UUID: QueueRowMeta] = [:]

    private func rebuildQueueRowMeta() {
        var meta: [UUID: QueueRowMeta] = [:]
        let formatter = RelativeDateTimeFormatter()
        for card in queue {
            guard let last = try? store.lastMessage(inThread: card.threadID) else { continue }
            let cleaned = SnippetCleaner.clean(last.text, maxLength: 80)
            meta[card.threadID] = QueueRowMeta(
                snippet: cleaned.isEmpty ? nil : (last.isFromMe ? "You: " : "") + cleaned,
                when: formatter.localizedString(for: last.sentAt, relativeTo: Date()),
                draftReady: (try? store.draftRecord(forThread: card.threadID))?.isAuto == true,
                lastInboundQuestion: last.isFromMe ? nil : {
                    let q = SnippetCleaner.clean(last.text, maxLength: 90)
                    return q.isEmpty ? nil : q
                }())
        }
        queueRowMeta = meta
    }

    /// Trailing-edge coalescer for reload(): bursts (per-message inbound
    /// during a backfill) collapse into at most ~3 reloads/second.
    private var reloadPending = false
    private var lastReloadAt = Date.distantPast
    func reloadSoon() {
        if Date().timeIntervalSince(lastReloadAt) > 0.35 { reload(); return }
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.reloadPending = false
            self?.reload()
        }
    }

    func reload() {
        lastReloadAt = Date()
        let snoozed = (try? store.snoozedThreadIDs()) ?? []
        // Load ALL threads (the default 500 cap silently dropped older threads —
        // e.g. Gmail behind hundreds of iMessage threads — so their platform chip
        // never appeared and the inbox filter looked broken).
        threads = ((try? store.threads(limit: 20000)) ?? []).filter { !snoozed.contains($0.id) }
        if demoMode { threads = DemoScope.trim(threads) }
        projects = (try? store.activeProjects()) ?? []
        messageCountByPlatform = Dictionary(uniqueKeysWithValues: Platform.allCases.map {
            ($0, (try? store.messageCount(platform: $0)) ?? 0)
        })
        // Persisted public profiles, loaded BEFORE people are built so list
        // subtitles + the Ask directory read them with zero network. Fetches
        // stay on-view only — no post-sync stampede.
        enrichmentByPerson = Dictionary(uniqueKeysWithValues:
            ((try? store.enrichments()) ?? []).map { ($0.personID, $0) })

        // Follow-up reminders: answered ones auto-clear inside activeFollowups;
        // scope the rest to visible threads and split due vs pending.
        let visibleThreadIDs = Set(threads.map(\.id))
        let followups = ((try? store.activeFollowups()) ?? [])
            .filter { visibleThreadIDs.contains($0.threadID) }
        dueFollowups = followups.filter { $0.due <= Date() }
        pendingFollowups = followups.filter { $0.due > Date() }
        // Rebuilding the identity graph is an O(n) contacts scan + name-similarity
        // pass — far too heavy to run on every reload (reload fires on every sync
        // tick + import-progress update). Only rebuild when contacts actually
        // changed, or when a merge/reject explicitly asks for it.
        let contactCount = (try? store.contactCount()) ?? 0
        if forceGraphRebuild || contactCount != lastGraphContactCount {
            mergeSuggestions = (try? store.rebuildIdentityGraph()) ?? []
            lastGraphContactCount = contactCount
            forceGraphRebuild = false
        }
        let allSnapshots = buildSnapshots()
        statusByThread = Dictionary(allSnapshots.map { ($0.threadID, TextingStatus.derive($0)) },
                                    uniquingKeysWith: { a, _ in a })
        // Remember each thread's human verdict so the inbox can filter live.
        humanByThread = Dictionary(allSnapshots.map { ($0.threadID, $0.isLikelyHuman) },
                                   uniquingKeysWith: { a, _ in a })
        nonHumanReasonByThread = Dictionary(
            allSnapshots.compactMap { s in s.nonHumanReason.map { (s.threadID, $0) } },
            uniquingKeysWith: { a, _ in a })
        hiddenNonHumanCount = allSnapshots.filter { !$0.isLikelyHuman }.count
        // People, Today, and the queue are about real conversations — default to
        // humans only; "Show all" opens the automated ones too. Nothing is ever
        // deleted; this is a view filter over the same stored data.
        let snapshots = showNonHuman ? allSnapshots : allSnapshots.filter { $0.isLikelyHuman }
        queue = MorningQueue.build(snapshots: snapshots, projects: projects)
        rebuildQueueRowMeta()
        people = buildPeople(snapshots: snapshots)

        // Today-header pulse.
        newInbound24h = (try? store.inboundMessageCount(since: Date().addingTimeInterval(-86_400))) ?? 0
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        activeThreads7d = threads.filter { ($0.lastMessageAt ?? .distantPast) >= weekAgo }.count

        // Dock badge = conversations that owe a reply (so the app is useful when
        // its window is closed — table stakes for a Mac messenger).
        let owed = queue.filter { $0.kind == .reply }.count
        NSApplication.shared.dockTile.badgeLabel = owed > 0 ? "\(owed)" : nil

        // Signal every view that the store changed (wrapping add — never traps).
        dataVersion &+= 1
    }

    // MARK: - Send (dynamic routing)

    /// Send an approved message. Routing:
    ///  - iMessage → local AppleScript send.
    ///  - a platform with a LIVE backend connection → send through the backend
    ///    (returns the real message), then ingest the echo.
    ///  - else → false (caller copies / inserts).
    @discardableResult
    func send(_ text: String, platform: Platform, target: String) async -> Bool {
        if platform == .imessage {
            do { try await IMessageSender().send(text, to: target) }
            catch { return false }
            // The AppleScript send returns before Messages commits the row to
            // chat.db, and we can't know the guid it'll get — so an optimistic
            // insert would DUPLICATE against the real polled row. Instead pull the
            // real row in (idempotent) a few times over ~2.5s; the poll that
            // catches it reloads the UI. Non-blocking so send() returns at once.
            Task { [weak self] in await self?.ingestSentIMessage() }
            return true
        }
        guard connections.canDirectSend(platform), !target.isEmpty else { return false }
        do {
            let message = try await backend.send(platform: platform, platformThreadID: target, text: text)
            let normalized = BackendBatchNormalizer.normalize(
                WireBatch(contacts: [], threads: [], messages: [message], cursor: "", hasMore: false))
            for m in normalized.batch.messages { _ = try? store.ingest(m) }
            reload()
            // A successful live send is a good moment to flush anything queued.
            await drainSendQueue()
            return true
        } catch let BackendClient.BackendError.badStatus(code) where code >= 400 && code < 500 {
            // Provider REJECTED it (bad thread, outside session window, revoked
            // token). Not a connectivity problem — don't queue-and-retry forever;
            // surface it so the user can fix it.
            toast = "Couldn't send to \(platform.displayName) — the conversation may not accept messages."
            return false
        } catch {
            // Network/offline → queue for later drain (foreground / sync / next send).
            try? store.enqueueSend(QueuedSend(
                id: nil, platform: platform, platformThreadID: target,
                text: text, queuedAt: Date(), attempts: 0))
            toast = "Offline — queued to send when you're back."
            return false
        }
    }

    /// React to a message with a tapback emoji. Messages.app AppleScript can't
    /// post a real tapback, so this: (1) optimistically stores the user's own
    /// reaction so it shows immediately like iMessage, and (2) for a 1:1 iMessage
    /// thread, best-effort sends the emoji as a normal message so the other person
    /// still gets it — surfaced honestly via a toast.
    func reactToIMessage(target: OsmoMessage, type: String, emoji: String) async {
        let rid = MessageReaction.makeID(targetGuid: target.platformMessageID, reactorKey: "me", type: type)
        try? store.upsertReaction(MessageReaction(
            id: rid, targetMessageID: target.id, reactorContactID: nil,
            reactionType: type, emoji: emoji, isFromMe: true, reactedAt: Date()))
        reload()   // dataVersion bump → the open transcript shows the tapback now

        guard target.platform == .imessage,
              let thread = try? store.thread(id: target.threadID) else { return }
        let others = ((try? store.contacts(inThread: target.threadID)) ?? []).filter { !$0.isMe }
        if !thread.isGroup, let handle = others.first?.handle {
            _ = await send(emoji, platform: .imessage, target: handle)
            toast = "Sent \(emoji) — tapbacks aren't scriptable, so Osmo sent it as a message."
        } else {
            toast = "Reaction saved. (Sending tapbacks to a group isn't supported yet.)"
        }
    }

    /// Pull the just-sent iMessage in from chat.db. Messages commits the row a
    /// beat after AppleScript returns, so poll a few times over ~2.5s; each poll
    /// is idempotent, and the one that ingests the row triggers a reload (which
    /// bumps `dataVersion`, refreshing any open transcript). If every attempt
    /// misses, the normal 3s background loop catches it next cycle.
    private func ingestSentIMessage() async {
        for delayMs in [200, 400, 800, 1500] {
            try? await Task.sleep(for: .milliseconds(delayMs))
            await realtime.pollLocalNow()
        }
        reload()
    }

    func runSearch() {
        // Trimmed: a whitespace-only query must not swap the whole detail pane
        // for a "0 results" takeover (one stray space blanked the entire app).
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchResults = q.isEmpty ? [] : ((try? store.search(q)) ?? [])
    }

    /// Whether a thread reads as a genuine human conversation (defaults true for
    /// anything not yet classified).
    func isHuman(_ threadID: UUID) -> Bool { humanByThread[threadID] ?? true }

    /// Avatar bytes for a person id — for queue/list rows that only have the id.
    func avatarData(forPerson id: UUID?) -> Data? {
        guard let id else { return nil }
        return people.first { $0.id == id }?.avatar
    }

    /// Attention flag for the queue: owe-a-reply compounded by a goal or a due
    /// follow-up (the things that make a miss expensive).
    func isHighPriority(_ threadID: UUID) -> Bool { priorityScore(threadID) >= 60 }

    // MARK: - Conversation briefs (memory jogger + insight per queue card)

    /// Live one-line briefs, keyed by thread. LLM-written when Pro + live keys;
    /// persisted per (thread, last message) so a brief is generated once per new
    /// message, not once per render. Fed from `intelByThread` (the richer pass
    /// that replaced the plain Insight call) — kept as its own dict so views
    /// reading briefs/topics didn't need to change shape.
    @Published private(set) var insightByThread: [UUID: String] = [:]
    /// Kinso-style conversation labels: LLM-written when available, else the
    /// deterministic keyword classifier (computed in buildSnapshots).
    @Published private(set) var llmTopicByThread: [UUID: String] = [:]
    private(set) var deterministicTopicByThread: [UUID: String] = [:]
    /// The full deeper read (urgency/action/question/commitments/tone/temp/
    /// effort/automated) — one completion per thread per new message, same
    /// cadence as the old `insight(_:)` call it replaces.
    @Published private(set) var intelByThread: [UUID: ThreadIntel] = [:]
    /// The instant, no-I/O half of the same layers — computed for every visible
    /// thread on every reload (see `buildSnapshots`).
    @Published private(set) var detIntelByThread: [UUID: DeterministicIntel] = [:]
    private var insightInFlight = Set<UUID>()
    private var insightCache: [String: [String: String]] = AppModel.loadInsights()

    /// The label a row shows — the model's read wins over keywords.
    func topic(forThread threadID: UUID) -> String? {
        llmTopicByThread[threadID] ?? deterministicTopicByThread[threadID]
    }

    /// The line a queue card shows NOW: live/cached LLM brief, else the
    /// deterministic fallback (goal / saved memory / trend) — never blank-generic.
    func insightLine(forThread threadID: UUID) -> String? {
        if let live = insightByThread[threadID] { return live }
        return Insight.fallback(insightContext(forThread: threadID))
    }

    /// The merged per-thread read every UI surface should query: the LLM pass
    /// wins field-by-field where it has an opinion, the deterministic pass
    /// (instant, always present) fills whatever it left blank.
    func intel(forThread threadID: UUID) -> ThreadIntel {
        let llm = intelByThread[threadID]
        let det = detIntelByThread[threadID]
        return ThreadIntel(
            topic: llm?.topic ?? deterministicTopicByThread[threadID],
            brief: llm?.brief,
            urgency: llm?.urgency ?? det?.urgency,
            urgencyReason: llm?.urgencyReason ?? det?.urgencyReason,
            action: llm?.action ?? det?.action,
            openQuestion: llm?.openQuestion ?? det?.openQuestion,
            commitments: llm?.commitments ?? [],
            tone: llm?.tone,
            temperature: llm?.temperature,
            effort: llm?.effort ?? det?.effort,
            automated: llm?.automated)
    }

    /// A concrete date worth nudging the user by, from the deterministic
    /// deadline detector reading the last inbound message — nil when nothing in
    /// the thread implied a deadline.
    func suggestedFollowUpBy(forThread threadID: UUID) -> Date? {
        detIntelByThread[threadID]?.deadline
    }

    /// Kick off (or restore) the LLM intel pass for a card. Cached per
    /// last-message so cost is one completion per thread per new inbound, and
    /// only for Pro on a live key — free/mock stays on the deterministic pass.
    func ensureIntel(forThread threadID: UUID) {
        guard isPro, !isMockMode, !insightInFlight.contains(threadID) else { return }
        guard let last = try? store.lastMessage(inThread: threadID) else { return }
        let key = last.platformMessageID
        if let hit = insightCache[threadID.uuidString], hit["key"] == key {
            restoreIntel(hit, threadID: threadID)
            return
        }
        insightInFlight.insert(threadID)
        let ctx = insightContext(forThread: threadID)
        Task { [weak self] in
            guard let self else { return }
            let result = try? await self.service.threadIntel(ctx)
            await MainActor.run {
                self.insightInFlight.remove(threadID)
                guard let result else { return }
                self.applyIntel(result, key: key, threadID: threadID)
            }
        }
    }

    /// Publish a freshly-generated intel result, persist it (extended cache
    /// keys — old entries missing them just restore topic/brief), and run the
    /// automated feedback loop: if the model just read this thread as a bot/
    /// newsletter that the deterministic classifier missed, drop its stale
    /// cached verdict so the next reload reclassifies with this evidence.
    private func applyIntel(_ result: ThreadIntel, key: String, threadID: UUID) {
        intelByThread[threadID] = result
        if let brief = result.brief, insightByThread[threadID] != brief { insightByThread[threadID] = brief }
        if let topic = result.topic, !topic.isEmpty, llmTopicByThread[threadID] != topic {
            llmTopicByThread[threadID] = topic
        }
        insightCache[threadID.uuidString] = [
            "key": key,
            "text": result.brief ?? "",
            "topic": result.topic ?? "",
            "urgency": result.urgency?.rawValue ?? "",
            "urgencyReason": result.urgencyReason ?? "",
            "action": result.action?.rawValue ?? "",
            "question": result.openQuestion.map { $0 ? "yes" : "no" } ?? "",
            "commitments": result.commitments.joined(separator: "\n"),
            "tone": result.tone ?? "",
            "temp": result.temperature?.rawValue ?? "",
            "effort": result.effort?.rawValue ?? "",
            "automated": result.automated.map { $0 ? "yes" : "no" } ?? "",
        ]
        Self.saveInsights(insightCache)
        if result.automated == true, humanByThread[threadID] == true {
            humanVerdictCache[threadID] = nil
            reload()
        }
    }

    /// Restore a cached intel result. Missing keys (an older, pre-I2 cache
    /// entry) simply decode to nil fields — topic/brief still restore.
    private func restoreIntel(_ hit: [String: String], threadID: UUID) {
        let intel = ThreadIntel(
            topic: hit["topic"].flatMap { $0.isEmpty ? nil : $0 },
            brief: hit["text"].flatMap { $0.isEmpty ? nil : $0 },
            urgency: hit["urgency"].flatMap { IntelUrgency(rawValue: $0) },
            urgencyReason: hit["urgencyReason"].flatMap { $0.isEmpty ? nil : $0 },
            action: hit["action"].flatMap { IntelAction(rawValue: $0) },
            openQuestion: hit["question"].flatMap { $0.isEmpty ? nil : ($0 == "yes") },
            commitments: (hit["commitments"] ?? "").components(separatedBy: "\n").filter { !$0.isEmpty },
            tone: hit["tone"].flatMap { $0.isEmpty ? nil : $0 },
            temperature: hit["temp"].flatMap { IntelTemperature(rawValue: $0) },
            effort: hit["effort"].flatMap { IntelEffort(rawValue: $0) },
            automated: hit["automated"].flatMap { $0.isEmpty ? nil : ($0 == "yes") })
        if intelByThread[threadID] != intel { intelByThread[threadID] = intel }
        if let text = intel.brief, insightByThread[threadID] != text { insightByThread[threadID] = text }
        if let topic = intel.topic, !topic.isEmpty, llmTopicByThread[threadID] != topic {
            llmTopicByThread[threadID] = topic
        }
    }

    private func insightContext(forThread threadID: UUID) -> InsightContext {
        let t = turns(forThread: threadID)
        let now = Date()
        let contacts = (try? store.contacts(inThread: threadID)) ?? []
        let personID = contacts.first?.personID
        let name = (try? store.thread(id: threadID)).flatMap { threadTitle($0, members: contacts) } ?? "them"
        let project = personID.flatMap { pid in projects.first { $0.personID == pid } }
        let memory = personID.flatMap { try? store.memory(forPerson: $0) }
        let verdict = ReachOutVerdict.decide(read: ThreadRead.read(t, now: now),
                                             partner: PartnerProfile.read(t), now: now)
        return InsightContext(
            personName: name,
            goalText: project?.goalText,
            memoryNote: memory?.note.isEmpty == false ? memory?.note : nil,
            trajectoryDriver: Trajectory.read(t, now: now).driver,
            verdictDetail: verdict.detail,
            transcript: t)
    }

    // MARK: - Ask Osmo (grounded Q&A over local data)

    /// One Ask exchange. `isError` marks an answer that's a surfaced failure
    /// (offline, quota, sign-in) so the transcript can render it as a warning
    /// rather than a normal grounded answer.
    struct AskExchange { let q: String; let a: String; var isError: Bool = false }

    /// Question/answer exchanges this session (newest last) + in-flight state.
    @Published private(set) var askExchanges: [AskExchange] = []
    @Published private(set) var askBusy = false

    /// Answer a natural-language question from LOCAL retrieval (FTS snippets +
    /// the people directory) synthesized by the model. Refusal-biased prompt:
    /// if it isn't in the user's data, the answer says so. Mock mode answers
    /// deterministically from local state (no model call, no pro gate).
    func askOsmo(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !askBusy else { return }

        // Keyless/demo: never dead-end — answer honestly from what we can see.
        if isMockMode {
            askExchanges.append(AskExchange(q: q, a: mockAnswer(for: q)))
            return
        }

        guard isPro else { activeSheet = .paywall; return }
        askBusy = true
        let snippets = askSnippets(for: q)
        let ctx = AskContext(question: q, snippets: snippets, people: peopleDirectory(),
                             about: onboardingProfile.promptPreamble)
        Task { [weak self] in
            guard let self else { return }
            do {
                // Hard deadline: a hung request must never wedge askBusy —
                // a stuck true disables the input forever ("chat stopped
                // working"), which is strictly worse than an error bubble.
                let answer = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask { try await self.askService.ask(ctx) }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                        throw URLError(.timedOut)
                    }
                    guard let first = try await group.next() else { throw URLError(.timedOut) }
                    group.cancelAll()
                    return first
                }
                await MainActor.run {
                    self.askBusy = false
                    self.askExchanges.append(AskExchange(q: q, a: answer))
                }
            } catch {
                await MainActor.run {
                    self.askBusy = false
                    self.askExchanges.append(AskExchange(q: q, a: Self.askErrorMessage(error), isError: true))
                }
            }
        }
    }

    /// Map an Ask failure to an honest, actionable one-liner.
    private static func askErrorMessage(_ error: Error) -> String {
        switch error {
        case GenerationError.quotaExceeded:
            return "You've used your weekly questions. Upgrade for unlimited."
        case GenerationError.http(401):
            return "Sign-in issue — try reopening Osmo. If it persists, sign out and back in."
        case GenerationError.http(503):
            return "Osmo's AI is briefly unavailable. Try again shortly."
        case GenerationError.network, is URLError:
            return "You appear to be offline. Ask Osmo needs a connection."
        default:
            return "Couldn't reach the model — try again."
        }
    }

    /// Deterministic, honest answers for demo/mock mode — read straight from the
    /// local queue + counts, no model call.
    private func mockAnswer(for question: String) -> String {
        let ql = question.lowercased()
        func names(_ cards: [QueueCard]) -> [String] {
            var seen = Set<String>(); var out: [String] = []
            for n in cards.map(\.personName) where seen.insert(n).inserted { out.append(n) }
            return out
        }
        if ql.contains("waiting") || ql.contains("owe") {
            let n = names(queue.filter { $0.kind == .reply })
            return n.isEmpty ? "Nobody's waiting on a reply right now."
                             : "Waiting on you: \(n.joined(separator: ", "))."
        }
        if ql.contains("overdue") || ql.contains("reach out") {
            let n = names(queue.filter { $0.kind == .reconnect || $0.kind == .goalNudge })
            return n.isEmpty ? "You're not overdue to reach out to anyone right now."
                             : "Worth reaching out to: \(n.joined(separator: ", "))."
        }
        let convos = threads.count, ppl = people.count
        return "Here's what I can see from your messages: \(convos) conversation\(convos == 1 ? "" : "s") across \(ppl) \(ppl == 1 ? "person" : "people"). Connect the AI proxy for deeper answers."
    }

    /// One compact line per person — lets "who do I know…" questions work even
    /// when full-text search can't find anything.
    /// Retrieval for Ask, in three lanes. FTS on the RAW question is useless
    /// for the flagship shape ("what did Niki and I last talk about?") — FTS5
    /// ANDs every token, and no message contains the question's boilerplate.
    /// 1. PERSON lane: names in the question → that person's threads' recent
    ///    messages (the actual conversation, not keyword hits).
    /// 2. KEYWORD lane: FTS over content words only (stopwords stripped).
    /// 3. RECENCY lane: when both are thin, the last few days across top
    ///    threads — "how are my relationships doing" gets real material.
    private func askSnippets(for q: String) -> [String] {
        let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .none
        var seen = Set<UUID>()
        var out: [String] = []

        func add(_ m: OsmoMessage) {
            guard seen.insert(m.id).inserted else { return }
            let members = (try? store.contacts(inThread: m.threadID)) ?? []
            let title = (try? store.thread(id: m.threadID)).map { threadTitle($0, members: members) } ?? "?"
            out.append("[\(m.platform.displayName) · \(title) · \(df.string(from: m.sentAt))] \(m.isFromMe ? "You: " : "")\(String(m.text.prefix(160)))")
        }

        // 1. Person lane.
        let qLower = q.lowercased()
        let mentioned = people.filter { person in
            person.name.lowercased().split(whereSeparator: { !$0.isLetter }).contains { token in
                token.count >= 3 && qLower.contains(token)
            }
        }.prefix(2)
        for person in mentioned {
            for thread in threads(forPerson: person.id).prefix(3) {
                for m in ((try? store.recentMessages(inThread: thread.id, limit: 12)) ?? []) { add(m) }
            }
        }

        // 2. Keyword lane.
        let stop: Set<String> = ["what", "did", "and", "the", "about", "talk", "last", "when",
                                 "who", "how", "are", "was", "were", "with", "have", "has",
                                 "does", "you", "your", "our", "for", "that", "this", "she",
                                 "him", "her", "they", "them", "should", "could", "would",
                                 "tell", "say", "said", "know", "anything", "everything"]
        let keywords = qLower.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 && !stop.contains($0) }
        for kw in keywords.prefix(4) {
            for m in ((try? store.search(kw, limit: 8)) ?? []) { add(m) }
        }

        // 3. Recency lane — only when the specific lanes came back thin.
        if out.count < 8 {
            for card in queue.prefix(4) {
                for m in ((try? store.recentMessages(inThread: card.threadID, limit: 6)) ?? []) { add(m) }
            }
        }
        return Array(out.prefix(60))
    }

    private func peopleDirectory() -> [String] {
        people.prefix(60).map { row in
            var bits = ["\(row.name)",
                        row.platforms.map(\.displayName).joined(separator: "/"),
                        row.status.label]
            // Public identity right after the name — "who do I know at X /
            // in growth?" becomes answerable.
            if let role = enrichmentByPerson[row.id]?.roleLine {
                bits.insert(role, at: 1)
            }
            if let goal = projects.first(where: { $0.personID == row.id })?.goalText, !goal.isEmpty {
                bits.append("goal: \(goal)")
            }
            if let note = try? store.memory(forPerson: row.id).note,
               let first = note.components(separatedBy: .newlines).first, !first.isEmpty {
                bits.append("noted: \(String(first.prefix(80)))")
            }
            return bits.joined(separator: " · ")
        }
    }

    // MARK: - Person enrichment (public profiles: LinkedIn + web)

    @Published private(set) var enrichmentByPerson: [UUID: PersonEnrichment] = [:]
    private var enrichmentInFlight = Set<UUID>()
    /// Persons the server said it has nothing for — don't re-ask this session.
    private var enrichmentEmptyThisSession = Set<UUID>()

    /// Consent gate (Privacy settings). Default ON — the user asked for this
    /// feature explicitly; the toggle is the off-ramp, and clearing is explicit.
    @Published var enrichmentEnabled: Bool =
        (UserDefaults.standard.object(forKey: "enrichmentEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(enrichmentEnabled, forKey: "enrichmentEnabled") }
    }

    /// The Unipile attendee/provider id our LinkedIn contacts already carry —
    /// exactly the {identifier} the profile endpoint wants.
    func linkedinHandle(forPerson personID: UUID) -> String? {
        (try? store.contacts(forPerson: personID))?
            .first { $0.platform == .linkedin && !$0.isMe }?.handle
    }

    /// Fetch (or refresh) the public profile for a person. On-view trigger:
    /// consent gate → real-person guard → freshness/in-flight/empty guards →
    /// backend → persist + publish + re-synthesize the dossier. No Pro gate —
    /// there's no LLM cost here, and mock mode must demo keyless.
    func ensureEnrichment(forPerson personID: UUID, name: String, force: Bool = false) {
        guard enrichmentEnabled, flag("enrichment") else { return }
        // PersonRow ids can be threadIDs for unresolved people — the FK insert
        // would fail, and there's no identity to enrich yet.
        guard (try? store.person(id: personID)) != nil else { return }
        if let existing = enrichmentByPerson[personID], !existing.isStale, !force { return }
        guard !enrichmentInFlight.contains(personID) else { return }
        if enrichmentEmptyThisSession.contains(personID) && !force { return }

        var hints: [String] = []
        if let note = (try? store.memory(forPerson: personID))?.note,
           let first = note.components(separatedBy: .newlines).first(where: { !$0.isEmpty }) {
            hints.append(String(first.prefix(80)))
        }
        if let goal = projects.first(where: { $0.personID == personID })?.goalText, !goal.isEmpty {
            hints.append(String(goal.prefix(80)))
        }
        let request = WireEnrichRequest(name: name,
                                        linkedinHandle: linkedinHandle(forPerson: personID),
                                        hints: hints)
        enrichmentInFlight.insert(personID)
        Task { [weak self] in
            guard let self else { return }
            let wire = try? await self.backend.enrichPerson(request)
            await MainActor.run {
                self.enrichmentInFlight.remove(personID)
                guard let wire else {
                    // 429/5xx/offline: keep whatever's cached; only a manual
                    // refresh earns a visible complaint.
                    if force { self.toast = "Couldn't refresh the profile — try again in a minute." }
                    return
                }
                guard wire.source != "none" else {
                    self.enrichmentEmptyThisSession.insert(personID)
                    return
                }
                let enrichment = PersonEnrichment(
                    personID: personID,
                    headline: wire.profile?.headline,
                    company: wire.profile?.company,
                    title: wire.profile?.title,
                    location: wire.profile?.location,
                    summary: wire.profile?.summary,
                    linkedinURL: wire.profile?.linkedinURL,
                    positions: wire.profile?.positions ?? [],
                    education: wire.profile?.education ?? [],
                    webFacts: wire.webFacts,
                    source: EnrichmentSource(rawValue: wire.source) ?? .web,
                    fetchedAt: wire.fetchedAt)
                try? self.store.upsertEnrichment(enrichment)
                self.enrichmentByPerson[personID] = enrichment
                // Patch the visible row now — the full rebuild waits for reload.
                if let idx = self.people.firstIndex(where: { $0.id == personID }) {
                    self.people[idx].headline = enrichment.roleLine
                }
                // Fresh public context → the dossier deserves a re-synthesis
                // (its cache key includes fetchedAt, so this actually re-runs).
                self.ensureDossier(forPerson: personID, name: name)
            }
        }
    }

    // MARK: - Contact dossiers ("remember every detail")

    @Published private(set) var dossierByPerson: [UUID: Dossier.Result] = [:]
    private var dossierInFlight = Set<UUID>()
    private var dossierCache: [String: [String: String]] = AppModel.loadDossiers()

    /// All threads that include this person (cross-platform, identity graph).
    func threads(forPerson personID: UUID) -> [OsmoThread] {
        threads.filter { thread in
            ((try? store.contacts(inThread: thread.id)) ?? []).contains { $0.personID == personID }
        }
    }

    /// Recent turns for a person merged across their threads, chronological.
    func turns(forPerson personID: UUID) -> [ThreadTurn] {
        threads(forPerson: personID).prefix(4)
            .flatMap { turns(forThread: $0.id, limit: 60) }
            .sorted { ($0.sentAt ?? .distantPast) < ($1.sentAt ?? .distantPast) }
    }

    func dossierContext(forPerson personID: UUID, name: String) -> DossierContext {
        let t = turns(forPerson: personID)
        let platforms = Array(Set(threads(forPerson: personID).map { $0.platform.displayName })).sorted()
        let profile = PartnerProfile.read(t)
        let enrichment = enrichmentByPerson[personID]
        return DossierContext(
            personName: name,
            platforms: platforms,
            goalText: projects.first(where: { $0.personID == personID })?.goalText,
            memoryNote: (try? store.memory(forPerson: personID))?.note,
            styleChips: profile.chips,
            trajectoryDriver: Trajectory.read(t, now: Date()).driver,
            transcript: t,
            headline: enrichment?.headline,
            company: enrichment?.company,
            location: enrichment?.location,
            profileSummary: enrichment?.summary,
            positions: (enrichment?.positions ?? []).map {
                "\($0.title) at \($0.company)" + ($0.period.map { " (\($0))" } ?? "")
            },
            education: (enrichment?.education ?? []).map {
                $0.school + ($0.degree.map { " — \($0)" } ?? "")
            },
            webFacts: (enrichment?.webFacts ?? []).map(\.text))
    }

    /// Generate (or restore) the AI dossier — one completion per person per new
    /// message, cached on disk like the briefs. Free/mock stays on the fallback.
    func ensureDossier(forPerson personID: UUID, name: String) {
        guard isPro, !isMockMode, !dossierInFlight.contains(personID) else { return }
        let latest = threads(forPerson: personID)
            .compactMap { try? store.lastMessage(inThread: $0.id) }
            .max(by: { $0.sentAt < $1.sentAt })
        // A fresh enrichment changes the key too — new public context should
        // regenerate the brief. Old-format entries just miss once, harmlessly.
        let enrichStamp = Int(enrichmentByPerson[personID]?.fetchedAt.timeIntervalSince1970 ?? 0)
        guard let key = latest.map({ $0.platformMessageID + "|" + String(enrichStamp) }) else { return }
        if let hit = dossierCache[personID.uuidString], hit["key"] == key {
            let restored = Dossier.Result(
                about: hit["about"] ?? "",
                remember: (hit["remember"] ?? "").components(separatedBy: "\n").filter { !$0.isEmpty })
            if dossierByPerson[personID] != restored { dossierByPerson[personID] = restored }
            return
        }
        dossierInFlight.insert(personID)
        let ctx = dossierContext(forPerson: personID, name: name)
        Task { [weak self] in
            guard let self else { return }
            let result = try? await self.service.dossier(ctx)
            await MainActor.run {
                self.dossierInFlight.remove(personID)
                guard let result else { return }
                self.dossierByPerson[personID] = result
                self.dossierCache[personID.uuidString] = [
                    "key": key, "about": result.about,
                    "remember": result.remember.joined(separator: "\n"),
                ]
                Self.saveDossiers(self.dossierCache)
            }
        }
    }

    private static func dossiersURL() -> URL { supportDir().appendingPathComponent("dossiers.json") }
    private static func loadDossiers() -> [String: [String: String]] {
        guard let data = try? Data(contentsOf: dossiersURL()),
              let dict = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [:] }
        return dict
    }
    private static func saveDossiers(_ cache: [String: [String: String]]) {
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: dossiersURL(), options: .atomic)
        }
    }

    private static func insightsURL() -> URL { supportDir().appendingPathComponent("insights.json") }
    private static func loadInsights() -> [String: [String: String]] {
        guard let data = try? Data(contentsOf: insightsURL()),
              let dict = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [:] }
        return dict
    }
    private static func saveInsights(_ cache: [String: [String: String]]) {
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: insightsURL(), options: .atomic)
        }
    }

    // MARK: - You (voice profile)

    @Published private(set) var voiceStats = VoiceStats(
        overall: .empty, medianReplySeconds: nil, activeBlock: nil, topPhrases: [], perPlatform: [:])
    /// "How you sound to others" — the same style chips shown for other people
    /// (`PartnerProfile.chips`), computed on the user's own turns via the
    /// identical invert-fromMe trick `VoiceStats.compute` uses internally.
    @Published private(set) var voiceChips: [String] = []
    @Published private(set) var voicePersona: VoicePersona.Result?
    private var voicePersonaInFlight = false
    private var voiceStatsComputedAtDataVersion = -1
    private var voicePersonaCache: [String: String] = AppModel.loadVoicePersonaCache()

    /// Recompute the stats (cheap local reads) — gated on `dataVersion` so
    /// re-visiting the section without new data is free. Called lazily from
    /// `YouView` on appear, never from `reload()` itself.
    func ensureVoiceStats() {
        guard voiceStatsComputedAtDataVersion != dataVersion else { return }
        voiceStatsComputedAtDataVersion = dataVersion
        var byPlatform: [Platform: [ThreadTurn]] = [:]
        // Bounded sample per platform (40 most-recently-active threads, 40
        // messages each) — plenty for a statistical read without touching
        // every thread the user has ever had.
        for (platform, platformThreads) in Dictionary(grouping: threads, by: \.platform) {
            let recent = platformThreads
                .sorted { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
                .prefix(40)
            let turns = recent.flatMap { self.turns(forThread: $0.id, limit: 40) }
                .sorted { ($0.sentAt ?? .distantPast) < ($1.sentAt ?? .distantPast) }
            if !turns.isEmpty { byPlatform[platform] = turns }
        }
        voiceStats = VoiceStats.compute(byPlatform)
        let inverted = byPlatform.values.flatMap { $0 }
            .map { ThreadTurn(fromMe: !$0.fromMe, text: $0.text, sentAt: $0.sentAt) }
        voiceChips = PartnerProfile.read(inverted).chips
    }

    /// One completion per ~250 sent messages (bucketed, cached to disk like
    /// every other AI narrative here). `force` bypasses the bucket cache —
    /// the section's explicit "Refresh" action.
    func ensureVoicePersona(force: Bool = false) {
        guard isPro, !isMockMode, !voicePersonaInFlight else { return }
        let bucket = voiceStats.overall.msgCount / 250
        let key = "bucket-\(bucket)"
        if !force, let cached = voicePersonaCache[key] {
            let restored = VoicePersona.Result(paragraphs: cached.components(separatedBy: "\n\n"))
            if voicePersona != restored { voicePersona = restored }
            return
        }
        voicePersonaInFlight = true
        let stats = voiceStats
        let sampleLines = ((try? store.outboundMessages(limit: 60)) ?? [])
            .map(\.text).filter { !$0.isEmpty }
        Task { [weak self] in
            guard let self else { return }
            let result = try? await self.service.voicePersona(stats: stats, sampleLines: sampleLines)
            await MainActor.run {
                self.voicePersonaInFlight = false
                guard let result else { return }
                self.voicePersona = result
                self.voicePersonaCache[key] = result.paragraphs.joined(separator: "\n\n")
                Self.saveVoicePersonaCache(self.voicePersonaCache)
            }
        }
    }

    private static func voicePersonaCacheURL() -> URL { supportDir().appendingPathComponent("voicePersona.json") }
    private static func loadVoicePersonaCache() -> [String: String] {
        guard let data = try? Data(contentsOf: voicePersonaCacheURL()),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }
    private static func saveVoicePersonaCache(_ cache: [String: String]) {
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: voicePersonaCacheURL(), options: .atomic)
        }
    }

    // MARK: - Timing intelligence for views

    /// Recent turns for a thread, chronological (bounded — view-grade sample).
    func turns(forThread threadID: UUID, limit: Int = 60) -> [ThreadTurn] {
        ((try? store.recentMessages(inThread: threadID, limit: limit)) ?? [])
            .reversed()
            .map { ThreadTurn(fromMe: $0.isFromMe, text: $0.text, sentAt: $0.sentAt) }
    }

    /// The explicit reach-out call for a thread: nudge, give it space, lay back,
    /// or your turn — the same rhythm math the drafts use.
    func reachOutVerdict(forThread threadID: UUID) -> ReachOutVerdict {
        let t = turns(forThread: threadID)
        let now = Date()
        return ReachOutVerdict.decide(read: ThreadRead.read(t, now: now),
                                      partner: PartnerProfile.read(t), now: now)
    }

    /// Arm "nudge me if no reply". `after: nil` = rhythm-based (3× their median
    /// reply time, floored at 1 day) so the reminder lands when silence actually
    /// means something for THIS person.
    func armFollowup(thread threadID: UUID, after interval: TimeInterval?) {
        let due: Date
        if let interval {
            due = Date().addingTimeInterval(interval)
        } else {
            let median = PartnerProfile.read(turns(forThread: threadID)).medianReplySeconds
            due = Date().addingTimeInterval(max((median ?? 86_400) * 3, 86_400))
        }
        try? store.setFollowup(thread: threadID, due: due)
        reload()
        let fmt = RelativeDateTimeFormatter()
        toast = "Osmo will nudge you \(fmt.localizedString(for: due, relativeTo: Date())) if they haven't replied."
    }

    /// Threads to show in the inbox: human-only unless "Show all" is on, through
    /// the fast filters (unanswered / topic), in the selected order. The platform
    /// filter is applied by the view on top of this.
    var humanFilteredThreads: [OsmoThread] {
        var base = showNonHuman ? threads : threads.filter { isHuman($0.id) }
        if unansweredOnly {
            base = InboxFilter.unanswered(base) { self.statusByThread[$0] == .needsReply }
        }
        if let label = topicFilter {
            base = InboxFilter.topic(base, label: label) { self.topic(forThread: $0) }
        }
        if let level = urgencyFilter {
            base = InboxFilter.urgency(base, level: level) { self.intel(forThread: $0).urgency }
        }
        if let kind = actionFilter {
            base = InboxFilter.action(base, kind: kind) { self.intel(forThread: $0).action }
        }
        guard inboxSort == .priority else { return base }
        return base.sorted { priorityScore($0.id) > priorityScore($1.id) }
    }

    /// Topic labels present across visible threads — the filter menu's options.
    var presentTopics: [String] {
        InboxFilter.presentTopics(in: showNonHuman ? threads : threads.filter { isHuman($0.id) }) {
            self.topic(forThread: $0)
        }
    }

    /// Urgency/action levels actually present across visible threads — the
    /// filter menu's options (never offers a filter that would show nothing).
    var presentUrgencies: [IntelUrgency] {
        InboxFilter.presentUrgencies(in: showNonHuman ? threads : threads.filter { isHuman($0.id) }) {
            self.intel(forThread: $0).urgency
        }
    }
    var presentActions: [IntelAction] {
        InboxFilter.presentActions(in: showNonHuman ? threads : threads.filter { isHuman($0.id) }) {
            self.intel(forThread: $0).action
        }
    }

    /// Related conversations for an open thread: same person elsewhere + same topic.
    func relatedThreads(to threadID: UUID) -> [OsmoThread] {
        RelatedThreads.find(for: threadID, in: threads,
                            personOf: { (try? self.store.contacts(inThread: $0))?.first?.personID },
                            topicOf: { self.topic(forThread: $0) })
    }

    /// Attention priority: who needs you first. Owe-a-reply outranks everything;
    /// a due follow-up and an active goal raise the stakes; ties break on recency
    /// via the base ordering's stability.
    private func priorityScore(_ threadID: UUID) -> Int {
        var score: Int
        switch statusByThread[threadID] {
        case .needsReply: score = 50
        case .leftOnRead: score = 40
        case .waiting: score = 20
        case .ghosted: score = 15
        case .quiet: score = 5
        case .sayHi, .none: score = 0
        }
        if dueFollowups.contains(where: { $0.threadID == threadID }) { score += 30 }
        let personID = (try? store.contacts(inThread: threadID))?.first?.personID
        if let personID, projects.contains(where: { $0.personID == personID }) { score += 10 }
        switch intel(forThread: threadID).urgency {
        case .some(.overdue): score += 25
        case .some(.today): score += 15
        case .some(.soon): score += 5
        case .some(.none), .none: break
        }
        return score
    }

    // MARK: - Snapshots

    /// Avatar for a person/thread row, from the first contact that has a photo.
    private var avatarByKey: [UUID: Data] = [:]
    /// Cached human/automated verdict per thread, invalidated when its last
    /// message changes. Big imports reload the whole snapshot set every ~0.5s;
    /// without this, every reload re-samples every thread's messages (an extra DB
    /// round-trip each) even though almost nothing changed between ticks.
    private var humanVerdictCache: [UUID: (stamp: Date?, human: Bool, reason: String?, topic: String?, version: Int)] = [:]

    private func buildSnapshots() -> [ThreadSnapshot] {
        avatarByKey = [:]
        var newDetIntel: [UUID: DeterministicIntel] = [:]
        // Normalized handles the user has ever sent TO — lets the classifier
        // treat a one-way inbound from someone you've messaged as human.
        let outboundHandles = (try? store.outboundCounterpartyHandles()) ?? []
        let snapshots = threads.compactMap { thread -> ThreadSnapshot? in
            guard let last = try? store.lastMessage(inThread: thread.id) else { return nil }
            let contacts = (try? store.contacts(inThread: thread.id)) ?? []
            let personID = contacts.first?.personID
            // PERSON name first for 1:1s — an email thread's title is its
            // SUBJECT, and "ceiling tiles is waiting on you" is not a person.
            // Groups keep the title (the group's name IS the identity).
            let personLabel = contacts.first?.displayLabel
            let titleLabel = thread.title?.isEmpty == false ? thread.title : nil
            let name = (thread.isGroup ? (titleLabel ?? personLabel)
                                       : (personLabel ?? titleLabel)) ?? "New conversation"
            // Cache an avatar under the person/thread key for buildPeople.
            if let avatar = contacts.first(where: { $0.avatarData != nil })?.avatarData {
                avatarByKey[personID ?? thread.id] = avatar
            }
            // The deterministic Action/Time read — instant, no I/O, recomputed
            // every reload (it's a couple of regex scans over one message).
            newDetIntel[thread.id] = ThreadSignals.read(
                theirLastText: last.isFromMe ? nil : last.text,
                lastFromMe: last.isFromMe, lastMessageAt: last.sentAt)
            // Is this a genuine person, or an OTP bot / marketing blast / no-reply
            // notification? Classify from a bounded recent-message sample — but
            // reuse the cached verdict when the thread hasn't changed since. A
            // server-side automated hint flipping true without the cached
            // verdict having caught it (D1) is re-checked even on a stamp hit —
            // the LLM-driven feedback loop invalidates the cache entry outright.
            let human: Bool, reason: String?
            if let cached = humanVerdictCache[thread.id], cached.stamp == last.sentAt,
               cached.version == HumanThreadClassifier.version,
               !(thread.automatedHint && cached.human) {
                human = cached.human; reason = cached.reason
                deterministicTopicByThread[thread.id] = cached.topic
            } else {
                let recent = (try? store.recentMessages(inThread: thread.id, limit: 12)) ?? []
                let others = contacts.filter { !$0.isMe }
                let verdict = HumanThreadClassifier.classify(.init(
                    platform: thread.platform,
                    isGroup: thread.isGroup,
                    counterpartyHandles: others.map(\.handle),
                    counterpartyNames: others.compactMap { $0.displayName }.filter { !$0.isEmpty },
                    hasResolvedPerson: others.contains { $0.personID != nil },
                    userReplied: recent.contains { $0.isFromMe },
                    inboundTexts: recent.filter { !$0.isFromMe }.map(\.text),
                    inboundCount: recent.filter { !$0.isFromMe }.count,
                    serverAutomatedHint: thread.automatedHint,
                    llmSaysAutomated: intelByThread[thread.id]?.automated,
                    subjectOrTitle: thread.title,
                    userEverMessagedSender: others.contains {
                        outboundHandles.contains(HandleNormalizer.normalize($0.handle).value)
                    }))
                human = verdict.isLikelyHuman; reason = verdict.reason
                // Same sample powers the Kinso-style topic label — free.
                let topic = TopicClassifier.classify(recent.map(\.text))
                deterministicTopicByThread[thread.id] = topic
                humanVerdictCache[thread.id] = (last.sentAt, human, reason, topic, HumanThreadClassifier.version)
            }
            return ThreadSnapshot(
                threadID: thread.id, personID: personID, personName: name,
                platform: thread.platform, isEmpty: false,
                lastFromMe: last.isFromMe, lastMessageAt: last.sentAt,
                myLastReadByThem: last.isFromMe ? last.readAt : nil,
                theirLastText: last.isFromMe ? nil : last.text,
                isLikelyHuman: human, nonHumanReason: reason)
        }
        detIntelByThread = newDetIntel
        return snapshots
    }

    private func buildPeople(snapshots: [ThreadSnapshot]) -> [PersonRow] {
        var rows: [UUID: PersonRow] = [:]
        for s in snapshots {
            let status = TextingStatus.derive(s)
            let key = s.personID ?? s.threadID
            if var existing = rows[key] {
                if rank(status) > rank(existing.status) { existing.status = status }
                if !existing.platforms.contains(s.platform) { existing.platforms.append(s.platform) }
                rows[key] = existing
            } else {
                rows[key] = PersonRow(id: key, name: s.personName, avatar: avatarByKey[key],
                                      status: status, platforms: [s.platform],
                                      headline: enrichmentByPerson[key]?.roleLine)
            }
        }
        return rows.values.sorted { rank($0.status) > rank($1.status) }
    }

    private func rank(_ s: TextingStatus) -> Int {
        switch s {
        case .needsReply: return 5
        case .leftOnRead: return 4
        case .waiting: return 3
        case .ghosted: return 2
        case .quiet: return 1
        case .sayHi: return 0
        }
    }

    // MARK: - Paths + persistence

    static func storeURL() -> URL { supportDir().appendingPathComponent("osmo.db") }
    static func configURL() -> URL { supportDir().appendingPathComponent("config.json") }
    static func connectionsURL() -> URL { supportDir().appendingPathComponent("connections.json") }
    static func cursorURL() -> URL { supportDir().appendingPathComponent("cursors.json") }

    private static func openEncrypted(url: URL, key: String?) -> OsmoStore {
        if let s = try? OsmoStore(url: url, passphrase: key) { return s }
        for ext in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ext))
        }
        return (try? OsmoStore(url: url, passphrase: key)) ?? (try! OsmoStore.inMemory())
    }

    static func supportDir() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Osmo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func loadConfig() -> RuntimeConfig {
        guard let data = try? Data(contentsOf: configURL()),
              let cfg = try? JSONDecoder().decode(RuntimeConfig.self, from: data) else {
            return RuntimeConfig()
        }
        return cfg
    }

    static func saveConfig(_ config: RuntimeConfig) {
        if let data = try? JSONEncoder().encode(config) { try? data.write(to: configURL()) }
    }

    // MARK: - Attachment media (lazy fetch + on-disk cache)

    private let mediaStore = MediaStore.appSupport()
    private var mediaFetchInFlight = Set<UUID>()

    /// The best URL to render this attachment's full media RIGHT NOW: an
    /// already-cached file (checked on disk directly, not just the DB's
    /// possibly-stale `localPath`), else nil. iMessage attachments carry a
    /// `localPath` from the moment they're ingested (no fetch needed — the
    /// file is already local); everything else is nil until `ensureMediaFetched`
    /// lands it in `mediaStore`.
    func cachedMediaURL(for attachment: OsmoAttachment) -> URL? {
        if let localPath = attachment.localPath, FileManager.default.fileExists(atPath: localPath) {
            return URL(fileURLWithPath: localPath)
        }
        return mediaStore.existingPath(id: attachment.id, ext: fileExtension(for: attachment))
    }

    /// Kick off the lazy fetch for one attachment's full bytes through the
    /// backend's media proxy, then persist the cache path (a device-local
    /// write — see `cacheAttachmentMedia`). A no-op when already cached, when
    /// there's no remote to fetch from (an iMessage file with a known local
    /// path — even if iCloud has since evicted it, there is no server copy to
    /// recover it from), or when a fetch for this id is already in flight.
    func ensureMediaFetched(_ attachment: OsmoAttachment, message: OsmoMessage) {
        guard cachedMediaURL(for: attachment) == nil, attachment.localPath == nil,
              let remoteRef = attachment.remoteRef,
              !mediaFetchInFlight.contains(attachment.id) else { return }
        mediaFetchInFlight.insert(attachment.id)
        Task { [weak self] in
            guard let self else { return }
            let data = try? await self.backend.fetchMedia(
                platform: message.platform, messageRef: message.platformMessageID,
                attachmentRef: remoteRef, mime: attachment.mimeType)
            await MainActor.run {
                self.mediaFetchInFlight.remove(attachment.id)
                guard let data else { return }
                let ext = self.fileExtension(for: attachment)
                guard let url = try? self.mediaStore.store(id: attachment.id, ext: ext, data: data) else { return }
                try? self.store.cacheAttachmentMedia(id: attachment.id, localPath: url.path)
            }
        }
    }

    private func fileExtension(for attachment: OsmoAttachment) -> String {
        if let filename = attachment.filename, let dot = filename.lastIndex(of: ".") {
            return String(filename[filename.index(after: dot)...]).lowercased()
        }
        switch attachment.mimeType {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/heic", "image/heif": return "heic"
        case "image/gif": return "gif"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "audio/mpeg": return "mp3"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "application/pdf": return "pdf"
        default: return "bin"
        }
    }

    // MARK: - Data management (Settings → Privacy)

    func exportData() -> Data? { try? store.exportJSON() }

    func deleteAllData() {
        try? store.deleteAllData()
        try? KeychainDeviceToken().clear()
        UserDefaults.standard.removeObject(forKey: "hasOnboarded")
        reload()
        toast = "All local data erased."
    }
}
