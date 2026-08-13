import Foundation

// Full Disk Access is optional (C8). A non-sandboxed app reads ~/Library/Caches,
// ~/Library/Application Support, and dotfile directories without it, but macOS
// gates other applications' containers behind it — which is where the largest
// single item on the motivating machine, a 34 GB Docker disk image, lives.
//
// Sweep degrades rather than fails: roots it cannot read are reported as needing
// permission and excluded from totals. They are never reported as 0 bytes, which
// would be a lie the user has no way to detect.
enum Permissions {

    /// A directory macOS protects behind Full Disk Access. Reading it is the
    /// probe: an unsandboxed app without the grant gets a permission error here
    /// and nowhere else useful.
    static var probeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.apple.mail")
    }

    /// Deep link to Privacy & Security › Full Disk Access.
    static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Whether Sweep can currently read TCC-protected locations.
    ///
    /// The probe attempts a real directory read. Checking for the path's
    /// existence is not enough — `fileExists` succeeds without the grant, and
    /// only enumeration actually fails.
    static func hasFullDiskAccess(fileManager: FileManager = .default) -> Bool {
        let probe = probeURL
        guard fileManager.fileExists(atPath: probe.path) else {
            // No Mail container on this machine: the probe cannot answer, so
            // report the pessimistic result and let the survey mark unreadable
            // roots individually.
            return false
        }
        do {
            _ = try fileManager.contentsOfDirectory(atPath: probe.path)
            return true
        } catch {
            return false
        }
    }

    /// Whether a specific root can be enumerated. The survey uses this to mark a
    /// root as needing permission instead of counting it as empty.
    static func isReadable(_ url: URL, fileManager: FileManager = .default) -> Bool {
        do {
            _ = try fileManager.contentsOfDirectory(atPath: url.path)
            return true
        } catch {
            return false
        }
    }
}
