import Foundation
import IntelligenceCore

public extension ModelCatalog {
    /// What `agy` exposes, and the tier tokens `agentapi` accepts.
    ///
    /// The pairing was verified by asking each tier what it was running as:
    /// `flash` answered "Gemini 3.7 Flash", `pro` answered Gemini Pro,
    /// `flash_lite` answered generically. The exact ids come from `agy models`
    /// and only the print transport can honour them.
    static let agy = ModelCatalog(
        provider: .localAgy,
        entries: [
            Entry(
                tier: .fast,
                tierToken: "flash_lite",
                exactID: "gemini-3.7-flash-low",
                displayName: "Gemini 3.7 Flash (Low)"
            ),
            Entry(
                tier: .balanced,
                tierToken: "flash",
                exactID: "gemini-3.7-flash-medium",
                displayName: "Gemini 3.7 Flash (Medium)"
            ),
            Entry(
                tier: .deep,
                tierToken: "pro",
                exactID: "gemini-3.1-pro-high",
                displayName: "Gemini 3.1 Pro (High)"
            ),
        ]
    )
}
