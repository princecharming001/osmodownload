import Foundation

/// A proposed merge of two contact clusters that isn't certain enough to apply
/// automatically — surfaced to the user for one-tap confirm/reject. Confidence in
/// 0…1.
public struct MergeSuggestion: Equatable, Sendable {
    public var contactIDsA: [UUID]
    public var contactIDsB: [UUID]
    public var displayNameA: String
    public var displayNameB: String
    public var confidence: Double
    public var reason: String
}

/// The result of resolving a set of contacts.
public struct ResolveResult: Equatable, Sendable {
    /// Deterministic clusters (contacts sharing a global phone/email). Each becomes
    /// one Person.
    public var clusters: [[UUID]]
    /// Probabilistic merges to review (name/avatar similarity across clusters).
    public var suggestions: [MergeSuggestion]
}

/// Resolves the identity graph from contacts. Deterministic joins on global
/// identifiers auto-cluster; ambiguous name/avatar matches become review
/// suggestions. Pure + unit-tested. Never silently merges a low-confidence match —
/// that's the "never silently merge" requirement.
public enum IdentityResolver {
    /// Above this name/avatar similarity we *suggest* a merge (never auto-apply).
    public static let suggestThreshold = 0.82

    public static func resolve(_ contacts: [OsmoContact]) -> ResolveResult {
        let live = contacts.filter { !$0.sync.isDeleted && !$0.isMe }

        // Union-Find over contacts sharing a global (phone/email) key.
        var parent: [UUID: UUID] = [:]
        for c in live { parent[c.id] = c.id }
        func find(_ x: UUID) -> UUID {
            var r = x
            while parent[r] != r { r = parent[r]! }
            var cur = x
            while parent[cur] != r { let next = parent[cur]!; parent[cur] = r; cur = next }
            return r
        }
        func union(_ a: UUID, _ b: UUID) { parent[find(a)] = find(b) }

        var byGlobalKey: [String: UUID] = [:]
        for c in live {
            let norm = HandleNormalizer.normalize(c.handle)
            guard norm.isGlobal else { continue }
            let key = norm.key(platform: c.platform)
            if let seen = byGlobalKey[key] { union(c.id, seen) } else { byGlobalKey[key] = c.id }
        }

        // Collect clusters.
        var groups: [UUID: [UUID]] = [:]
        for c in live { groups[find(c.id), default: []].append(c.id) }
        let clusters = groups.values.map { $0.sorted { $0.uuidString < $1.uuidString } }
            .sorted { $0[0].uuidString < $1[0].uuidString }

        // Probabilistic suggestions: compare display names across distinct clusters.
        let byID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        func name(_ ids: [UUID]) -> String {
            ids.compactMap { byID[$0]?.displayName }.first(where: { !$0.isEmpty }) ?? ""
        }
        var suggestions: [MergeSuggestion] = []
        for i in clusters.indices {
            for j in clusters.indices where j > i {
                let nA = name(clusters[i]), nB = name(clusters[j])
                guard !nA.isEmpty, !nB.isEmpty else { continue }
                let sim = StringSimilarity.ratio(nA, nB)
                // Avatar match is a strong nudge.
                let avatarMatch = avatarEqual(clusters[i], clusters[j], byID)
                let confidence = min(1, avatarMatch ? max(sim, 0.9) : sim)
                if confidence >= suggestThreshold {
                    suggestions.append(MergeSuggestion(
                        contactIDsA: clusters[i], contactIDsB: clusters[j],
                        displayNameA: nA, displayNameB: nB, confidence: confidence,
                        reason: avatarMatch ? "same name + matching photo" : "very similar name"))
                }
            }
        }
        return ResolveResult(clusters: clusters,
                             suggestions: suggestions.sorted { $0.confidence > $1.confidence })
    }

    private static func avatarEqual(_ a: [UUID], _ b: [UUID],
                                    _ byID: [UUID: OsmoContact]) -> Bool {
        let avA = a.compactMap { byID[$0]?.avatarData }
        let avB = b.compactMap { byID[$0]?.avatarData }
        guard let x = avA.first, let y = avB.first else { return false }
        return x == y
    }
}

/// Normalized Levenshtein similarity (0…1). Small, dependency-free.
public enum StringSimilarity {
    public static func ratio(_ a: String, _ b: String) -> Double {
        let s = a.lowercased().trimmingCharacters(in: .whitespaces)
        let t = b.lowercased().trimmingCharacters(in: .whitespaces)
        if s == t { return 1 }
        if s.isEmpty || t.isEmpty { return 0 }
        let dist = levenshtein(Array(s), Array(t))
        return 1 - Double(dist) / Double(max(s.count, t.count))
    }

    static func levenshtein(_ s: [Character], _ t: [Character]) -> Int {
        var prev = Array(0...t.count)
        var cur = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            cur[0] = i
            for j in 1...t.count {
                let cost = s[i-1] == t[j-1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[t.count]
    }
}
