// swift-tools-version: 6.0
import PackageDescription

// Deliberately a separate package from Tutor/apps/macos/TutorHost:
//
//  * this one pulls a whisper.cpp xcframework, and TutorHost's `swift test`
//    should not start downloading one;
//  * TutorHost lives inside the vendored `Tutor/` subtree, which has already
//    diverged from upstream by hand. New boring-owned code stays out of it.
let package = Package(
    name: "CallaCallHost",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CallaCallHost", targets: ["CallaCallHost"]),
    ],
    dependencies: [
        // The app's intelligence layer. A local package rather than shared source
        // paths, because SPM refuses a target path outside its own package root
        // and the app, the XPC engine and this host all need the same types.
        .package(path: "../Intelligence"),
    ],
    targets: [
        // Prebuilt, checksummed. Same pin Mila ships, so the two apps agree on
        // whisper behaviour and on the audio_ctx findings that came with it.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.4/whisper-v1.8.4-xcframework.zip",
            checksum: "1c7a93bd20fe4e57e0af12051ddb34b7a434dfc9acc02c8313393150b6d1821f"),
        // Capture, VAD, transcription and the call session live in a library so
        // they can be tested without launching an app. The executable is a thin
        // main.
        .target(
            name: "CallaCallHostKit",
            dependencies: [
                "whisper",
                .product(name: "IntelligenceCore", package: "Intelligence"),
                .product(name: "IntelligenceProviders", package: "Intelligence"),
                .product(name: "IntelligenceStore", package: "Intelligence"),
            ],
            // The only model that ships inside the bundle: under a megabyte,
            // and the gate that keeps whisper from hallucinating words onto a
            // fan or a keyboard burst. The transcription models are far too
            // large to embed and are fetched on first run instead.
            resources: [.copy("Resources/ggml-silero-v5.1.2.bin")]),
        .executableTarget(
            name: "CallaCallHost",
            dependencies: ["CallaCallHostKit"]),
        .testTarget(
            name: "CallaCallHostKitTests",
            dependencies: ["CallaCallHostKit"]),
    ]
)
