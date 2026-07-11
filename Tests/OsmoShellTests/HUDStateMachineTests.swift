import Testing
import Foundation
import CoreGraphics
@testable import OsmoShell

@Suite("HUD state machine — bar/open sizing + top-left anchoring")
struct HUDStateMachineTests {
    @Test("toggle flips bar ⟷ open")
    func toggle() {
        #expect(HUDStateMachine.toggled(.bar) == .open)
        #expect(HUDStateMachine.toggled(.open) == .bar)
    }

    @Test("The bar is a fixed slim size; the open panel grows with rows up to a cap")
    func sizing() {
        let bar = HUDStateMachine.size(for: HUDState(mode: .bar), rowCount: 10)
        #expect(bar.height == HUDStateMachine.barHeight)
        let few = HUDStateMachine.size(for: HUDState(mode: .open), rowCount: 2)
        let many = HUDStateMachine.size(for: HUDState(mode: .open), rowCount: 50)
        #expect(many.height > few.height)
        #expect(many.height <= HUDStateMachine.openMaxHeight)   // capped
    }

    @Test("summary phrasing")
    func summary() {
        #expect(HUDStateMachine.summary(owedCount: 0) == "You're clear")
        #expect(HUDStateMachine.summary(owedCount: 1) == "1 needs you")
        #expect(HUDStateMachine.summary(owedCount: 4) == "4 need you")
    }

    @Test("Growing the panel keeps its top-left corner pinned (grows downward)")
    func topLeftPin() {
        // AppKit frame: origin bottom-left. A 56-tall bar at y=900 has its top at 956.
        let old = CGRect(x: 20, y: 900, width: 380, height: 56)
        let origin = HUDStateMachine.originPinningTopLeft(oldFrame: old, newSize: CGSize(width: 380, height: 400))
        #expect(abs(origin.x - 20) < 0.001)
        #expect(abs(origin.y - 556) < 0.001)   // top edge (956) preserved, grows down
    }

    @Test("clampTopLeft keeps the panel on screen")
    func clamp() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 380, height: 400)
        // A top-left way off the right edge is pulled back on-screen.
        let clamped = HUDStateMachine.clampTopLeft(CGPoint(x: 5000, y: 880), size: size, screen: screen)
        #expect(clamped.x <= screen.maxX - size.width - 16)
        #expect(clamped.x >= 16)
    }

    @Test("default anchor is the screen's top-left, inset")
    func defaultAnchor() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let a = HUDStateMachine.defaultTopLeft(screen: screen)
        #expect(abs(a.x - 16) < 0.001)
        #expect(abs(a.y - 884) < 0.001)   // maxY - inset
    }
}
