import Testing
import Foundation
import OsmoCore
@testable import OsmoShell

@Suite("Pill state machine")
struct PillStateMachineTests {
    typealias SM = PillStateMachine
    let ctx = PillContext(platform: .slack, partnerName: "Priya")

    @Test("Hotkey walks hidden → idle → generating → (finish) expanded → collapse")
    func hotkeyCycle() {
        var s = PillState.hidden
        s = SM.reduce(s, .hotkey);              #expect(s == .idle)
        s = SM.reduce(s, .hotkey)               // idle → generating (top queue card)
        if case .generating = s {} else { Issue.record("expected generating"); return }
        s = SM.reduce(s, .generationFinished)
        if case .expanded = s {} else { Issue.record("expected expanded"); return }
        s = SM.reduce(s, .hotkey)               // toggle collapse
        #expect(s == .idle)
    }

    @Test("Detected context makes the pill ready and carries the context")
    func detectionReady() {
        let s = SM.reduce(.idle, .detected(ctx))
        #expect(s == .ready(ctx))
        // Tapping a ready pill starts generation with the same context.
        let g = SM.reduce(s, .tapPill)
        #expect(g == .generating(ctx))
    }

    @Test("Detection never yanks an open panel away from the user")
    func detectionRespectsOpenPanel() {
        let expanded = PillState.expanded(ctx)
        #expect(SM.reduce(expanded, .detected(PillContext(platform: .gmail))) == expanded)
        let generating = PillState.generating(ctx)
        #expect(SM.reduce(generating, .detected(nil)) == generating)
    }

    @Test("Context leaving the field collapses a ready pill to idle")
    func contextLeaves() {
        #expect(SM.reduce(.ready(ctx), .detected(nil)) == .idle)
    }

    @Test("Escape collapses an expanded panel back to ready, keeping context")
    func escapeCollapses() {
        #expect(SM.reduce(.expanded(ctx), .escape) == .ready(ctx))
        #expect(SM.reduce(.generating(ctx), .escape) == .ready(ctx))
        // Escape on a collapsed pill is a no-op.
        #expect(SM.reduce(.idle, .escape) == .idle)
    }

    @Test("Hide always returns to hidden")
    func hide() {
        #expect(SM.reduce(.expanded(ctx), .hide) == .hidden)
        #expect(SM.reduce(.ready(ctx), .hide) == .hidden)
    }
}
