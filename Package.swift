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
        .library(name: "OsmoBrain", targets: ["OsmoBrain"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "OsmoCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "OsmoBrain",
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
        )
    ]
)
