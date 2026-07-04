import Foundation

/// One opaque, encrypted operation as the server stores it: a monotonic log `seq`
/// and the ciphertext. The server (Supabase/S3 in production) sees nothing else —
/// no table, no id, no timestamp, no plaintext.
public struct EncryptedOp: Equatable, Sendable {
    public var seq: Int64
    public var ciphertext: Data
    public init(seq: Int64, ciphertext: Data) { self.seq = seq; self.ciphertext = ciphertext }
}

/// The remote the sync engine pushes ciphertext to and pulls it from. Append-only
/// log semantics. `InMemoryBlobStore` is the test/dev mock; the real one is a
/// thin Supabase/S3 client added with credentials last.
public protocol BlobStore: Sendable {
    /// Append ciphertext blobs; returns the assigned sequence numbers.
    func append(_ ciphertexts: [Data]) async throws -> [Int64]
    /// Pull ops with seq greater than `after`, in order.
    func pull(after: Int64) async throws -> [EncryptedOp]
}

/// In-memory append-only log — the keyless default so sync works end-to-end in
/// tests and local dev. Actor for safe concurrent access.
public actor InMemoryBlobStore: BlobStore {
    private var log: [EncryptedOp] = []
    private var nextSeq: Int64 = 1

    public init() {}

    public func append(_ ciphertexts: [Data]) async throws -> [Int64] {
        var seqs: [Int64] = []
        for ct in ciphertexts {
            log.append(EncryptedOp(seq: nextSeq, ciphertext: ct))
            seqs.append(nextSeq)
            nextSeq += 1
        }
        return seqs
    }

    public func pull(after: Int64) async throws -> [EncryptedOp] {
        log.filter { $0.seq > after }
    }

    /// Test helper: prove the server holds only opaque ciphertext.
    public func rawBytes() -> [Data] { log.map(\.ciphertext) }
}
