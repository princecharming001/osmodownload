import SwiftUI
import AppKit
import AuthenticationServices
import OsmoShell

/// The account/profile page — presented as a sheet from the sidebar account
/// row. Two panes: the profile (identity + account actions) and Plan & Billing.
struct ProfileView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Pane: String, CaseIterable, Identifiable { case profile = "Profile", plan = "Plan & Billing"; var id: String { rawValue } }
    @State private var pane: Pane = .profile

    var body: some View {
        VStack(spacing: 0) {
            header
            HairlineDivider()
            ScrollView {
                Group {
                    switch pane {
                    case .profile: AccountPane()
                    case .plan: PlanBillingView()
                    }
                }
                .padding(DS.Space.xl)
            }
        }
        .frame(width: 480, height: 620)
        .background(DS.Colors.paper)
    }

    private var header: some View {
        HStack(spacing: DS.Space.m) {
            HStack(spacing: 2) {
                ForEach(Pane.allCases) { p in
                    let selected = pane == p
                    Button {
                        withAnimation(DS.Motion.standard) { pane = p }
                    } label: {
                        Text(p.rawValue).font(DS.Typography.captionEm)
                            .padding(.horizontal, DS.Space.m).padding(.vertical, 6)
                            .foregroundStyle(selected ? .white : DS.Colors.ink)
                            .background(selected ? DS.Colors.ink : Color.clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(DS.Colors.chip, in: Capsule())
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("profile.close")
        }
        .padding(DS.Space.l)
    }
}

/// Identity + account actions.
private struct AccountPane: View {
    @EnvironmentObject var model: AppModel
    @State private var name = ""
    @State private var email = ""
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            identityHeader
            fields
            accountActions
            support
            dangerZone
            footer
        }
        .onAppear { name = model.account.displayName; email = model.account.email }
        // Feedback/Help are NOT presented as nested sheets here (sheet-over-sheet
        // deadlocks on macOS). Instead they hand off to the single app-level
        // presenter: close this sheet, open theirs.
        .alert("Delete your account?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete everything", role: .destructive) { model.deleteAccount() }
        } message: {
            Text("This permanently deletes your account and every message, person, and setting on this Mac, and cancels any local subscription record. This can't be undone.")
        }
    }

    private var identityHeader: some View {
        HStack(spacing: DS.Space.l) {
            Button { pickAvatar() } label: {
                ZStack(alignment: .bottomTrailing) {
                    AvatarView(name: name.isEmpty ? "You" : name, data: model.account.avatarData, size: 64)
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 16)).foregroundStyle(DS.Colors.accent)
                        .background(Circle().fill(DS.Colors.paper))
                }
            }
            .buttonStyle(.plain)
            .help("Change photo")
            VStack(alignment: .leading, spacing: 3) {
                Text(name.isEmpty ? "Your account" : name)
                    .font(DS.Typography.title).foregroundStyle(DS.Colors.ink)
                HStack(spacing: DS.Space.xs) {
                    Text(model.planName).font(DS.Typography.eyebrow)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .foregroundStyle(model.isPro ? .white : DS.Colors.ink)
                        .background(model.isPro ? DS.Colors.accent : DS.Colors.chip, in: Capsule())
                    Text("Member since \(memberSince)")
                        .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                }
            }
            Spacer()
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            field("Name", text: $name, placeholder: "Your name") { model.updateAccount(displayName: name) }
            field("Email", text: $email, placeholder: "you@example.com") { model.updateAccount(email: email) }
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String,
                       onCommit: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(label)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain).font(DS.Typography.body)
                .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
                .background(DS.Colors.card, in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                    .stroke(DS.Colors.hairline, lineWidth: 1))
                .onSubmit(onCommit)
        }
    }

    private var accountActions: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if model.account.isSignedIn {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 12)).foregroundStyle(DS.Colors.green)
                    Text("Signed in\(model.account.email.isEmpty ? "" : " · \(model.account.email)")")
                        .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                    Spacer()
                    Button("Sign out") { model.signOut() }
                        .buttonStyle(.plain).font(DS.Typography.captionEm).foregroundStyle(DS.Colors.red)
                }
            } else {
                SignInWithAppleButton(.signIn, onRequest: { req in
                    req.requestedScopes = [.fullName, .email]
                }, onCompletion: handleSignIn)
                .signInWithAppleButtonStyle(.black)
                .frame(height: 40)
                .clipShape(Capsule())
                Text("Sign in to sync your profile and subscription across devices.")
                    .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func handleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential else { return }
            let fullName = [cred.fullName?.givenName, cred.fullName?.familyName]
                .compactMap { $0 }.joined(separator: " ")
            model.completeSignInWithApple(userID: cred.user, email: cred.email,
                                          fullName: fullName.isEmpty ? nil : fullName)
        case .failure:
            model.toast = "Sign-in was cancelled or unavailable."
        }
    }

    private var support: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Eyebrow("Support")
            HStack(spacing: DS.Space.l) {
                // Hand off to the single app-level presenter: close this sheet,
                // then open the target a tick later so SwiftUI fully tears down
                // this one first. Never present a sheet from within a sheet.
                Button { model.handoff(to: .feedback) } label: {
                    Label("Send feedback", systemImage: "envelope")
                        .font(DS.Typography.captionEm)
                }.buttonStyle(.plain).foregroundStyle(DS.Colors.accent)
                    .accessibilityIdentifier("profile.feedback")
                Button { model.handoff(to: .help) } label: {
                    Label("Help & FAQ", systemImage: "questionmark.circle")
                        .font(DS.Typography.captionEm)
                }.buttonStyle(.plain).foregroundStyle(DS.Colors.accent)
                    .accessibilityIdentifier("profile.help")
            }
        }
    }

    private var dangerZone: some View {
        Button("Delete account…", role: .destructive) { confirmDelete = true }
            .buttonStyle(.plain).font(DS.Typography.captionEm).foregroundStyle(DS.Colors.red)
    }

    private var footer: some View {
        HStack(spacing: DS.Space.m) {
            Text("Osmo \(appVersion)").font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
            Spacer()
            Button("Terms") { open("https://osmo.app/terms") }
                .buttonStyle(.plain).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
            Button("Privacy") { open("https://osmo.app/privacy") }
                .buttonStyle(.plain).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
        }
    }

    private var memberSince: String {
        let f = DateFormatter(); f.dateFormat = "MMM yyyy"; return f.string(from: model.account.memberSince)
    }
    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    private func open(_ s: String) { if let url = URL(string: s) { NSWorkspace.shared.open(url) } }

    private func pickAvatar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        // `.begin` (non-blocking) — NOT `.runModal()`. Running a blocking AppKit
        // modal session while this view is itself inside a SwiftUI `.sheet`
        // wedges the window's event loop on macOS (a modal-on-modal deadlock).
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let image = NSImage(contentsOf: url) else { return }
            // Downscale to a reasonable avatar size before storing.
            let target = NSSize(width: 256, height: 256)
            let resized = NSImage(size: target)
            resized.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: target))
            resized.unlockFocus()
            if let tiff = resized.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                model.updateAccount(avatar: .some(png))
            }
        }
    }
}
