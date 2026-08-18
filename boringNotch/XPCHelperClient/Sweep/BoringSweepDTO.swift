//
//  BoringSweepDTO.swift
//  boringNotch
//
//  What crosses the XPC boundary, in both directions.
//

import Foundation

struct BoringSweepRequest: Codable {
    var version = 2
    var command: String
    var targetID: String? = nil
    var categoryID: String? = nil
    var targetOffset: Int? = nil
    var typedConfirmation: String? = nil
    var preferences: BoringSweepPreferences? = nil
}
struct BoringSweepPreferences: Codable { var candidateThresholdBytes: Int64; var extraScanRoots: [String]; var userExclusions: [String]; var resurveyInterval: TimeInterval }
struct BoringSweepReply: Codable { var version: Int; var snapshot: BoringSweepSnapshot?; var progress: BoringSweepProgress?; var error: String? }
struct BoringSweepProgress: Codable { var isSurveying: Bool; var progress: Double }
struct BoringSweepSnapshot: Codable {
    var isSurveying: Bool; var progress: Double; var analysisIsCached: Bool; var lastSurvey: Date?
    var volume: BoringSweepVolume?; var categories: [BoringSweepCategory]; var protected: BoringSweepProtected
    var includesCategoryPage: Bool; var categoryID: String?; var targets: [BoringSweepTarget]; var nextTargetOffset: Int?
    var reclaimableBytes: Int64; var includesHistory: Bool; var unreadableRoots: [String]
    var selectedIDs: Set<String>; var selectedBytes: Int64; var preferences: BoringSweepPreferences
    var history: BoringSweepHistory; var regrowth: [BoringSweepRegrowth]; var pendingPlan: BoringSweepPlan?
    var lastReport: BoringSweepReport?; var fullDiskAccess: Bool; var migration: BoringSweepMigration
}
struct BoringSweepVolume: Codable { var name: String; var total: Int64; var available: Int64; var availableStrict: Int64 }
struct BoringSweepCategory: Codable, Identifiable { var id: String; var label: String; var count: Int; var reclaimableBytes: Int64 }
struct BoringSweepProtected: Codable { static let id = "__protected__"; var count: Int; var bytes: Int64 }
struct BoringSweepTarget: Codable, Identifiable { var id: String; var title: String; var path: String; var bytes: Int64; var risk: String; var category: String; var summary: String; var defaultReclaim: String; var components: [BoringSweepTarget] }
struct BoringSweepHistory: Codable { var samples: [BoringSweepSample]; var cumulativeFreedBytes: Int64; var entries: [BoringSweepHistoryEntry] }
struct BoringSweepSample: Codable { var date: Date; var usedBytes: Int64; var totalBytes: Int64 }
struct BoringSweepHistoryEntry: Codable, Identifiable { var id: String; var date: Date; var measuredFreedBytes: Int64; var trashedBytes: Int64; var itemCount: Int }
struct BoringSweepRegrowth: Codable, Identifiable { var id: String; var path: String; var count: Int; var lastBytes: Int64 }
struct BoringSweepPlan: Codable { var itemCount: Int; var requiresTypedConfirmation: Bool; var estimatedBytes: Int64; var sourceTimestamp: Date; var sourceState: String }
struct BoringSweepReport: Codable { var measuredFreedBytes: Int64; var trashedBytes: Int64; var failedCount: Int }
struct BoringSweepMigration: Codable { var complete: Bool; var importedLegacyData: Bool; var message: String }
struct BoringSweepPage { var targets: [BoringSweepTarget]; var nextOffset: Int? }
