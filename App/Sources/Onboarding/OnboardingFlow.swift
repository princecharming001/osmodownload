import SwiftUI
import KeyboardShortcuts
import AuthenticationServices
import OsmoShell

/// Full-window onboarding takeover on first launch. Builds a context layer about
/// the person (why they're here · how they want to come across · what trips them
/// up), captures their account, sets up permissions, and lands them on their
/// first connection. Steps live in OsmoShell.OnboardingModel (pure); this renders
/// them on the cream ground and writes answers into `model.onboardingProfile`.
struct OnboardingFlow: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var step: OnboardingModel.Step = .welcome
    @State private var permissionTimer: Timer?

    private let flow = OnboardingModel()

    var body: some View {
        ZStack {
            DS.Colors.cream.ignoresSafeArea()
            VStack(spacing: DS.Space.xl) {
                Spacer(minLength: DS.Space.l)
                ScrollView {
                    content
                        .frame(maxWidth: 520)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
                .scrollBounceBehavior(.basedOnSize)
                Spacer(minLength: DS.Space.l)
                footer.frame(maxWidth: 520)
            }
            .padding(DS.Space.xxl)
        }
        .onDisappear { permissionTimer?.invalidate() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:       welcome
        case .privacy:       privacy
        case .goals:         goalsStep
        case .style:         styleStep
        case .struggles:     strugglesStep
        case .signIn:        signInStep
        case .hotkey:        hotkey
        case .permission:    permission
        case .connect:       connect
        case .notifications: notificationsStep
        case .finish:        finish
        }
    }

    // MARK: - Intro

    private var welcome: some View {
        VStack(spacing: DS.Space.l) {
            Image(systemName: "sparkles").font(.system(size: 40)).foregroundStyle(DS.Colors.accent)
            Text("Every conversation, remembered.")
                .font(DS.Typography.display).multilineTextAlignment(.center)
                .foregroundStyle(DS.Colors.ink)
            Text("Osmo reads your messages across every platform, remembers each person, and drafts what to say — in your voice, toward what you want.")
                .font(DS.Typography.body).foregroundStyle(DS.Colors.muted)
                .multilineTextAlignment(.center)
        }
    }

    private var privacy: some View {
        VStack(spacing: DS.Space.l) {
            stepIcon("lock.laptopcomputer")
            Text("Your messages never leave your Mac")
                .font(DS.Typography.displaySmall).foregroundStyle(DS.Colors.ink)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: DS.Space.s) {
                bullet("Your conversations are read and stored locally, encrypted at rest")
                bullet("Only the words you choose to draft are sent — to generate a reply")
                bullet("No message content is uploaded, sold, or used to train anything")
                bullet("Your account just syncs who you are + your plan across devices")
            }
            .padding(DS.Space.m)
            .background(DS.Colors.card, in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
        }
    }

    // MARK: - Context layer (writes model.onboardingProfile)

    private var goalsStep: some View {
        contextScreen(
            icon: "target",
            title: "What brings you to Osmo?",
            subtitle: "Pick what matters — Osmo leads with it. Choose as many as fit.") {
            ForEach(OnboardingProfile.Goal.allCases) { g in
                selectRow(g.label, selected: model.onboardingProfile.goals.contains(g)) {
                    toggle(g, in: \.goals)
                }
            }
        }
    }

    private var styleStep: some View {
        contextScreen(
            icon: "quote.bubble",
            title: "How do you want to come across?",
            subtitle: "How you see yourself — or want to. Osmo also learns your real style from your messages once they're synced.") {
            ForEach(OnboardingProfile.Style.allCases) { s in
                selectRow(s.label, selected: model.onboardingProfile.styles.contains(s)) {
                    toggle(s, in: \.styles)
                }
            }
        }
    }

    private var strugglesStep: some View {
        contextScreen(
            icon: "exclamationmark.bubble",
            title: "Where does messaging trip you up?",
            subtitle: "So Osmo can lead with the right help. Optional.") {
            ForEach(OnboardingProfile.Struggle.allCases) { s in
                selectRow(s.label, selected: model.onboardingProfile.struggles.contains(s)) {
                    toggle(s, in: \.struggles)
                }
            }
        }
    }

    // MARK: - Sign in

    private var signInStep: some View {
        VStack(spacing: DS.Space.l) {
            stepIcon("person.badge.key")
            Text("Save your account").font(DS.Typography.displaySmall).foregroundStyle(DS.Colors.ink)
            if model.account.isSignedIn {
                Label(model.account.email.isEmpty ? "Signed in" : "Signed in as \(model.account.email)",
                      systemImage: "checkmark.circle.fill")
                    .font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.green)
            } else {
                Text("Keep your plan and settings across devices. Your messages still stay on your Mac.")
                    .font(DS.Typography.body).foregroundStyle(DS.Colors.muted).multilineTextAlignment(.center)
                SignInWithAppleButton(.signIn,
                    onRequest: { $0.requestedScopes = [.fullName, .email] },
                    onCompletion: handleApple)
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 44).frame(maxWidth: 320)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
                providerButton("Continue with Google", icon: "g.circle") { openWebLogin(provider: "google") }
                providerButton("Continue with email", icon: "envelope") { openWebLogin() }
                Text("Email & Google finish in your browser, then come back.")
                    .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
            }
        }
    }

    private func providerButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: icon).font(.system(size: 14))
                Text(label).font(DS.Typography.bodyEm)
            }
            .foregroundStyle(DS.Colors.ink)
            .frame(maxWidth: 320).frame(height: 44)
            .background(DS.Colors.card, in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).stroke(DS.Colors.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        guard case .success(let auth) = result,
              let cred = auth.credential as? ASAuthorizationAppleIDCredential else { return }
        let name = [cred.fullName?.givenName, cred.fullName?.familyName].compactMap { $0 }.joined(separator: " ")
        model.completeSignInWithApple(userID: cred.user, email: cred.email,
                                      fullName: name.isEmpty ? nil : name)
    }

    private func openWebLogin(provider: String? = nil) {
        var s = "https://app.leftonread.in/login"
        if let provider { s += "?provider=\(provider)" }   // lets the web page start the right flow
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Hotkey + permission

    private var hotkey: some View {
        VStack(spacing: DS.Space.l) {
            stepIcon("keyboard")
            Text("Your summon key").font(DS.Typography.displaySmall).foregroundStyle(DS.Colors.ink)
            Text("Press this anywhere to bring up Osmo. ⌥Space is a good default — you can change it.")
                .font(DS.Typography.body).foregroundStyle(DS.Colors.muted).multilineTextAlignment(.center)
            KeyboardShortcuts.Recorder(for: .togglePill).padding(.top, DS.Space.s)
        }
    }

    private var permission: some View {
        VStack(spacing: DS.Space.l) {
            stepIcon("lock.shield")
            Text("One permission").font(DS.Typography.displaySmall).foregroundStyle(DS.Colors.ink)
            Text("Accessibility lets the pill appear when you're writing — it reads only the field you're typing in.")
                .font(DS.Typography.body).foregroundStyle(DS.Colors.muted).multilineTextAlignment(.center)
            if AXPermission.isTrusted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.green)
            } else {
                PillButton("Open System Settings") {
                    AXPermission.promptIfNeeded(); startPermissionPoll()
                }
            }
        }
        .onAppear { startPermissionPoll() }
    }

    // MARK: - Connect (gated on sign-in per the "require before connecting" rule)

    private var connect: some View {
        VStack(spacing: DS.Space.l) {
            stepIcon("link")
            Text("Bring your conversations").font(DS.Typography.displaySmall).foregroundStyle(DS.Colors.ink)
            Text("Connect a platform and Osmo pulls your history + keeps it live. iMessage stays on your Mac; the rest connect in one click.")
                .font(DS.Typography.body).foregroundStyle(DS.Colors.muted).multilineTextAlignment(.center)
            if model.account.isSignedIn {
                // The step's purpose → the visually-dominant (filled) action, so the
                // footer "Continue" reads as the secondary "I'll connect later" path.
                PillButton("Connect a platform") {
                    hasOnboarded = true; model.section = .connections
                }
            } else {
                PillButton("Sign in to connect") {
                    withAnimation(DS.Motion.expoOut) { flow.goTo(.signIn); step = .signIn }
                }
                Text("Connecting needs an account so your data is yours across devices.")
                    .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
            }
        }
    }

    // MARK: - Notifications

    private var notificationsStep: some View {
        VStack(spacing: DS.Space.l) {
            stepIcon("bell.badge")
            Text("Nudges when it matters").font(DS.Typography.displaySmall).foregroundStyle(DS.Colors.ink)
            Text("Osmo can remind you when someone's waiting on a reply — never spam, just the people who matter.")
                .font(DS.Typography.body).foregroundStyle(DS.Colors.muted).multilineTextAlignment(.center)
            if model.notifier.authorized {
                Label("Notifications on", systemImage: "checkmark.circle.fill")
                    .font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.green)
            } else {
                PillButton("Turn on reminders") { Task { await model.notifier.requestAuthorization() } }
            }
        }
    }

    private var finish: some View {
        VStack(spacing: DS.Space.l) {
            stepIcon("checkmark.circle")
            Text("You're set").font(DS.Typography.displaySmall).foregroundStyle(DS.Colors.ink)
            Text("Osmo lives in your menu bar. Press ⌥Space anywhere, or it'll appear on its own when you start writing a message.")
                .font(DS.Typography.body).foregroundStyle(DS.Colors.muted).multilineTextAlignment(.center)
            Button {
                if let url = URL(string: model.referralLink) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    model.toast = "Invite link copied"
                }
            } label: {
                Label("Copy an invite link for a friend", systemImage: "gift")
                    .font(DS.Typography.captionEm).foregroundStyle(DS.Colors.accent)
            }.buttonStyle(.plain)
        }
    }

    // MARK: - Context screen scaffold + selectable rows

    private func contextScreen<Rows: View>(
        icon: String, title: String, subtitle: String,
        @ViewBuilder rows: () -> Rows) -> some View {
        VStack(spacing: DS.Space.l) {
            stepIcon(icon)
            Text(title).font(DS.Typography.displaySmall).foregroundStyle(DS.Colors.ink)
                .multilineTextAlignment(.center)
            Text(subtitle).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                .multilineTextAlignment(.center)
            VStack(spacing: DS.Space.s) { rows() }
        }
    }

    private func selectRow(_ label: String, selected: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16)).foregroundStyle(selected ? DS.Colors.accent : DS.Colors.muted)
                Text(label).font(DS.Typography.body).foregroundStyle(DS.Colors.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? DS.Colors.accent.opacity(0.08) : DS.Colors.card,
                        in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .stroke(selected ? DS.Colors.accent.opacity(0.5) : DS.Colors.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Toggle membership in one of the profile's Sets and persist (value-type
    /// mutation reassigns the struct → @Published didSet saves).
    private func toggle<T: Hashable>(_ item: T, in keyPath: WritableKeyPath<OnboardingProfile, Set<T>>) {
        withAnimation(DS.Motion.standard) {
            if model.onboardingProfile[keyPath: keyPath].contains(item) {
                model.onboardingProfile[keyPath: keyPath].remove(item)
            } else {
                model.onboardingProfile[keyPath: keyPath].insert(item)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { withAnimation(DS.Motion.expoOut) { flow.back(); step = flow.step } }
                    .buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
            }
            Spacer()
            ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { s in
                Circle().fill(s == step ? DS.Colors.accent : DS.Colors.hairline)
                    .frame(width: 5, height: 5)
            }
            Spacer()
            HStack(spacing: DS.Space.m) {
                if step.isSkippable {
                    Button("Skip") { advance(skip: true) }
                        .buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
                }
                PillButton(step == .finish ? "Start using Osmo" : "Continue") {
                    if step == .finish { hasOnboarded = true } else { advance(skip: false) }
                }
            }
        }
    }

    // MARK: - Helpers

    private func advance(skip: Bool) {
        permissionTimer?.invalidate(); permissionTimer = nil
        withAnimation(DS.Motion.expoOut) {
            if skip { flow.skip() } else { flow.advance() }
            step = flow.step
            if flow.completed { hasOnboarded = true }
        }
    }

    private func startPermissionPoll() {
        permissionTimer?.invalidate()
        permissionTimer = AXPermission.poll {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if step == .permission { advance(skip: false) }
            }
        }
    }

    private func stepIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 32)).foregroundStyle(DS.Colors.accent)
    }
    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.Colors.accent)
                .padding(.top, 3)
            Text(text).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
            Spacer(minLength: 0)
        }
    }
}
