import Foundation

// The Swift side of the wire contract (web/lib/connections/types.ts is the
// canonical shape). The backend speaks PLATFORM-NATIVE IDs; the Mac mints
// deterministic UUIDs in BackendBatchNormalizer. Codable field names match the
// wire exactly — change either side only together.

public struct WireContact: Codable, Equatable, Sendable {
    public var platform: String
    public var handle: String
    public var displayName: String?
    public var avatarUrl: String?
    public var isMe: Bool
    public init(platform: String, handle: String, displayName: String?, avatarUrl: String? = nil, isMe: Bool) {
        self.platform = platform; self.handle = handle
        self.displayName = displayName; self.avatarUrl = avatarUrl; self.isMe = isMe
    }
}

public struct WireThread: Codable, Equatable, Sendable {
    public var platform: String
    public var platformThreadID: String
    public var title: String?
    public var isGroup: Bool
    public var lastMessageAt: Date?
    /// Optional so older servers/rows decode unchanged.
    public var automatedHint: Bool?
    public var providerThreadID: String?
    public init(platform: String, platformThreadID: String, title: String?,
                isGroup: Bool, lastMessageAt: Date?,
                automatedHint: Bool? = nil, providerThreadID: String? = nil) {
        self.platform = platform; self.platformThreadID = platformThreadID
        self.title = title; self.isGroup = isGroup; self.lastMessageAt = lastMessageAt
        self.automatedHint = automatedHint; self.providerThreadID = providerThreadID
    }
}

public struct WireReaction: Codable, Equatable, Sendable {
    public var emoji: String
    public var senderHandle: String?
    public var isFromMe: Bool
    public init(emoji: String, senderHandle: String? = nil, isFromMe: Bool = false) {
        self.emoji = emoji; self.senderHandle = senderHandle; self.isFromMe = isFromMe
    }
}

public struct WireAttachment: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String            // AttachmentKind.rawValue
    public var mimeType: String?
    public var filename: String?
    public var sizeBytes: Int64?
    public var width: Int?
    public var height: Int?
    public var remoteRef: String?
    public var url: String?
    public var title: String?
    public init(id: String, kind: String, mimeType: String? = nil, filename: String? = nil,
                sizeBytes: Int64? = nil, width: Int? = nil, height: Int? = nil,
                remoteRef: String? = nil, url: String? = nil, title: String? = nil) {
        self.id = id; self.kind = kind; self.mimeType = mimeType; self.filename = filename
        self.sizeBytes = sizeBytes; self.width = width; self.height = height
        self.remoteRef = remoteRef; self.url = url; self.title = title
    }
}

// Person-enrichment wire (POST /api/enrich/person). Leaf types
// (EnrichedPosition/EnrichedEducation/WebFact) are the storage model's own —
// shared verbatim so the wire and the store can't drift.

public struct WireEnrichRequest: Codable, Sendable {
    public var name: String
    public var linkedinHandle: String?
    public var hints: [String]
    public init(name: String, linkedinHandle: String?, hints: [String]) {
        self.name = name; self.linkedinHandle = linkedinHandle; self.hints = hints
    }
}

public struct WireEnrichedProfile: Codable, Equatable, Sendable {
    public var name: String?
    public var headline: String?
    public var company: String?
    public var title: String?
    public var location: String?
    public var summary: String?
    public var linkedinURL: String?
    public var positions: [EnrichedPosition]
    public var education: [EnrichedEducation]
}

public struct WireEnrichment: Codable, Equatable, Sendable {
    public var profile: WireEnrichedProfile?
    public var webFacts: [WebFact]
    /// Includes "none" — which the app never persists.
    public var source: String
    public var fetchedAt: Date
}

public struct WireMessage: Codable, Equatable, Sendable {
    public var platform: String
    public var platformMessageID: String
    public var platformThreadID: String
    public var senderHandle: String?
    public var isFromMe: Bool
    public var text: String
    public var sentAt: Date
    public var readAt: Date?
    /// Emoji reactions + reply threading when the provider exposes them —
    /// optional, so older servers/rows decode unchanged.
    public var reactions: [WireReaction]?
    public var replyToMessageID: String?
    /// Media/files/shared-post attachments, when the provider exposes them.
    public var attachments: [WireAttachment]?
    public init(platform: String, platformMessageID: String, platformThreadID: String,
                senderHandle: String?, isFromMe: Bool, text: String, sentAt: Date, readAt: Date?,
                reactions: [WireReaction]? = nil, replyToMessageID: String? = nil,
                attachments: [WireAttachment]? = nil) {
        self.platform = platform; self.platformMessageID = platformMessageID
        self.platformThreadID = platformThreadID; self.senderHandle = senderHandle
        self.isFromMe = isFromMe; self.text = text; self.sentAt = sentAt; self.readAt = readAt
        self.reactions = reactions; self.replyToMessageID = replyToMessageID
        self.attachments = attachments
    }
}

public struct WireBatch: Codable, Equatable, Sendable {
    public var contacts: [WireContact]
    public var threads: [WireThread]
    public var messages: [WireMessage]
    public var cursor: String
    public var hasMore: Bool
    /// Identity of the server's oplog sequence space (changes on server boot/
    /// redeploy). A cursor minted under a different epoch is meaningless — it
    /// can sit past the new stream's seq and silently starve the client.
    public var epoch: String?
    /// The device's current max seq server-side — lets the client detect an
    /// impossible cursor (cursor > maxSeq) even without an epoch change.
    public var maxSeq: Int?
    /// Server-declared gap: the cursor points below the oplog's retained
    /// window (rows were evicted), so this batch is NOT contiguous — restart
    /// from 0 (idempotent) to recover.
    public var reset: Bool?
    /// Oldest seq still retained when the window is truncated.
    public var oldestSeq: Int?
    public init(contacts: [WireContact], threads: [WireThread], messages: [WireMessage],
                cursor: String, hasMore: Bool, epoch: String? = nil, maxSeq: Int? = nil,
                reset: Bool? = nil, oldestSeq: Int? = nil) {
        self.contacts = contacts; self.threads = threads; self.messages = messages
        self.cursor = cursor; self.hasMore = hasMore
        self.epoch = epoch; self.maxSeq = maxSeq
        self.reset = reset; self.oldestSeq = oldestSeq
    }
}

public struct DeviceCredentials: Codable, Equatable, Sendable {
    public var deviceId: String
    public var deviceToken: String
    public var mode: String            // "mock" | "live"
}

/// A server-signed entitlement (verified locally by `EntitlementVerifier`).
public struct WireEntitlement: Codable, Equatable, Sendable {
    public var entitlement: String     // base64url payload
    public var signature: String       // base64url Ed25519 signature
    public init(entitlement: String, signature: String) {
        self.entitlement = entitlement; self.signature = signature
    }
}

/// The checkout URL the app opens to subscribe.
public struct WireCheckout: Codable, Equatable, Sendable {
    public var url: String
    public var mode: String            // "mock" | "stripe-pending"
}

/// The user this device is now linked to (Sign in with Apple).
public struct WireAccountUser: Codable, Equatable, Sendable {
    public var id: String
    public var email: String
    public var displayName: String?
}

/// Response of /api/account/link — the linked user + a fresh signed entitlement
/// that reflects the account's subscription.
public struct WireAccountLink: Codable, Equatable, Sendable {
    public var user: WireAccountUser
    public var entitlement: WireEntitlement
}

/// Remote feature flags + kill-switch.
public struct WireFlags: Codable, Equatable, Sendable {
    public var flags: [String: Bool]
}

/// Service health / incident status.
public struct WireHealth: Codable, Equatable, Sendable {
    public var ok: Bool
    public var status: String        // "operational" | "degraded" | "down"
    public var message: String?
}

public struct ConnectLink: Codable, Equatable, Sendable {
    public var url: String
    public var linkId: String
    public var mode: String            // "mock" | "unipile" | "oauth"
}

public struct ConnectionInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var platform: String
    public var status: String          // linking|backfilling|connected|degraded|paused|disconnected
    public var displayName: String
    public var backfillProgress: Double
    public var createdAt: Date
    /// Sync/liveness stamps — optional so older servers/rows decode unchanged.
    public var lastSyncAt: Date?
    public var lastVerifiedAt: Date?

    public init(id: String, platform: String, status: String, displayName: String,
                backfillProgress: Double, createdAt: Date,
                lastSyncAt: Date? = nil, lastVerifiedAt: Date? = nil) {
        self.id = id; self.platform = platform; self.status = status
        self.displayName = displayName; self.backfillProgress = backfillProgress
        self.createdAt = createdAt
        self.lastSyncAt = lastSyncAt; self.lastVerifiedAt = lastVerifiedAt
    }
}

struct AccountsEnvelope: Codable { var connections: [ConnectionInfo] }
struct SendEnvelope: Codable { var message: WireMessage }

/// Events off the SSE doorbell stream (plus two synthesized by the client's
/// reconnect loop — the server never sends streamOpened/streamClosed).
public enum BackendEvent: Sendable, Equatable {
    case syncDirty(seq: Int64)
    case connectionStatus(platform: String, status: String, connectionId: String)
    case backfillProgress(platform: String, progress: Double)
    case heartbeat
    case streamOpened
    case streamClosed
}

extension BackendEvent {
    /// Decode one SSE `data:` payload. Unknown types → nil (forward compat).
    static func decode(_ json: String) -> BackendEvent? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        switch type {
        case "sync.dirty":
            return .syncDirty(seq: (obj["seq"] as? NSNumber)?.int64Value ?? 0)
        case "connection.status":
            guard let p = obj["platform"] as? String, let s = obj["status"] as? String else { return nil }
            return .connectionStatus(platform: p, status: s,
                                     connectionId: obj["connectionId"] as? String ?? "")
        case "backfill.progress":
            guard let p = obj["platform"] as? String else { return nil }
            return .backfillProgress(platform: p,
                                     progress: (obj["progress"] as? NSNumber)?.doubleValue ?? 0)
        default:
            return nil
        }
    }
}

public extension JSONDecoder {
    /// The wire's date convention: ISO-8601, fractional seconds tolerated.
    static var osmoWire: JSONDecoder {
        let decoder = JSONDecoder()
        let iso = ISO8601DateFormatter()
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            if let date = isoFrac.date(from: s) ?? iso.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath,
                                                    debugDescription: "bad date \(s)"))
        }
        return decoder
    }
}

public extension JSONEncoder {
    static var osmoWire: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
