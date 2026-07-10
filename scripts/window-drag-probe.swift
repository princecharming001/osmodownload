#!/usr/bin/swift
// window-drag-probe.swift — reproduce + measure the "window snaps back / won't
// drag" bug with REAL mouse events (CGEvent), not AX position writes.
//
// For each grab point along the window's top strip: mouse-down, drag +220px
// right (in steps, like a human), mouse-up, then sample the window's origin
// immediately and again 1.5s later. PASS = the window moved with the drag AND
// stayed where it was dropped. Prints one line per grab point.
//
// Usage: swift scripts/window-drag-probe.swift [appName]   (default Osmo)

import AppKit
import ApplicationServices

let appName = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Osmo"

guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) else {
    print("FAIL: \(appName) is not running"); exit(1)
}
let axApp = AXUIElementCreateApplication(app.processIdentifier)

func mainWindow() -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return nil }
    // Pick the largest window (the pill panel is tiny).
    var best: (AXUIElement, CGFloat)? = nil
    for w in windows {
        if let f = frame(of: w), f.width > (best?.1 ?? 0) { best = (w, f.width) }
    }
    return best?.0
}

func frame(of window: AXUIElement) -> CGRect? {
    var posValue: CFTypeRef?, sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
          AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success else { return nil }
    var pos = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    return CGRect(origin: pos, size: size)
}

func post(_ type: CGEventType, at point: CGPoint) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
    e?.post(tap: .cghidEventTap)
    usleep(30_000)
}

func dragTest(grabOffsetX fraction: CGFloat, label: String) {
    guard let w = mainWindow(), let f0 = frame(of: w) else { print("\(label): no window"); return }
    let grab = CGPoint(x: f0.origin.x + f0.width * fraction, y: f0.origin.y + 12)   // 12px into the top strip
    let dropDX: CGFloat = 220

    app.activate(options: [])
    usleep(300_000)
    post(.leftMouseDown, at: grab)
    // human-ish drag in 10 steps
    for i in 1...10 {
        let p = CGPoint(x: grab.x + dropDX * CGFloat(i) / 10.0, y: grab.y)
        post(.leftMouseDragged, at: p)
    }
    post(.leftMouseUp, at: CGPoint(x: grab.x + dropDX, y: grab.y))
    usleep(300_000)

    guard let f1 = frame(of: w) else { print("\(label): window vanished"); return }
    Thread.sleep(forTimeInterval: 1.5)
    guard let f2 = frame(of: w) else { print("\(label): window vanished late"); return }

    let moved = f1.origin.x - f0.origin.x
    let drift = f2.origin.x - f1.origin.x
    let verdict: String
    if abs(moved) < 40 { verdict = "NO-GRAB (moved \(Int(moved))px of 220)" }
    else if abs(drift) > 20 { verdict = "SNAP-BACK (settled drift \(Int(drift))px)" }
    else if abs(moved - dropDX) > 60 { verdict = "LAGGY (moved \(Int(moved))px of 220)" }
    else { verdict = "OK (moved \(Int(moved))px, drift \(Int(drift))px)" }
    print("\(label) grab@\(Int(fraction*100))%: \(verdict)")

    // drag it back so repeated runs stay on screen
    if abs(moved) > 40 {
        let back = CGPoint(x: grab.x + moved, y: grab.y)
        post(.leftMouseDown, at: back)
        for i in 1...6 { post(.leftMouseDragged, at: CGPoint(x: back.x - moved * CGFloat(i) / 6.0, y: back.y)) }
        post(.leftMouseUp, at: CGPoint(x: back.x - moved, y: back.y))
        usleep(200_000)
    }
}

print("— window drag probe on \(appName) —")
dragTest(grabOffsetX: 0.10, label: "left  ")   // over the sidebar header
dragTest(grabOffsetX: 0.30, label: "mid-L ")   // sidebar/detail boundary
dragTest(grabOffsetX: 0.60, label: "mid-R ")   // detail toolbar strip
dragTest(grabOffsetX: 0.90, label: "right ")   // far right of the strip
