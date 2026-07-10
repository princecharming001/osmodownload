import Foundation

/// Produces the raw model text (three lines) from a composed prompt. The engine
/// stays transport-agnostic: a `MockGenerator` runs everything keyless by default;
/// `ClaudeProxyGenerator` calls the thin server proxy once credentials are in.
public protocol Generator: Sendable {
    func generate(systemCore: String, userTurn: String, count: Int) async throws -> String
}

public enum GenerationError: Error, Equatable, Sendable {
    case notConfigured        // no proxy URL / auth yet — fall back to mock
    case http(Int)
    case empty
    case refusedBySafety(String)
    case network                          // live proxy unreachable (was a raw URLError)
    case quotaExceeded(remaining: Int)    // 429 from the proxy — weekly draft quota hit
}

/// Deterministic, keyless generator. Lets the whole app — onboarding, overlay,
/// morning queue — run and be demoed before any API key exists. It reads the
/// composed prompt to stay on-topic, but is intentionally simple: it is NOT the
/// product's intelligence, just a stand-in so nothing is blocked on credentials.
public struct MockGenerator: Generator {
    public init() {}

    public func generate(systemCore: String, userTurn: String, count: Int) async throws -> String {
        let move = extract(after: "this message is ", from: userTurn) ?? "a message"
        let theirLine = lastThem(in: userTurn)
        let subject = theirLine.map { snippet($0) } ?? "that"

        // Three distinct slants so the parser yields direct/warmer/lighter.
        let direct = "[mock] on \(subject): here's the direct \(move)."
        let warmer = "[mock] on \(subject): a warmer take on the \(move), with a bit more heart."
        let lighter = "[mock] on \(subject): the lighter \(move) 🙂"
        return [direct, warmer, lighter].prefix(max(1, count)).joined(separator: "\n")
    }

    private func extract(after marker: String, from text: String) -> String? {
        guard let r = text.range(of: marker) else { return nil }
        let rest = text[r.upperBound...]
        let line = rest.prefix { $0 != ")" && $0 != "\n" }
        return line.isEmpty ? nil : String(line)
    }

    private func lastThem(in text: String) -> String? {
        text.components(separatedBy: "\n").last { $0.hasPrefix("Them: ") }
            .map { String($0.dropFirst("Them: ".count)) }
    }

    private func snippet(_ s: String) -> String {
        let w = s.split(separator: " ").prefix(4).joined(separator: " ")
        return w.isEmpty ? "that" : w.lowercased()
    }
}
