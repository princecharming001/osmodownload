import Foundation

/// Osmo's paid packaging as pure, testable data. `Entitlements` owns what a
/// tier is ALLOWED to do (the free meter, trial window); this owns what the
/// plans COST and how they're presented. The `id`s are the product/price
/// identifiers a real payments backend keys on — StoreKit product ids or Stripe
/// price ids — so swapping mock checkout for the real thing is a one-file change.
public enum BillingPeriod: String, Codable, Sendable, CaseIterable {
    case monthly, annual
    /// Price suffix for display ("$24/month").
    public var suffix: String { self == .monthly ? "/month" : "/year" }
    public var label: String { self == .monthly ? "Monthly" : "Annual" }
}

/// One purchasable plan.
public struct BillingPlan: Identifiable, Equatable, Sendable {
    /// Product/price identifier the payments backend charges against.
    public var id: String
    public var name: String
    public var period: BillingPeriod
    /// Display price for the whole period ("$24", "$192").
    public var priceText: String
    /// Integer cents — for comparisons/tests, never string-parsed.
    public var priceCents: Int
    /// The effective monthly cost, shown on annual plans ("$16/mo").
    public var monthlyEquivalent: String?
    /// A savings callout on the discounted plan ("Save 33%").
    public var savingsText: String?

    public init(id: String, name: String, period: BillingPeriod, priceText: String,
                priceCents: Int, monthlyEquivalent: String? = nil, savingsText: String? = nil) {
        self.id = id; self.name = name; self.period = period
        self.priceText = priceText; self.priceCents = priceCents
        self.monthlyEquivalent = monthlyEquivalent; self.savingsText = savingsText
    }

    /// "$24/month" — the headline price line.
    public var perPeriodText: String { "\(priceText)\(period.suffix)" }
}

/// The plan catalog + the feature lists the pricing UI renders.
public enum BillingCatalog {
    public static let proMonthly = BillingPlan(
        id: "com.osmo.pro.monthly", name: "Osmo Pro", period: .monthly,
        priceText: "$24", priceCents: 2400)

    public static let proAnnual = BillingPlan(
        id: "com.osmo.pro.annual", name: "Osmo Pro", period: .annual,
        priceText: "$192", priceCents: 19_200, monthlyEquivalent: "$16/mo", savingsText: "Save 33%")

    /// Every paid plan, in display order.
    public static let paid = [proMonthly, proAnnual]

    /// Pro's checklist — kept short and benefit-first (mirrors the paywall).
    public static let proFeatures: [String] = [
        "Unlimited AI drafts, everywhere",
        "The Read on every person — tonality, tempo, and why",
        "Autodraft replies before you open the thread",
        "Your voice profile + message analysis",
        "Priority model and new features first",
    ]

    /// What Free covers — the honest hook (Osmo is useful before it's paid).
    public static let freeFeatures: [String] = [
        "\(Entitlements.freeDraftsPerWeek) AI drafts a week",
        "Unified inbox + search across every platform",
        "Human-only filtering, media, and deep links",
        "Everything encrypted on your Mac",
    ]

    public static func plan(id: String) -> BillingPlan? { paid.first { $0.id == id } }
    public static func plan(period: BillingPeriod) -> BillingPlan { period == .annual ? proAnnual : proMonthly }
}
