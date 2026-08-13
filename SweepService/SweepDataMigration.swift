import AppKit
import Foundation

/// One-way, non-destructive import. Old standalone data stays available for
/// rollback; a receipt prevents later opens from overwriting Boring-owned data.
enum SweepDataMigration {
    private static let legacyBundleID = "com.isnakolah.Sweep"
    private static let receiptURL = SweepStorage.url("migration-v1.json")
    private static let files = ["survey.json", "history.json", "regrowth.json"]

    static func runIfNeeded() -> SweepWireMigration {
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            return SweepWireMigration(complete: true, importedLegacyData: false, message: "Sweep data already belongs to Boring Notch.")
        }

        NSRunningApplication.runningApplications(withBundleIdentifier: legacyBundleID).forEach { $0.terminate() }
        let legacyRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sweep", isDirectory: true)
        var imported = false
        var copied: [String: String] = [:]
        do {
            try FileManager.default.createDirectory(at: SweepStorage.rootURL, withIntermediateDirectories: true)
            for name in files {
                let source = legacyRoot.appendingPathComponent(name)
                let destination = SweepStorage.url(name)
                guard FileManager.default.fileExists(atPath: source.path),
                      !FileManager.default.fileExists(atPath: destination.path) else { continue }
                let data = try Data(contentsOf: source)
                try data.write(to: destination, options: .atomic)
                copied[name] = checksum(data)
                imported = true
            }
            let legacy = UserDefaults(suiteName: legacyBundleID)
            let current = UserDefaults.standard
            for key in ["sweep.appearance", "sweep.reclaim.permanentByDefault", "sweep.survey.thresholdBytes", "sweep.survey.extraScanRoots", "sweep.survey.userExclusions", "sweep.survey.resurveyInterval"] {
                if let value = legacy?.object(forKey: key) { current.set(value, forKey: key) }
            }
            let receipt: [String: Any] = ["version": 1, "copied": copied, "createdAt": ISO8601DateFormatter().string(from: Date())]
            let receiptData = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            try receiptData.write(to: receiptURL, options: .atomic)
            return SweepWireMigration(complete: true, importedLegacyData: imported,
                                      message: imported ? "Imported standalone Sweep data. Legacy copy preserved." : "No standalone Sweep data needed importing.")
        } catch {
            return SweepWireMigration(complete: false, importedLegacyData: imported,
                                      message: "Sweep data migration failed: \(error.localizedDescription)")
        }
    }

    private static func checksum(_ data: Data) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in data { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(format: "%016llx-%llu", hash, data.count)
    }
}
