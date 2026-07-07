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

    /// Generic chat/group names that are never a person — without this, a
    /// contact whose displayName ended up being a group's title (a group with
    /// a null real title falling back to a generic label, or a sender
    /// attribution bug elsewhere) spams merge suggestions against every OTHER
    /// contact that also inherited the same generic label. Lowercased.
    public static let genericNameStoplist: Set<String> = [
        "general", "announcements", "random", "team", "boosting posts",
        "notifications", "updates", "new chat", "group", "group chat",
        "everyone", "members", "chat",
    ]

    /// Case-insensitive containment check against the stoplist + whatever
    /// group-thread titles the caller supplied (already lowercased).
    private static func isExcluded(_ name: String, _ excludedNames: Set<String>) -> Bool {
        let lower = name.lowercased().trimmingCharacters(in: .whitespaces)
        return genericNameStoplist.contains(lower) || excludedNames.contains(lower)
    }

    /// A stable, order-independent identifier for a suggested pair of clusters,
    /// built from each cluster's smallest contact id. Deterministic clusters map
    /// to a stable representative (same phone/email ⇒ same contacts ⇒ same min),
    /// so a decision recorded against this key survives rebuilds. Used both when
    /// the user rejects a pair and when we decide whether to re-suggest it.
    public static func pairKey(_ a: [UUID], _ b: [UUID]) -> String {
        let ra = a.min(by: { $0.uuidString < $1.uuidString })?.uuidString ?? ""
        let rb = b.min(by: { $0.uuidString < $1.uuidString })?.uuidString ?? ""
        return ra < rb ? "\(ra)|\(rb)" : "\(rb)|\(ra)"
    }

    /// - Parameters:
    ///   - rejectedPairKeys: `pairKey`s the user has explicitly marked
    ///     "not the same" — never re-suggested.
    ///   - excludedNames: names that are never a person (already lowercased or
    ///     not — compared case-insensitively) — group-chat titles the caller
    ///     supplies, folded in with the static `genericNameStoplist`.
    public static func resolve(_ contacts: [OsmoContact], rejectedPairKeys: Set<String> = [],
                               excludedNames: Set<String> = []) -> ResolveResult {
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
        // PRECOMPUTE per-cluster values ONCE (name, dominant personID, min contact
        // id, first avatar) — recomputing them inside the pair loop made this
        // O(n³) and pegged the CPU on large imports.
        let byID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        func firstName(_ ids: [UUID]) -> String {
            ids.compactMap { byID[$0]?.displayName }.first(where: { !$0.isEmpty }) ?? ""
        }
        // The person a cluster already resolves to (most common non-nil personID).
        // Two clusters that are already the SAME person must never be re-suggested
        // — that was the "merge does nothing" bug: a confirmed merge relinks both
        // clusters to one person, but the old resolver ignored personID.
        func dominantPersonID(_ ids: [UUID]) -> UUID? {
            var counts: [UUID: Int] = [:]
            for id in ids { if let pid = byID[id]?.personID { counts[pid, default: 0] += 1 } }
            return counts.max(by: { $0.value < $1.value })?.key
        }
        let names = clusters.map(firstName)
        let pids = clusters.map(dominantPersonID)
        let reps = clusters.map { $0.min(by: { $0.uuidString < $1.uuidString })?.uuidString ?? "" }
        let avatars = clusters.map { ids in ids.compactMap { byID[$0]?.avatarData }.first }

        // BLOCK by a cheap key so we only compare plausibly-similar names, turning
        // an O(n²) all-pairs Levenshtein sweep into O(n × small bucket). A name
        // similarity ≥ 0.82 needs the strings to share almost every character, so
        // two names that differ in their first two letters are never a real match
        // — bucketing on that prefix drops the comparison count enormously without
        // losing genuine suggestions.
        func blockKey(_ name: String) -> String? {
            let norm = name.lowercased().filter { $0.isLetter || $0.isNumber }
            guard norm.count >= 2 else { return norm.isEmpty ? nil : norm }
            return String(norm.prefix(2))
        }
        var nameBuckets: [String: [Int]] = [:]
        for i in clusters.indices where !names[i].isEmpty {
            if let key = blockKey(names[i]) { nameBuckets[key, default: []].append(i) }
        }
        // Also block by identical avatar, so a shared photo still pairs two people
        // whose names diverge (e.g. "Bob"/"Robert") — that match forces confidence
        // ≥ 0.9, so it must not be lost to name bucketing.
        var avatarBuckets: [Data: [Int]] = [:]
        for i in clusters.indices where !names[i].isEmpty {
            if let av = avatars[i] { avatarBuckets[av, default: []].append(i) }
        }

        // Gather candidate pairs from both blockings, deduped, then score once.
        var candidates = Set<[Int]>()
        for indices in nameBuckets.values where indices.count > 1 {
            for a in indices.indices { for b in (a + 1)..<indices.count {
                candidates.insert([min(indices[a], indices[b]), max(indices[a], indices[b])])
            } }
        }
        for indices in avatarBuckets.values where indices.count > 1 {
            for a in indices.indices { for b in (a + 1)..<indices.count {
                candidates.insert([min(indices[a], indices[b]), max(indices[a], indices[b])])
            } }
        }

        var suggestions: [MergeSuggestion] = []
        for pair in candidates {
            let i = pair[0], j = pair[1]
            // Already one person (a prior confirmed merge) → nothing to review.
            if let pA = pids[i], pA == pids[j] { continue }
            // A group-title (or generic "General"/"Announcements"/…) name is
            // never a person — the root cause of the group-title suggestion
            // spam this guards against.
            if isExcluded(names[i], excludedNames) || isExcluded(names[j], excludedNames) { continue }
            // The user said "not the same" → honor it permanently.
            if !rejectedPairKeys.isEmpty {
                let key = reps[i] < reps[j] ? "\(reps[i])|\(reps[j])" : "\(reps[j])|\(reps[i])"
                if rejectedPairKeys.contains(key) { continue }
            }
            let sim = StringSimilarity.ratio(names[i], names[j])
            let avatarMatch = avatars[i] != nil && avatars[i] == avatars[j]
            let confidence = min(1, avatarMatch ? max(sim, 0.9) : sim)
            if confidence >= suggestThreshold {
                suggestions.append(MergeSuggestion(
                    contactIDsA: clusters[i], contactIDsB: clusters[j],
                    displayNameA: names[i], displayNameB: names[j], confidence: confidence,
                    reason: avatarMatch ? "same name + matching photo" : "very similar name"))
            }
        }
        return ResolveResult(clusters: clusters,
                             suggestions: suggestions.sorted { $0.confidence > $1.confidence })
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
