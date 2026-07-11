// swift-tools-version: 6.0
import PackageDescription

// Osmo — cross-platform relationship intelligence for Mac. Self-contained: the
// psychology + suggestion engine (OsmoBrain) is built natively for the pivot's
// goal-directed, thread-grounded model rather than ported from the iOS keyboard
// app. Everything runs keyless/mock by default; real credentials inject last.
//
// Modules:
//   OsmoCore  — data layer (canonical schema, encrypted store, readers, memory,
//               projects, identity graph, sync, AI-client, morning queue).
//   OsmoBrain — psychology technique catalog + goal-directed suggestion engine.
let package = Package(
    name: "Osmo",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OsmoCore", targets: ["OsmoCore"]),
        .library(name: "OsmoBrain", targets: ["OsmoBrain"]),
        // Pure app-shell logic (pill state machine, typing-detection rules,
        // onboarding model, notification rules) — SPM so `swift test` covers
        // it; the Xcode app target is a thin AppKit/SwiftUI shell over it.
        .library(name: "OsmoShell", targets: ["OsmoShell"])
        // The Mac app is an Xcode target (Osmo.xcodeproj) that links these
        // library products — see project.yml / App/. It's not an SPM executable
        // so it can carry an Info.plist, entitlements (App Sandbox off for
        // chat.db access), and a real .app bundle.
    ],
    dependencies: [
        // Vendored GRDB 7.11.1 with SQLCipher enabled (see vendor/GRDB) — real
        // whole-database encryption at rest. Same `import GRDB`; the passphrase is
        // applied at OsmoDatabase.open. Local path so it can't drift or break the build.
        .package(path: "vendor/GRDB")
    ],
    targets: [
        .executableTarget(
            name: "osmo-tool",
            dependencies: ["OsmoCore", .product(name: "GRDB", package: "GRDB")]),

        .target(
            name: "OsmoCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "OsmoBrain",
            dependencies: ["OsmoCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "OsmoShell",
            dependencies: ["OsmoCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OsmoCoreTests",
            dependencies: ["OsmoCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OsmoBrainTests",
            dependencies: ["OsmoBrain", "OsmoCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OsmoShellTests",
            dependencies: ["OsmoShell", "OsmoCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
