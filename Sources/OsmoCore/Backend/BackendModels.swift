import Foundation

// The Swift side of the wire contract (web/lib/connections/types.ts is the
// canonical shape). The backend speaks PLATFORM-NATIVE IDs; the Mac mints
// deterministic UUIDs in BackendBatchNormalizer. Codable field names match the
// wire exactly — change either side only together.

public struct WireContact: Codable, Equatable, Sendable {
    public var platform: String
    public var handle: String
    public var displayName: String?
    public var isMe: Bool
    public init(platform: String, handle: String, displayName: String?, isMe: Bool) {
        self.platform = platform; self.handle = handle
        self.displayName = displayName; self.isMe = isMe
    }
}

public struct WireThread: Codable, Equatable, Sendable {
    public var platform: String
    public var platformThreadID: String
    public var title: String?
    public var isGroup: Bool
    public var lastMessageAt: Date?
    public init(platform: String, platformThreadID: String, title: String?,
                isGroup: Bool, lastMessageAt: Date?) {
        self.platform = platform; self.platformThreadID = platformThreadID
        self.title = title; self.isGroup = isGroup; self.lastMessageAt = lastMessageAt
    }
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
    public init(platform: String, platformMessageID: String, platformThreadID: String,
                senderHandle: String?, isFromMe: Bool, text: String, sentAt: Date, readAt: Date?) {
        self.platform = platform; self.platformMessageID = platformMessageID
        self.platformThreadID = platformThreadID; self.senderHandle = senderHandle
        self.isFromMe = isFromMe; self.text = text; self.sentAt = sentAt; self.readAt = readAt
    }
}

public struct WireBatch: Codable, Equatable, Sendable {
    public var contacts: [WireContact]
    public var threads: [WireThread]
    public var messages: [WireMessage]
    public var cursor: String
    public var hasMore: Bool
    public init(contacts: [WireContact], threads: [WireThread], messages: [WireMessage],
                cursor: String, hasMore: Bool) {
        self.contacts = contacts; self.threads = threads; self.messages = messages
        self.cursor = cursor; self.hasMore = hasMore
    }
}

public struct DeviceCredentials: Codable, Equatable, Sendable {
    public var deviceId: String
    public var deviceToken: String
    public var mode: String            // "mock" | "live"
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

    public init(id: String, platform: String, status: String, displayName: String,
                backfillProgress: Double, createdAt: Date) {
        self.id = id; self.platform = platform; self.status = status
        self.displayName = displayName; self.backfillProgress = backfillProgress
        self.createdAt = createdAt
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
