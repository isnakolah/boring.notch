// swift-tools-version: 6.0
import PackageDescription

// The app's intelligence layer, as its own package rather than files shared by
// path (the trick the root Package.swift uses for CallaEngineValidation).
// SPM refuses a target path outside its package root, so a path-shared target
// cannot reach across into CallaCallHost/. A local package dependency can, and
// all three consumers — the app, the XPC engine, and the call host — need the
// same types.
//
// IntelligenceCore is pure: no Process, no UI, no Defaults. Policy is passed
// in, never read. That is what keeps it usable from every target.
let package = Package(
    name: "Intelligence",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IntelligenceCore", targets: ["IntelligenceCore"]),
        .library(name: "IntelligenceProviders", targets: ["IntelligenceProviders"]),
        .library(name: "IntelligenceStore", targets: ["IntelligenceStore"]),
    ],
    targets: [
        .target(name: "IntelligenceCore"),
        .target(name: "IntelligenceProviders", dependencies: ["IntelligenceCore"]),
        // Knowledge and call history on SQLite. Deliberately not folded into
        // IntelligenceCore: this one links SQLite3 and NaturalLanguage and owns a
        // file on disk, and Core's whole value is that it does neither.
        .target(
            name: "IntelligenceStore",
            dependencies: ["IntelligenceCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "IntelligenceCoreTests", dependencies: ["IntelligenceCore"]),
        .testTarget(name: "IntelligenceProvidersTests", dependencies: ["IntelligenceProviders"]),
        .testTarget(name: "IntelligenceStoreTests", dependencies: ["IntelligenceStore"]),
    ]
)
