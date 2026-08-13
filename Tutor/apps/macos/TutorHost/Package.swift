// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CallaTutorHost",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CallaTutorHost", targets: ["CallaTutorHost"]),
        // Rendered in its own process: AppKit panels never composite from the
        // SwiftUI MenuBarExtra host, and an overlay crash must not take the
        // socket host with it.
        .executable(name: "CallaOverlayHelper", targets: ["CallaOverlayHelper"]),
    ],
    dependencies: [.package(path: "../../../packages/swift/TutorKit")],
    targets: [
        .executableTarget(
            name: "CallaTutorHost",
            dependencies: [.product(name: "TutorProtocol", package: "TutorKit")]),
        .executableTarget(name: "CallaOverlayHelper"),
        // The two pieces of arithmetic in this host that are wrong silently.
        // A coordinate transform that is off by a title bar still points
        // somewhere, and a diagnosis that names the wrong modifier still reads
        // like help — neither fails, so neither is noticed without a test.
        .testTarget(name: "CallaTutorHostTests", dependencies: ["CallaTutorHost"]),
    ]
)
