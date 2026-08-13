import Foundation

/// Sweep now belongs to Boring. Legacy `Application Support/Sweep` remains a
/// rollback copy; service reads and writes only this root after migration.
enum SweepStorage {
    static let directoryName = "boringNotch/Sweep"

    static var rootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func url(_ name: String) -> URL { rootURL.appendingPathComponent(name) }
}
