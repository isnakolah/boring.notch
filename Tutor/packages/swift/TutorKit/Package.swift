// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TutorKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TutorProtocol", targets: ["TutorProtocol"]),
        .library(name: "TutorCore", targets: ["TutorCore"]),
    ],
    targets: [
        .target(name: "TutorProtocol"),
        .target(name: "TutorCore", dependencies: ["TutorProtocol"]),
        .testTarget(name: "TutorCoreTests", dependencies: ["TutorCore", "TutorProtocol"]),
    ]
)
