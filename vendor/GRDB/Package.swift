// swift-tools-version:6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// VENDORED (Osmo): this is upstream GRDB.swift v7.11.1 with the project's own
// built-in "GRDB+SQLCipher" toggle enabled — the four lines below are uncommented,
// the plain-SQLite target is swapped for the GRDBSQLCipher C shim, and the test
// target is dropped (Tests/ isn't vendored). No GRDB *source* is modified: every
// codec call is already guarded by `#if SQLITE_HAS_CODEC` upstream. This gives real
// whole-database encryption at rest via `Database.usePassphrase(_:)` over SPM,
// which upstream can't do unmodified because the codec defines must be compiled
// into GRDB's own target. Pinned by vendoring so it can't drift.

import Foundation
import PackageDescription

let darwinPlatforms: [Platform] = [
    .iOS,
    .macOS,
    .macCatalyst,
    .tvOS,
    .visionOS,
    .watchOS,
]
var swiftSettings: [SwiftSetting] = [
    .define("SQLITE_ENABLE_FTS5"),
    .define("SQLITE_ENABLE_SNAPSHOT"),
    // Not all Linux distributions have support for WAL snapshots.
    .define("SQLITE_DISABLE_SNAPSHOT", .when(platforms: [.linux])),
]
var cSettings: [CSetting] = []
var dependencies: [PackageDescription.Package.Dependency] = []

if ProcessInfo.processInfo.environment["SQLITE_ENABLE_PREUPDATE_HOOK"] == "1" {
    swiftSettings.append(.define("SQLITE_ENABLE_PREUPDATE_HOOK"))
    cSettings.append(.define("GRDB_SQLITE_ENABLE_PREUPDATE_HOOK"))
}

// GRDB+SQLCipher: enabled.
dependencies.append(.package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", from: "4.11.0"))
cSettings.append(.define("SQLITE_HAS_CODEC"))
swiftSettings.append(.define("SQLITE_HAS_CODEC"))
swiftSettings.append(.define("SQLCipher"))

let package = Package(
    name: "GRDB",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v7),
    ],
    products: [
        // GRDB+SQLCipher: GRDBSQLite library deleted.
        .library(name: "GRDB", targets: ["GRDB"]),
        .library(name: "GRDB-dynamic", type: .dynamic, targets: ["GRDB"]),
    ],
    dependencies: dependencies,
    targets: [
        // GRDB+SQLCipher: GRDBSQLite (plain-SQLite systemLibrary) deleted; the
        // GRDBSQLCipher C shim bridges GRDB to the SQLCipher.swift amalgamation.
        .target(
            name: "GRDBSQLCipher",
            dependencies: [.product(name: "SQLCipher", package: "SQLCipher.swift")]
        ),
        .target(
            name: "GRDB",
            dependencies: [
                .product(name: "SQLCipher", package: "SQLCipher.swift"),
                .target(name: "GRDBSQLCipher"),
            ],
            path: "GRDB",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            cSettings: cSettings,
            swiftSettings: swiftSettings + [
                .enableUpcomingFeature("MemberImportVisibility"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
