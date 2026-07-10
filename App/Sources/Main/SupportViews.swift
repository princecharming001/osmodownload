import SwiftUI
import AppKit

/// In-app feedback / bug report. Sends the message (+ opt-in diagnostics) to
/// the backend feedback endpoint.
struct FeedbackView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var includeDiagnostics = true

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            HStack {
                Text("Send feedback").font(DS.Typography.title).foregroundStyle(DS.Colors.ink)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .medium)) }
                    .buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
                    .accessibilityIdentifier("feedback.close")
            }
            Text("Bug, idea, or just a note — it goes straight to the team.")
                .font(DS.Typography.body).foregroundStyle(DS.Colors.muted)

            TextEditor(text: $text)
                .font(DS.Typography.body).scrollContentBackground(.hidden)
                .frame(height: 150)
                .padding(DS.Space.s)
                .background(DS.Colors.card, in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                    .stroke(DS.Colors.hairline, lineWidth: 1))

            Toggle(isOn: $includeDiagnostics) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Include diagnostics").font(DS.Typography.captionEm).foregroundStyle(DS.Colors.ink)
                    Text("App version + macOS version. Never your messages.")
                        .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                }
            }
            .toggleStyle(.checkbox)

            HStack {
                Spacer()
                PillButton("Send", icon: "paperplane.fill") {
                    model.submitFeedback(text, includeDiagnostics: includeDiagnostics)
                    dismiss()
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("feedback.send")
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 460)
        .background(DS.Colors.paper)
    }
}

/// First-run consent — the user must accept the Terms + Privacy Policy before
/// using Osmo. Non-dismissable until accepted.
struct LegalConsentView: View {
    var onAccept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Image(systemName: "hand.raised.fill").font(.system(size: 24)).foregroundStyle(DS.Colors.accent)
            Text("Welcome to Osmo").font(DS.Typography.display).foregroundStyle(DS.Colors.ink)
            Text("Before you start, please review and accept our terms. In short: your messages stay encrypted on this Mac, you approve every message Osmo drafts, and you can export or delete your data anytime.")
                .font(DS.Typography.body).foregroundStyle(DS.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.m) {
                Button("Terms of Service") { open("https://osmo.app/terms") }
                    .buttonStyle(.plain).font(DS.Typography.captionEm).foregroundStyle(DS.Colors.accent)
                Button("Privacy Policy") { open("https://osmo.app/privacy") }
                    .buttonStyle(.plain).font(DS.Typography.captionEm).foregroundStyle(DS.Colors.accent)
            }
            HStack {
                Spacer()
                PillButton("I agree & continue", icon: "checkmark") { onAccept() }
                    .accessibilityIdentifier("consent.accept")
            }
        }
        .padding(DS.Space.xxl)
        .frame(width: 460)
        .background(DS.Colors.paper)
    }

    private func open(_ s: String) { if let url = URL(string: s) { NSWorkspace.shared.open(url) } }
}

/// "What's New" — shown once per version bump. Highlights live in the bundled
/// `Changelog`; bump it with each release.
struct WhatsNewView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow("What's new")
                Text("Osmo \(model.appVersion)").font(DS.Typography.display).foregroundStyle(DS.Colors.ink)
            }
            VStack(alignment: .leading, spacing: DS.Space.m) {
                ForEach(Changelog.current, id: \.title) { item in
                    HStack(alignment: .top, spacing: DS.Space.m) {
                        Image(systemName: item.icon).font(.system(size: 15, weight: .medium))
                            .foregroundStyle(DS.Colors.accent).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink)
                            Text(item.detail).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                PillButton("Got it") { model.markWhatsNewSeen(); dismiss() }
                    .accessibilityIdentifier("whatsnew.done")
            }
        }
        .padding(DS.Space.xxl)
        .frame(width: 460)
        .background(DS.Colors.paper)
        .interactiveDismissDisabled(false)
    }
}

/// Release highlights. Update per version.
enum Changelog {
    static let current: [(icon: String, title: String, detail: String)] = [
        ("arrow.triangle.2.circlepath", "Sync that self-heals",
         "Messages keep flowing across restarts and reconnects — no more silent stalls, and connection status now tells the truth."),
        ("bubble.left.and.text.bubble.right", "Ask, fixed",
         "Ask about your conversations and get a real answer from your own data — the demo-mode mix-up is gone."),
        ("macwindow", "Smoother window",
         "Drag from anywhere along the top, no snap-back or stutter, even mid-sync."),
        ("checkmark.shield", "Sturdier everywhere",
         "Dozens of edge cases hardened — odd names, huge inboxes, flaky networks — so it holds up on real data."),
    ]
}

/// A lightweight Help / FAQ. Static answers to the common questions + contact.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let faqs: [(String, String)] = [
        ("Where is my data stored?",
         "Only on this Mac, encrypted at rest. Osmo never uploads your messages — the backend only proxies AI drafting and never stores conversation content."),
        ("How do I summon the pill?",
         "Press ⌥Space anywhere, or start typing in a message field and Osmo appears next to it. You can rebind the shortcut in Settings → Pill & Hotkey."),
        ("What does Pro unlock?",
         "Unlimited AI drafts, the Read on every person, autodraft-on-arrival, your voice profile, and message analysis. Free covers 15 drafts a week."),
        ("How do I connect a platform?",
         "Open Connections and pick a platform — Osmo walks you through a secure hosted sign-in. Your provider tokens stay on the server; the app never sees them."),
        ("How do I cancel?",
         "Plan & Billing → Manage / cancel opens the billing portal. You keep Pro until the period ends."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            HStack {
                Text("Help & FAQ").font(DS.Typography.title).foregroundStyle(DS.Colors.ink)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .medium)) }
                    .buttonStyle(.plain).foregroundStyle(DS.Colors.muted)
                    .accessibilityIdentifier("help.close")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    ForEach(faqs, id: \.0) { q, a in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(q).font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink)
                            Text(a).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack(spacing: DS.Space.m) {
                Button("Documentation") { open("https://osmo.app/help") }
                    .buttonStyle(.plain).font(DS.Typography.captionEm).foregroundStyle(DS.Colors.accent)
                Button("Email support") { open("mailto:hi@osmo.app") }
                    .buttonStyle(.plain).font(DS.Typography.captionEm).foregroundStyle(DS.Colors.accent)
                Spacer()
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 480, height: 520)
        .background(DS.Colors.paper)
    }

    private func open(_ s: String) { if let url = URL(string: s) { NSWorkspace.shared.open(url) } }
}
