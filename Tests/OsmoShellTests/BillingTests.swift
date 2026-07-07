import Testing
import Foundation
@testable import OsmoShell

@Suite("Billing catalog — pricing invariants")
struct BillingTests {
    @Test("Product ids are unique and stable (a payments backend keys on them)")
    func idsUnique() {
        let ids = BillingCatalog.paid.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(BillingCatalog.plan(id: "com.osmo.pro.monthly") == BillingCatalog.proMonthly)
        #expect(BillingCatalog.plan(id: "nope") == nil)
    }

    @Test("Annual is genuinely cheaper per month than monthly")
    func annualIsCheaperPerMonth() {
        let monthly = BillingCatalog.proMonthly.priceCents
        let annualPerMonth = BillingCatalog.proAnnual.priceCents / 12
        #expect(annualPerMonth < monthly)
    }

    @Test("Annual savings text matches the actual discount")
    func savingsMathIsHonest() {
        let monthlyYear = BillingCatalog.proMonthly.priceCents * 12
        let annual = BillingCatalog.proAnnual.priceCents
        let pct = Int((1 - Double(annual) / Double(monthlyYear)) * 100)
        #expect(pct == 33)
        #expect(BillingCatalog.proAnnual.savingsText == "Save 33%")
    }

    @Test("Period display strings")
    func periodStrings() {
        #expect(BillingCatalog.proMonthly.perPeriodText == "$24/month")
        #expect(BillingCatalog.proAnnual.perPeriodText == "$192/year")
        #expect(BillingCatalog.plan(period: .annual) == BillingCatalog.proAnnual)
    }

    @Test("Feature lists are non-empty and free references the real weekly cap")
    func featureLists() {
        #expect(!BillingCatalog.proFeatures.isEmpty)
        #expect(BillingCatalog.freeFeatures.contains { $0.contains("\(Entitlements.freeDraftsPerWeek)") })
    }
}
