import Foundation
import CryptoKit

/// The app's tier, as proven by a server signature. Verified locally against a
/// bundled Ed25519 PUBLIC key — the matching private key lives only on the
/// server, so a user editing the cached entitlement file breaks the signature
/// and silently drops to `.free`. This is what makes the entitlement
/// tamper-resistant (the old editable `entitlements.json` was not).
public enum EntitlementTier: String, Codable, Sendable {
    case free, trial, pro
    public var isPaid: Bool { self == .pro || self == .trial }
}

/// A verified, still-valid entitlement decoded from a signed server payload.
public struct VerifiedEntitlement: Equatable, Sendable {
    public var deviceID: String
    public var tier: EntitlementTier
    public var issuedAt: Date
    public var expiresAt: Date
    public var trialEndsAt: Date?
    /// Present once a trial has EVER been used — lets the UI hide "start trial"
    /// for someone whose trial already lapsed.
    public var trialStartedAt: Date?

    /// Whether the offline-grace window is still open (server re-validation
    /// refreshes it; a cancelled subscription lapses once this passes).
    public func isValid(now: Date = Date()) -> Bool { now < expiresAt }
}

public enum EntitlementVerifier {
    /// The bundled Ed25519 public key (JWK `x`, base64url). MUST match the
    /// server's `OSMO_LICENSE_PUBLIC_X`. PRODUCTION key (generated 2026-07-06);
    /// the private half lives only in the server env (OSMO_LICENSE_PRIVATE_D).
    public static let publicKeyX = "lRI-n0RMoS_ErgsdnnS5hjIWEDJ8ZkhhOCZL2DU5F0k"

    private struct Payload: Codable {
        var v: Int
        var deviceId: String
        var tier: String
        var issuedAt: TimeInterval
        var expiresAt: TimeInterval
        var trialEndsAt: TimeInterval?
        var trialStartedAt: TimeInterval?
    }

    /// Verify a signed entitlement. Returns nil (⇒ treat as free) on any of:
    /// bad base64, bad signature, unknown tier, a payload bound to a DIFFERENT
    /// device (replay of someone else's Pro), or an expired offline window.
    public static func verify(entitlementB64: String, signatureB64: String,
                              expectedDeviceID: String?, now: Date = Date()) -> VerifiedEntitlement? {
        guard let message = Data(base64URLEncoded: entitlementB64),
              let signature = Data(base64URLEncoded: signatureB64),
              let keyData = Data(base64URLEncoded: publicKeyX),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              key.isValidSignature(signature, for: message),
              let payload = try? JSONDecoder().decode(Payload.self, from: message),
              let tier = EntitlementTier(rawValue: payload.tier)
        else { return nil }

        if let expected = expectedDeviceID, payload.deviceId != expected { return nil }

        let entitlement = VerifiedEntitlement(
            deviceID: payload.deviceId, tier: tier,
            issuedAt: Date(timeIntervalSince1970: payload.issuedAt),
            expiresAt: Date(timeIntervalSince1970: payload.expiresAt),
            trialEndsAt: payload.trialEndsAt.map { Date(timeIntervalSince1970: $0) },
            trialStartedAt: payload.trialStartedAt.map { Date(timeIntervalSince1970: $0) })
        return entitlement.isValid(now: now) ? entitlement : nil
    }
}

extension Data {
    /// Decode a base64url string (no padding, `-`/`_` alphabet) into bytes.
    init?(base64URLEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b.append("=") }
        self.init(base64Encoded: b)
    }
}
