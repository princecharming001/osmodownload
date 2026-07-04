import Foundation

/// One card in the morning ritual: a person to attend to, why, and the kind of
/// message that would help. The app calls the brain to draft the actual opener
/// per card (this engine only decides *who*, *why*, and *what move*).
public struct QueueCard: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case reply          // they're waiting on you
        case leftOnRead     // you're waiting, they read it — a gentle follow-up
        case goalNudge      // an active project is stalling — advance the goal
        case reconnect      // a maintain/reconnect project gone quiet
    }
    public var id: UUID { threadID }
    public var threadID: UUID
    public var personID: UUID?
    public var personName: String
    public var platform: Platform
    public var kind: Kind
    public var status: TextingStatus
    public var reason: String
    /// Intent hint handed to the brain to draft the opener.
    public var suggestedMove: String
    public var priority: Double
    /// The project this card advances, if any.
    public var projectID: UUID?
}

/// Assembles the morning queue: who you owe, who to nudge toward a goal, who's
/// gone quiet on an active project. Pure + testable. End state when empty is
/// "You're clear."
public enum MorningQueue {
    public struct Config: Sendable {
        public var cap: Int
        public var reconnectCadence: TimeInterval   // nudge maintain/reconnect projects past this idle
        public var statusConfig: TextingStatus.Config
        public init(cap: Int = 12, reconnectCadence: TimeInterval = 10 * 86_400,
                    statusConfig: TextingStatus.Config = .init()) {
            self.cap = cap; self.reconnectCadence = reconnectCadence; self.statusConfig = statusConfig
        }
    }

    public static func build(snapshots: [ThreadSnapshot], projects: [Project],
                             now: Date = Date(), config: Config = .init()) -> [QueueCard] {
        // Active projects indexed by person.
        let activeByPerson = Dictionary(grouping: projects.filter { $0.status == .active && !$0.sync.isDeleted },
                                        by: { $0.personID })
        var cards: [QueueCard] = []

        for s in snapshots {
            let status = TextingStatus.derive(s, now: now, config: config.statusConfig)
            let project = s.personID.flatMap { activeByPerson[$0]?.first }
            let hasProject = project != nil
            let idle = s.lastMessageAt.map { now.timeIntervalSince($0) } ?? 0

            switch status {
            case .needsReply:
                cards.append(card(s, .reply, status, project,
                                  reason: "\(firstName(s.personName)) is waiting on you",
                                  move: "reply to their last message",
                                  base: 100, boost: hasProject ? 30 : 0, idle: idle))
            case .leftOnRead:
                cards.append(card(s, .leftOnRead, status, project,
                                  reason: "\(firstName(s.personName)) read it \(ago(idle)) ago — a light nudge could help",
                                  move: "follow up gently, zero guilt",
                                  base: 68, boost: hasProject ? 22 : 0, idle: idle))
            case .waiting, .ghosted, .quiet:
                // Only surface if a project wants forward motion.
                guard let project else { continue }
                let kind: QueueCard.Kind
                let move: String
                let reason: String
                switch project.status == .active ? GoalKind.classify(project.goalText) : .freeform {
                case .maintainCadence, .reconnect:
                    guard idle > config.reconnectCadence else { continue }
                    kind = .reconnect
                    move = "reconnect warmly, no agenda"
                    reason = "It's been \(ago(idle)) with \(firstName(s.personName)) — \(project.goalText)"
                default:
                    // Goal projects: nudge when the ball's been in their court a while
                    // or the thread's stalled.
                    guard idle > config.statusConfig.leftOnRead else { continue }
                    kind = .goalNudge
                    move = "advance the goal: \(project.goalText)"
                    reason = "Move \(firstName(s.personName)) toward: \(project.goalText)"
                }
                cards.append(card(s, kind, status, project, reason: reason, move: move,
                                  base: kind == .goalNudge ? 55 : 42, boost: 0, idle: idle))
            case .sayHi:
                continue
            }
        }

        return Array(cards.sorted { $0.priority > $1.priority }.prefix(config.cap))
    }

    private static func card(_ s: ThreadSnapshot, _ kind: QueueCard.Kind, _ status: TextingStatus,
                             _ project: Project?, reason: String, move: String,
                             base: Double, boost: Double, idle: TimeInterval) -> QueueCard {
        // Slight recency decay so fresher items edge ahead within a tier.
        let recency = max(0, 10 - idle / 86_400)
        return QueueCard(threadID: s.threadID, personID: s.personID, personName: s.personName,
                         platform: s.platform, kind: kind, status: status, reason: reason,
                         suggestedMove: move, priority: base + boost + recency, projectID: project?.id)
    }

    static func firstName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }

    static func ago(_ interval: TimeInterval) -> String {
        let days = Int(interval / 86_400)
        if days >= 1 { return "\(days)d" }
        let hours = Int(interval / 3600)
        if hours >= 1 { return "\(hours)h" }
        return "\(max(1, Int(interval / 60)))m"
    }
}
