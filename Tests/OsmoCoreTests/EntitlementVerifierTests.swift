import Testing
import Foundation
@testable import OsmoCore

@Suite("EntitlementVerifier — tamper-resistant tier")
struct EntitlementVerifierTests {
    // A real entitlement signed by the backend's DEV private key (payload:
    // deviceId "test-device", tier pro, expiresAt far in the future). The Swift
    // verifier must accept it with the bundled DEV public key.
    let entitlement = "eyJ2IjoxLCJkZXZpY2VJZCI6InRlc3QtZGV2aWNlIiwidGllciI6InBybyIsImlzc3VlZEF0IjoxODAwMDAwMDAwLCJleHBpcmVzQXQiOjQxMDI0NDQ4MDB9"
    let signature = "1wH2_T3gTc_ed38QfsAPxnSu2i2X22K6CQb8oVwmGniwwEtyqDEkUjF2haTKbAYLr8N5-GuiXnkpKa6en9RvDw"

    @Test("A validly-signed entitlement verifies to the right tier + device")
    func validSignaturePasses() {
        let v = EntitlementVerifier.verify(entitlementB64: entitlement, signatureB64: signature,
                                           expectedDeviceID: "test-device")
        #expect(v?.tier == .pro)
        #expect(v?.deviceID == "test-device")
        #expect(v?.tier.isPaid == true)
    }

    @Test("A tampered payload fails (the anti-forgery property that protects revenue)")
    func tamperedPayloadFails() {
        // Re-encode a payload flipping tier free→pro; the old signature won't cover it.
        let forgedJSON = #"{"v":1,"deviceId":"test-device","tier":"pro","issuedAt":1,"expiresAt":4102444800}"#
        let forged = Data(forgedJSON.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(EntitlementVerifier.verify(entitlementB64: forged, signatureB64: signature,
                                           expectedDeviceID: "test-device") == nil)
    }

    @Test("An entitlement bound to another device is rejected (no cross-device replay)")
    func wrongDeviceRejected() {
        #expect(EntitlementVerifier.verify(entitlementB64: entitlement, signatureB64: signature,
                                           expectedDeviceID: "someone-else") == nil)
    }

    @Test("A garbage signature is rejected, never crashes")
    func garbageSignature() {
        #expect(EntitlementVerifier.verify(entitlementB64: entitlement, signatureB64: "!!!notb64!!!",
                                           expectedDeviceID: "test-device") == nil)
    }

    @Test("An expired offline window is rejected even with a valid signature")
    func expiredRejected() {
        // Verify the SAME good signature but 'now' pushed past the payload's
        // expiresAt (4102444800 = year 2100). now = year 2100 + 1 day.
        let past2100 = Date(timeIntervalSince1970: 4_102_531_200)
        #expect(EntitlementVerifier.verify(entitlementB64: entitlement, signatureB64: signature,
                                           expectedDeviceID: "test-device", now: past2100) == nil)
    }
}
