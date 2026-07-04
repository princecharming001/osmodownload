import Foundation

/// A single column value in a synced row, JSON-codable and lossless across the
/// scalar types SQLite stores (text/int/double/blob/null). Blobs ride as base64.
public enum SyncScalar: Codable, Equatable, Sendable {
    case text(String)
    case int(Int64)
    case double(Double)
    case blob(Data)
    case null

    enum CodingKeys: String, CodingKey { case t, v }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s): try c.encode("s", forKey: .t); try c.encode(s, forKey: .v)
        case .int(let i): try c.encode("i", forKey: .t); try c.encode(i, forKey: .v)
        case .double(let d): try c.encode("d", forKey: .t); try c.encode(d, forKey: .v)
        case .blob(let b): try c.encode("b", forKey: .t); try c.encode(b.base64EncodedString(), forKey: .v)
        case .null: try c.encode("n", forKey: .t)
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .t) {
        case "s": self = .text(try c.decode(String.self, forKey: .v))
        case "i": self = .int(try c.decode(Int64.self, forKey: .v))
        case "d": self = .double(try c.decode(Double.self, forKey: .v))
        case "b": self = .blob(Data(base64Encoded: try c.decode(String.self, forKey: .v)) ?? Data())
        default: self = .null
        }
    }
}

/// One row's worth of change, ready to encrypt. Carries everything the receiving
/// device needs to apply LWW after decryption — the *server never sees any of
/// this in the clear*.
public struct SyncChange: Codable, Equatable, Sendable {
    public var deviceID: UUID
    public var table: String
    public var id: String
    /// Unix epoch seconds — the LWW clock (compared after decrypt, on-device).
    public var updatedAt: Double
    public var columns: [String: SyncScalar]

    public init(deviceID: UUID, table: String, id: String, updatedAt: Double,
                columns: [String: SyncScalar]) {
        self.deviceID = deviceID; self.table = table; self.id = id
        self.updatedAt = updatedAt; self.columns = columns
    }
}
