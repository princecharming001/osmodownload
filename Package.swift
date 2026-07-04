// swift-tools-version: 6.0
import PackageDescription

// OsmoCore — the local-first engine for Osmo (cross-platform relationship
// intelligence for Mac). Holds the canonical message/thread/contact schema, the
// encrypted local store, the platform readers, and the normalizer. The AI/
// psychology "brain" is reused from RegisterKit (referenced by local path) —
// proven to build + pass its 391 tests on macOS unchanged.
//
// Storage: GRDB over SQLite with FTS5. SQLCipher encryption is layered at a
// single seam (`OsmoDatabase.open`) so the whole-DB-encryption swap is localized
// — see StorageEncryption note in OsmoStore.swift. macOS `FileProtectionType`
// degrades to volume-level, so app-layer encryption (SQLCipher) is required for
// the "encrypted on your Mac" guarantee; that swap is the next storage slice.
let package = Package(
    name: "OsmoCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OsmoCore", targets: ["OsmoCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // The reused psychology/memory/suggestion brain. Local path — same repo
        // that passes 391 tests on macOS.
        .package(path: "/Users/home/Downloads/files 4/RegisterKit")
    ],
    targets: [
        .target(
            name: "OsmoCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "RegisterKit", package: "RegisterKit")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "OsmoCoreTests",
            dependencies: ["OsmoCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
