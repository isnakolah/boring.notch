// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BoringCallaEngineValidation",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CallaEngineValidation",
            path: "BoringCallaEngine",
            exclude: ["BoringCallaEngine.swift", "BoringCallaEngineProtocol.swift", "BoringCallaEngine.entitlements", "Info.plist", "main.swift"],
            sources: ["CallaCourseCommandValidation.swift", "CallaCoursePresentation.swift", "CallaCopilotCommandValidation.swift", "CallaAgyLoginParsing.swift"]
        ),
        .target(
            name: "CallaNotchPresentation",
            path: "boringNotch/components/Calla",
            exclude: [
                "CallaCalendarBindings.swift", "CallaCopilotLiveView.swift", "CallaCopilotSignInView.swift",
                "CallaCopilotTabView.swift", "CallaEngineClient.swift", "CallaKnowledge.swift",
                "CallaKnowledgeAttach.swift", "CallaKnowledgeDropView.swift", "CallaKnowledgeFocus.swift",
                "CallaKnowledgeLibrary.swift", "CallaTabView.swift", "CopilotLiveSession.swift",
                "CopilotNotchBadge.swift", "KnowledgeDocumentReader.swift", "NotchDropChooserView.swift",
                "NotchDropRouter.swift"
            ],
            sources: ["CallaNotchPresentation.swift", "CallaCopilotPresentation.swift"]
        ),
        .testTarget(
            name: "CallaEngineValidationTests",
            dependencies: ["CallaEngineValidation", "CallaNotchPresentation"],
            path: "BoringCallaEngineTests/Tests"
        )
    ]
)
