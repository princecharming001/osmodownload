import Foundation

/// Per-platform connection lifecycle. The pure reducer is the unit-testable
/// core; ConnectionsManager drives it from SSE events + reconciliation
/// snapshots + local probes.
public enum ConnectionPhase: Codable, Equatable, Sendable {
    case notConnected
    case linking(started: Date)
    case backfilling(progress: Double)
    case live
    case degraded(reason: String)      // provider session dropped → Reconnect CTA
    case paused
    case disconnected

    public var isActive: Bool {
        switch self {
        case .backfilling, .live: return true
        default: return false
        }
    }
}

public enum ConnectionStateMachine {
    public enum Input: Equatable, Sendable {
        /// User tapped Connect; hosted-auth link is being opened.
        case beginLink(now: Date)
        /// SSE `connection.status` (or the same statuses off a snapshot).
        case statusEvent(String)
        case backfillProgress(Double)
        /// Reconciliation: does the backend list this connection, and as what?
        case accountsSnapshot(present: Bool, status: String?)
        /// Linking has been pending too long (wizard abandoned) — give up.
        case linkTimeout(now: Date)
    }

    /// How long a hosted-auth wizard may stay open before we reset to
    /// notConnected (the user can always tap Connect again).
    public static let linkTimeout: TimeInterval = 10 * 60

    public static func reduce(_ phase: ConnectionPhase, _ input: Input) -> ConnectionPhase {
        switch input {
        case .beginLink(let now):
            return .linking(started: now)

        case .statusEvent(let status):
            switch status {
            case "backfilling":
                if case .backfilling(let p) = phase { return .backfilling(progress: p) }
                return .backfilling(progress: 0)
            case "connected":  return .live
            case "degraded":   return .degraded(reason: "Session expired — reconnect to resume syncing.")
            case "paused":     return .paused
            case "disconnected": return .disconnected
            default:           return phase
            }

        case .backfillProgress(let progress):
            switch phase {
            case .backfilling, .linking, .live:
                return progress >= 1 ? phase : .backfilling(progress: progress)
            default:
                return phase
            }

        case .accountsSnapshot(let present, let status):
            if !present {
                // Not on the backend. Keep an in-flight wizard; anything else
                // collapses to notConnected (incl. after a dev-server restart).
                if case .linking = phase { return phase }
                return .notConnected
            }
            return reduce(phase, .statusEvent(status ?? "connected"))

        case .linkTimeout(let now):
            if case .linking(let started) = phase,
               now.timeIntervalSince(started) >= linkTimeout {
                return .notConnected
            }
            return phase
        }
    }
}
