import Foundation
import GRDB

// The public-profile layer of a person: LinkedIn profile + web mentions,
// fetched via the backend and cached locally. Device-local like thread_draft —
// re-fetchable at any time, so it carries no sync columns and cascades away
// with its person. Leaf types are shared verbatim with the wire structs so the
// two sides can't drift.

public struct EnrichedPosition: Codable, Equatable, Sendable {
    public var title: String
    public var company: String
    public var period: String?
    public init(title: String, company: String, period: String? = nil) {
        self.title = title; self.company = company; self.period = period
    }
}

public struct EnrichedEducation: Codable, Equatable, Sendable {
    public var school: String
    public var degree: String?
    public var period: String?
    public init(school: String, degree: String? = nil, period: String? = nil) {
        self.school = school; self.degree = degree; self.period = period
    }
}

public struct WebFact: Codable, Equatable, Sendable {
    public var text: String
    public var url: String
    public init(text: String, url: String) { self.text = text; self.url = url }
}

public enum EnrichmentSource: String, Codable, Sendable {
    case linkedin, web, both, mock
}

public struct PersonEnrichment: Codable, Equatable, Sendable, Identifiable,
                                FetchableRecord, PersistableRecord {
    public var personID: UUID
    public var headline: String?
    public var company: String?
    public var title: String?
    public var location: String?
    public var summary: String?
    public var linkedinURL: String?
    public var positions: [EnrichedPosition]   // stored as JSON
    public var education: [EnrichedEducation]  // stored as JSON
    public var webFacts: [WebFact]             // stored as JSON
    public var source: EnrichmentSource
    public var fetchedAt: Date

    public static let databaseTableName = "person_enrichment"
    public var id: UUID { personID }

    /// Profiles change slowly; a week-old fetch is due for a quiet refresh.
    public var isStale: Bool {
        Date().timeIntervalSince(fetchedAt) > 7 * 86_400
    }

    /// One compact line for prompts and list rows: headline, else title @ company.
    public var roleLine: String? {
        if let headline, !headline.isEmpty { return headline }
        let role = [title, company].compactMap { $0 }.filter { !$0.isEmpty }
        return role.isEmpty ? nil : role.joined(separator: " at ")
    }

    public init(personID: UUID, headline: String? = nil, company: String? = nil,
                title: String? = nil, location: String? = nil, summary: String? = nil,
                linkedinURL: String? = nil, positions: [EnrichedPosition] = [],
                education: [EnrichedEducation] = [], webFacts: [WebFact] = [],
                source: EnrichmentSource, fetchedAt: Date = Date()) {
        self.personID = personID
        self.headline = headline
        self.company = company
        self.title = title
        self.location = location
        self.summary = summary
        self.linkedinURL = linkedinURL
        self.positions = positions
        self.education = education
        self.webFacts = webFacts
        self.source = source
        self.fetchedAt = fetchedAt
    }
}
