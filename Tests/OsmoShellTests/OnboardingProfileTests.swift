import XCTest
@testable import OsmoShell

/// The onboarding "context layer" — captured goals/style/struggles/people must
/// render into a stable prompt preamble and survive persistence, since it's
/// injected into every draft + Ask prompt.
final class OnboardingProfileTests: XCTestCase {

    func testEmptyProfileHasEmptyPreamble() {
        let p = OnboardingProfile()
        XCTAssertTrue(p.isEmpty)
        XCTAssertTrue(p.promptPreamble.isEmpty)
    }

    func testPreambleRendersCapturedContext() {
        let p = OnboardingProfile(
            goals: [.writeBetter],
            styles: [.warm, .direct],
            struggles: [.overthinking],
            keyPeople: ["Sam", "Alex"])
        let s = p.promptPreamble
        XCTAssertTrue(s.contains("write better"), s)
        XCTAssertTrue(s.contains("warm"), s)
        XCTAssertTrue(s.contains("overthinking"), s)
        XCTAssertTrue(s.contains("Sam"), s)
        XCTAssertFalse(p.isEmpty)
    }

    func testCodableRoundTrip() throws {
        let p = OnboardingProfile(goals: [.keepInTouch], keyPeople: ["Jordan"])
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(OnboardingProfile.self, from: data)
        XCTAssertEqual(p, back)
    }
}
