import Foundation

/// Pulls every connected source into the store and rebuilds the identity graph.
/// Local sources (iMessage `chat.db`, WhatsApp msgstore) import directly; the
/// official-API sources (Gmail, Slack) fetch over the network when credentials
/// are present. Degrades gracefully — an unreadable/unconfigured source is
/// skipped with a note, never a crash — and reports a human summary.
public actor SyncCoordinator {
    private let store: OsmoStore
    public var iMessageDBPath: URL
    public var whatsAppDBPath: URL?
    public var credentials: APICredentials
    /// Injectable transport for the API readers (real URLSession by default);
    /// lets the Gmail/Slack fetch path be tested without a network.
    public var transport: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public init(store: OsmoStore,
                iMessageDBPath: URL = SyncCoordinator.defaultChatDBPath,
                whatsAppDBPath: URL? = nil,
                credentials: APICredentials = .init(),
                transport: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil) {
        self.store = store
        self.iMessageDBPath = iMessageDBPath
        self.whatsAppDBPath = whatsAppDBPath
        self.credentials = credentials
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse) ?? HTTPURLResponse())
        }
    }

    public static var defaultChatDBPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db")
    }

    /// Run every available source, rebuild the identity graph, return a summary.
    @discardableResult
    public func syncAll() async -> String {
        var parts: [String] = []

        // iMessage (local, read-only).
        if FileManager.default.isReadableFile(atPath: iMessageDBPath.path) {
            do {
                let s = try IMessageImporter().importAll(from: iMessageDBPath, into: store)
                parts.append("iMessage \(s.newlyIngested) new")
            } catch {
                parts.append("iMessage error")
            }
        } else {
            parts.append("iMessage needs Full Disk Access")
        }

        // WhatsApp (local, read-only) — only when a path is configured.
        if let wa = whatsAppDBPath, FileManager.default.isReadableFile(atPath: wa.path) {
            do {
                let s = try WhatsAppImporter().importAll(from: wa, into: store)
                parts.append("WhatsApp \(s.newlyIngested) new")
            } catch {
                parts.append("WhatsApp error")
            }
        }

        // Gmail + Slack (network) when connected.
        if credentials.gmailReady {
            do { parts.append("Gmail \(try await syncGmail()) new") }
            catch { parts.append("Gmail error") }
        }
        if credentials.slackReady {
            do { parts.append("Slack \(try await syncSlack()) new") }
            catch { parts.append("Slack error") }
        }

        try? store.rebuildIdentityGraph()
        return parts.isEmpty ? "Nothing to sync yet" : parts.joined(separator: " · ")
    }

    // MARK: Gmail (list recent → get metadata → normalize → ingest)

    func syncGmail(maxMessages: Int = 100) async throws -> Int {
        guard let token = credentials.gmailAccessToken,
              let selfEmail = credentials.gmailSelfEmail else { return 0 }
        let ids = try await gmailRecentIDs(token: token, limit: maxMessages)
        var msgs: [GmailMessage] = []
        for id in ids {
            let (data, http) = try await transport(GmailAPI.messageGetRequest(token: token, id: id))
            guard (200..<300).contains(http.statusCode) else { continue }
            if let m = try? JSONDecoder().decode(GmailMessage.self, from: data) { msgs.append(m) }
        }
        let batch = GmailNormalizer.normalize(msgs, selfEmail: selfEmail)
        return ingest(batch)
    }

    private func gmailRecentIDs(token: String, limit: Int) async throws -> [String] {
        var comps = URLComponents(url: GmailAPI.base.appendingPathComponent("messages"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "maxResults", value: String(limit))]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, http) = try await transport(req)
        guard (200..<300).contains(http.statusCode) else { return [] }
        struct ListResp: Decodable { let messages: [Ref]?; struct Ref: Decodable { let id: String } }
        return (try? JSONDecoder().decode(ListResp.self, from: data))?.messages?.map(\.id) ?? []
    }

    // MARK: Slack (list conversations → history → normalize → ingest)

    func syncSlack(maxPerConversation: Int = 200) async throws -> Int {
        guard let token = credentials.slackUserToken,
              let selfID = credentials.slackSelfUserID else { return 0 }
        let channels = try await slackConversationIDs(token: token)
        var convos: [SlackConversation] = []
        for ch in channels {
            let (data, http) = try await transport(
                SlackAPI.conversationsHistoryRequest(token: token, channel: ch.id, limit: maxPerConversation))
            guard (200..<300).contains(http.statusCode) else { continue }
            struct HistResp: Decodable { let messages: [SlackMessage]? }
            let messages = (try? JSONDecoder().decode(HistResp.self, from: data))?.messages ?? []
            convos.append(SlackConversation(id: ch.id, name: ch.name, isGroup: ch.isGroup,
                                            peerUserID: ch.peerUserID, messages: messages))
        }
        return ingest(SlackNormalizer.normalize(convos, selfUserID: selfID))
    }

    private struct SlackChannel { var id: String; var name: String?; var isGroup: Bool; var peerUserID: String? }

    private func slackConversationIDs(token: String) async throws -> [SlackChannel] {
        var comps = URLComponents(url: SlackAPI.base.appendingPathComponent("conversations.list"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "types", value: "im,mpim,private_channel,public_channel"),
                            .init(name: "limit", value: "200")]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, http) = try await transport(req)
        guard (200..<300).contains(http.statusCode) else { return [] }
        struct ListResp: Decodable {
            let channels: [Ch]?
            struct Ch: Decodable { let id: String; let name: String?; let is_im: Bool?; let is_mpim: Bool?; let user: String? }
        }
        return (try? JSONDecoder().decode(ListResp.self, from: data))?.channels?.map {
            SlackChannel(id: $0.id, name: $0.name ?? $0.user, isGroup: $0.is_mpim ?? false,
                         peerUserID: ($0.is_im ?? false) ? $0.user : nil)
        } ?? []
    }

    private func ingest(_ batch: NormalizedBatch) -> Int {
        for c in batch.contacts { try? store.ingest(c) }
        for t in batch.threads { try? store.ingest(t) }
        var n = 0
        for m in batch.messages { if (try? store.ingest(m)) == true { n += 1 } }
        return n
    }
}
