import Foundation

/// Drives E2EE sync: encrypt local changes → push ciphertext to the BlobStore;
/// pull ciphertext → decrypt → apply with LWW. The server only ever sees opaque
/// blobs. Cursors (push high-water + pull position) are held here; the app
/// persists them across launches (a small follow-up — noted, not blocking).
public actor SyncEngine {
    private let store: OsmoStore
    private let blobStore: BlobStore
    private let crypto: CryptoBox
    private var lastPushedSeq: Int64
    private var pullCursor: Int64

    public init(store: OsmoStore, blobStore: BlobStore, crypto: CryptoBox,
                lastPushedSeq: Int64 = 0, pullCursor: Int64 = 0) {
        self.store = store
        self.blobStore = blobStore
        self.crypto = crypto
        self.lastPushedSeq = lastPushedSeq
        self.pullCursor = pullCursor
    }

    /// Encrypt and push every local change since the last push.
    @discardableResult
    public func push() async throws -> Int {
        let changes = try store.exportChanges(sinceDeviceSeq: lastPushedSeq)
        guard !changes.isEmpty else { return 0 }
        let encoder = JSONEncoder()
        let ciphertexts = try changes.map { try crypto.seal(try encoder.encode($0)) }
        _ = try await blobStore.append(ciphertexts)
        lastPushedSeq = try store.currentDeviceSeq()
        return changes.count
    }

    /// Pull, decrypt, and apply remote changes with LWW.
    @discardableResult
    public func pull() async throws -> Int {
        let ops = try await blobStore.pull(after: pullCursor)
        guard !ops.isEmpty else { return 0 }
        let decoder = JSONDecoder()
        var changes: [SyncChange] = []
        for op in ops {
            let plaintext = try crypto.open(op.ciphertext)
            changes.append(try decoder.decode(SyncChange.self, from: plaintext))
            pullCursor = max(pullCursor, op.seq)
        }
        return try store.applyChanges(changes)
    }

    /// Convenience: push then pull.
    public func sync() async throws {
        try await push()
        try await pull()
    }
}
