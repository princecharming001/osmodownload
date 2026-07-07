import SwiftUI
import AppKit
import OsmoShell

/// The pricing + subscription-management surface. Reused in the account sheet
/// and the "Plan" settings tab. Real checkout/management is wired behind
/// `AppModel`'s billing methods; this is purely the presentation + CTAs.
struct PlanBillingView: View {
    @EnvironmentObject var model: AppModel
    @State private var period: BillingPeriod = .annual
    @State private var licenseKey = ""
    @State private var promoCode = ""

    private var isPro: Bool { model.isPro }
    private var proPlan: BillingPlan { BillingCatalog.plan(period: period) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            currentPlanBanner
            periodToggle
            proCard
            freeCard
            accountActions
            growthSection
            testingSection
            Text("Prices in USD. Subscriptions renew automatically until cancelled; manage or cancel anytime. Checkout and management open in your browser.")
                .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Current plan

    private var currentPlanBanner: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: isPro ? "checkmark.seal.fill" : "sparkles")
                .font(.system(size: 18)).foregroundStyle(isPro ? DS.Colors.green : DS.Colors.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("You're on \(model.planName)").font(DS.Typography.bodyEm).foregroundStyle(DS.Colors.ink)
                Text(statusDetail).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
            }
            Spacer()
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isPro ? DS.Colors.green : DS.Colors.accent).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
    }

    private var statusDetail: String {
        if let days = model.trialDaysLeft { return "Trial — \(days) day\(days == 1 ? "" : "s") left, then it renews." }
        if isPro { return "Unlimited drafts, everywhere." }
        if let left = model.draftsRemaining { return "\(left) of \(Entitlements.freeDraftsPerWeek) free drafts left this week." }
        return "Upgrade for unlimited drafts."
    }

    // MARK: Period toggle

    private var periodToggle: some View {
        HStack(spacing: 2) {
            ForEach(BillingPeriod.allCases, id: \.self) { p in
                let selected = period == p
                Button {
                    withAnimation(DS.Motion.standard) { period = p }
                } label: {
                    HStack(spacing: 5) {
                        Text(p.label).font(DS.Typography.captionEm)
                        if p == .annual, let s = BillingCatalog.proAnnual.savingsText {
                            Text(s).font(DS.Typography.eyebrow)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(selected ? Color.white.opacity(0.25) : DS.Colors.green.opacity(0.15),
                                            in: Capsule())
                                .foregroundStyle(selected ? .white : DS.Colors.green)
                        }
                    }
                    .padding(.horizontal, DS.Space.m).padding(.vertical, 6)
                    .foregroundStyle(selected ? .white : DS.Colors.ink)
                    .background(selected ? DS.Colors.ink : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(DS.Colors.chip, in: Capsule())
    }

    // MARK: Plan cards

    private var proCard: some View {
        planCard(
            title: "Osmo Pro",
            price: proPlan.priceText,
            priceSuffix: proPlan.period.suffix,
            sub: proPlan.monthlyEquivalent.map { "\($0) billed annually" },
            features: BillingCatalog.proFeatures,
            highlighted: true,
            current: isPro
        ) {
            if isPro {
                PillButton("Manage subscription", icon: "creditcard") { model.manageSubscription() }
            } else if model.trialAvailable {
                VStack(spacing: DS.Space.xs) {
                    PillButton("Start 14-day free trial", icon: "sparkles") { model.startTrial() }
                    Button("or subscribe now — \(proPlan.perPeriodText)") { model.subscribe(to: proPlan) }
                        .buttonStyle(.plain).font(DS.Typography.captionEm).foregroundStyle(DS.Colors.accent)
                }
            } else {
                PillButton("Subscribe — \(proPlan.perPeriodText)", icon: "arrow.up.circle.fill") {
                    model.subscribe(to: proPlan)
                }
            }
        }
    }

    private var freeCard: some View {
        planCard(
            title: "Free",
            price: "$0",
            priceSuffix: "",
            sub: nil,
            features: BillingCatalog.freeFeatures,
            highlighted: false,
            current: !isPro,
            cta: { EmptyView() }
        )
    }

    @ViewBuilder
    private func planCard<CTA: View>(title: String, price: String, priceSuffix: String,
                                     sub: String?, features: [String], highlighted: Bool,
                                     current: Bool, @ViewBuilder cta: () -> CTA) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(DS.Typography.heading).foregroundStyle(DS.Colors.ink)
                if current {
                    Text("Current").font(DS.Typography.eyebrow)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .foregroundStyle(DS.Colors.muted).background(DS.Colors.chip, in: Capsule())
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(price).font(DS.Typography.title).foregroundStyle(DS.Colors.ink)
                    Text(priceSuffix).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                }
            }
            if let sub {
                Text(sub).font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(features, id: \.self) { f in
                    Label(f, systemImage: "checkmark")
                        .font(DS.Typography.caption)
                        .foregroundStyle(highlighted ? DS.Colors.ink : DS.Colors.muted)
                }
            }
            cta()
        }
        .padding(DS.Space.l)
        .background(DS.Colors.card, in: RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous)
            .stroke(highlighted ? DS.Colors.accent.opacity(0.5) : DS.Colors.hairlineSoft,
                    lineWidth: highlighted ? 1.5 : 1))
    }

    // MARK: Account actions

    @ViewBuilder private var accountActions: some View {
        if !isPro {
            HStack(spacing: DS.Space.s) {
                TextField("Have a license key?", text: $licenseKey)
                    .textFieldStyle(.plain).font(DS.Typography.body)
                    .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
                    .background(DS.Colors.card, in: Capsule())
                    .overlay(Capsule().stroke(DS.Colors.hairline, lineWidth: 1))
                    .onSubmit { redeem() }
                Button("Redeem") { redeem() }
                    .buttonStyle(.plain).font(DS.Typography.captionEm).foregroundStyle(DS.Colors.accent)
                    .disabled(licenseKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        HStack(spacing: DS.Space.l) {
            Button("Restore purchases") { model.restorePurchases() }
                .buttonStyle(.plain).font(DS.Typography.captionEm).foregroundStyle(DS.Colors.accent)
            if isPro {
                Button("Manage / cancel") { model.manageSubscription() }
                    .buttonStyle(.plain).font(DS.Typography.captionEm).foregroundStyle(DS.Colors.muted)
            }
            Spacer()
        }
    }

    private func redeem() {
        model.redeemLicense(licenseKey)
        licenseKey = ""
    }

    // MARK: Referral + promo

    private var growthSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if !isPro {
                HStack(spacing: DS.Space.s) {
                    TextField("Promo or referral code", text: $promoCode)
                        .textFieldStyle(.plain).font(DS.Typography.body)
                        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
                        .background(DS.Colors.card, in: Capsule())
                        .overlay(Capsule().stroke(DS.Colors.hairline, lineWidth: 1))
                        .onSubmit { applyPromo() }
                    Button("Apply") { applyPromo() }
                        .buttonStyle(.plain).font(DS.Typography.captionEm).foregroundStyle(DS.Colors.accent)
                        .disabled(promoCode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            HStack(spacing: DS.Space.s) {
                Image(systemName: "gift").font(.system(size: 11)).foregroundStyle(DS.Colors.accent)
                Text("Refer a friend — you both get 2 free weeks of Pro.")
                    .font(DS.Typography.caption).foregroundStyle(DS.Colors.muted)
                Spacer()
                Button("Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.referralLink, forType: .string)
                    model.toast = "Referral link copied."
                }
                .buttonStyle(.plain).font(DS.Typography.captionEm).foregroundStyle(DS.Colors.accent)
            }
        }
    }

    private func applyPromo() {
        model.redeemPromo(promoCode)
        promoCode = ""
    }

    // MARK: Testing (pre-launch)

    private var testingSection: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "hammer").font(.system(size: 10)).foregroundStyle(DS.Colors.muted)
            Text("Testing").font(DS.Typography.eyebrow).foregroundStyle(DS.Colors.muted)
            Spacer()
            Button("Activate Pro") { model.activateProLocally() }
                .buttonStyle(.plain).font(DS.Typography.eyebrow).foregroundStyle(DS.Colors.accent)
            Button("Reset to Free") { model.resetToFree() }
                .buttonStyle(.plain).font(DS.Typography.eyebrow).foregroundStyle(DS.Colors.muted)
        }
        .padding(.horizontal, DS.Space.s).padding(.vertical, 6)
        .background(DS.Colors.chip.opacity(0.5), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
    }
}
