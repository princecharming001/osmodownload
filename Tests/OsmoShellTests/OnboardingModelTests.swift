import Testing
import Foundation
@testable import OsmoShell

@Suite("Onboarding flow model")
struct OnboardingModelTests {

    @Test("Steps advance in order and complete on the last")
    func ordering() {
        let m = OnboardingModel()
        #expect(m.step == .welcome)
        #expect(m.isFirst)
        var guardCount = 0
        while !m.completed && guardCount < 20 { m.advance(); guardCount += 1 }
        #expect(m.completed)
        #expect(m.step == .finish)
    }

    @Test("Skip records the step and still advances")
    func skip() {
        let m = OnboardingModel(start: .connect)
        m.skip()
        #expect(m.skipped.contains(.connect))
        #expect(m.step == .finish)
    }

    @Test("Granting the permission auto-advances only on the permission step")
    func permissionAdvance() {
        let m = OnboardingModel(start: .permission)
        #expect(m.permissionGranted())        // advances
        #expect(m.step == .practice)
        #expect(!m.skipped.contains(.permission))
        // On a different step, permissionGranted is a no-op.
        let other = OnboardingModel(start: .welcome)
        #expect(!other.permissionGranted())
        #expect(other.step == .welcome)
    }

    @Test("Progress is monotonic 0→1 and back() steps backward")
    func progress() {
        let m = OnboardingModel()
        #expect(m.progress == 0)
        m.advance(); m.advance()
        #expect(m.progress > 0 && m.progress < 1)
        m.back()
        #expect(m.step == .hotkey)
        // goTo jumps directly (replay-from-settings).
        m.goTo(.practice)
        #expect(m.step == .practice)
    }
}
