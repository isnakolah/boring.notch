// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CallaContracts",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CallaContracts", targets: ["CallaContracts"])],
    targets: [
        .target(name: "CallaContracts"),
        .testTarget(name: "CallaContractsTests", dependencies: ["CallaContracts"]),
    ]
)
