import SwiftUI
import OsmoShell

/// The Osmo Pro sheet — shown when the free draft meter runs out, or from any
/// locked surface (the Read card). Sells the pitch, not features: the right
/// words, the right tone, the right moment. Trial is the primary CTA; purchase
/// opens the site (checkout wiring lands with the licensing backend).
struct PaywallView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: DS.Space.xl) {
            VStack(spacing: DS.Space.s) {
                Image(systemName: "sparkles")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(DS.Colors.accent)
                Text("Know exactly what to say")
                    .font(DS.Typography.display).foregroundStyle(DS.Colors.ink)
                Text("Osmo Pro is the drafting brain — unlimited, everywhere, in your voice.")
                    .font(DS.Typography.body).foregroundStyle(DS.Colors.muted)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: DS.Space.m) {
                benefit("infinity", "Unlimited drafts",
                        "Free covers \(Entitlements.freeDraftsPerWeek) a week. Pro never makes you ration the right words.")
                benefit("person.text.rectangle", "The Read on every person",
                        "How they communicate, the tonality to strike, and why — for everyone, not a sample.")
                benefit("clock", "The right moment",
                        "Reply rhythms and quiet-time cues, so a nudge lands as thoughtful — never needy.")
                benefit("lock", "Still yours only",
                        "Everything stays encrypted on your Mac. Pro changes what Osmo does, never where your data lives.")
            }
            .padding(DS.Space.l)
            .background(DS.Colors.card, in: RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))

            VStack(spacing: DS.Space.s) {
                if model.trialAvailable {
                    PillButton("Start 14-day free trial", icon: "sparkles") { model.startTrial() }
                        .accessibilityIdentifier("paywall.trial")
                    Text("Full Pro, no card. Then \(Entitlements.proMonthlyPrice).")
                        .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                } else {
                    PillButton("Get Osmo Pro — \(Entitlements.proMonthlyPrice)", icon: "arrow.up.circle.fill") {
                        model.subscribe(to: BillingCatalog.proMonthly)
                    }
                    .accessibilityIdentifier("paywall.trial")
                    Text("Checkout opens in your browser.")
                        .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                }
                Button("Not now") { dismiss() }
                    .buttonStyle(.plain).font(DS.Typography.captionEm)
                    .foregroundStyle(DS.Colors.muted)
                    .accessibilityIdentifier("paywall.notnow")
            }
        }
        .padding(DS.Space.xxl)
        .frame(width: 440)
        .background(DS.Colors.paper)
    }

    private func benefit(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DS.Colors.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink)
                Text(detail).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
