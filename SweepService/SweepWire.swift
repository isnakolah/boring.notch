import Foundation

/// JSON-only boundary between sandboxed Boring host and unsandboxed Sweep XPC
/// service. Values stay explicit so service never receives arbitrary commands.
struct SweepWireRequest: Codable {
    enum Command: String, Codable {
        case open, status, loadCategory, loadHistory, rescan, cancel, toggleSelection, selectAll, selectRecommended, clearSelection
        case updatePreferences, prepareReclaim, confirmReclaim, clearRegrowth, shutdown
    }

    static let version = 2
    var version: Int = SweepWireRequest.version
    var command: Command
    var targetID: String?
    var categoryID: String?
    var targetOffset: Int?
    var typedConfirmation: String?
    var preferences: SweepWirePreferences?
}

struct SweepWireReply: Codable {
    var version: Int = SweepWireRequest.version
    var snapshot: SweepWireSnapshot?
    var progress: SweepWireProgress?
    var error: String?
}

/// Small response used while walking disk. Do not resend cached survey data for
/// every progress tick: it can be megabytes and makes Settings contend with scan.
struct SweepWireProgress: Codable {
    var isSurveying: Bool
    var progress: Double
}

struct SweepWireSnapshot: Codable {
    var isSurveying: Bool
    var progress: Double
    var analysisIsCached: Bool
    var lastSurvey: Date?
    var volume: SweepWireVolume?
    /// Rollups remain small enough to return on every non-progress reply.
    /// Individual rows cross XPC only after their category is expanded.
    var categories: [SweepWireCategorySummary]
    var protected: SweepWireProtectedSummary
    var includesCategoryPage: Bool
    var categoryID: String?
    var targets: [SweepWireTarget]
    var nextTargetOffset: Int?
    var reclaimableBytes: Int64
    var includesHistory: Bool
    var unreadableRoots: [String]
    var selectedIDs: Set<String>
    var selectedBytes: Int64
    var preferences: SweepWirePreferences
    var history: SweepWireHistory
    var regrowth: [SweepWireRegrowth]
    var pendingPlan: SweepWirePlan?
    var lastReport: SweepWireReport?
    var fullDiskAccess: Bool
    var migration: SweepWireMigration
}

struct SweepWireVolume: Codable {
    var name: String
    var total: Int64
    var available: Int64
    var availableStrict: Int64
    var used: Int64 { max(0, total - available) }
}

struct SweepWireTarget: Codable, Identifiable {
    var id: String
    var title: String
    var path: String
    var bytes: Int64
    var risk: String
    var category: String
    var summary: String
    var defaultReclaim: String
    var components: [SweepWireTarget]
}

struct SweepWireCategorySummary: Codable, Identifiable {
    var id: String
    var label: String
    var count: Int
    var reclaimableBytes: Int64
}

struct SweepWireProtectedSummary: Codable {
    static let id = "__protected__"
    var count: Int
    var bytes: Int64
}

struct SweepWirePreferences: Codable {
    var candidateThresholdBytes: Int64
    var extraScanRoots: [String]
    var userExclusions: [String]
    var resurveyInterval: TimeInterval
}

struct SweepWireHistory: Codable {
    var samples: [SweepWireSample]
    var cumulativeFreedBytes: Int64
    var entries: [SweepWireHistoryEntry]
}
struct SweepWireSample: Codable { var date: Date; var usedBytes: Int64; var totalBytes: Int64 }
struct SweepWireHistoryEntry: Codable, Identifiable {
    var id: String; var date: Date; var measuredFreedBytes: Int64; var trashedBytes: Int64; var itemCount: Int
}
struct SweepWireRegrowth: Codable, Identifiable {
    var id: String; var path: String; var count: Int; var lastBytes: Int64
}
struct SweepWirePlan: Codable {
    var itemCount: Int
    var requiresTypedConfirmation: Bool
    var estimatedBytes: Int64
    /// Frozen when Review cleanup is pressed. A later survey cannot change this
    /// confirmation's payload or make its wording misleading.
    var sourceTimestamp: Date
    var sourceState: String
}
struct SweepWireReport: Codable { var measuredFreedBytes: Int64; var trashedBytes: Int64; var failedCount: Int }
struct SweepWireMigration: Codable { var complete: Bool; var importedLegacyData: Bool; var message: String }
