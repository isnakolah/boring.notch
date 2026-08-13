import Foundation

// Who owns a candidate, and whether they are still on the machine (C6).
//
// The orphan case falls out of this rather than needing its own scanner: an owner
// that resolves by name or vendor but has no installed application is, by that
// fact, an orphan — the evidence Phase 06 reads. Attribution states what it
// found; it reaches no verdict.
struct Owner: Codable, Equatable {

    // How the owner was identified, so the reasoning stays auditable and so a
    // generated explanation can say *how* Sweep knows who owns this.
    enum Provenance: String, Codable, Equatable {
        case bundleIdentifierInPath     // the path literally contains com.vendor.app
        case installedAppName           // a container child named like an installed app
        case spotlightBundleIdentifier  // kMDItemCFBundleIdentifier on the node
        case contentTypeVendor          // a reverse-DNS UTI on the node or a child
        case toolchainOnPath            // a dotfile dir whose binary is on PATH
    }

    var displayName: String
    var bundleIdentifier: String?
    /// Where the owning application is installed, if it is. Nil is the orphan
    /// signal: a resolved owner with no install.
    var installedURL: URL?
    /// `CFBundleShortVersionString`, normalised where a vendor uses a dated
    /// scheme, so Phase 06 can compare it against a version-suffixed directory.
    var installedVersion: String?
    var isRunning: Bool
    var provenance: Provenance

    var isInstalled: Bool { installedURL != nil }
}

// An application the registry found installed. Kept minimal — the attributor
// needs a name to match, an id to compare, and a version to read.
struct InstalledApp: Equatable {
    var name: String                    // "Docker Desktop", no ".app"
    var bundleIdentifier: String?
    var url: URL
    var version: String?
}

// Version normalisation, shared by attribution and the version signal (Phase 06).
// JetBrains and similar vendors stamp a directory `GoLand2026.1` and report
// `CFBundleShortVersionString` as `2026.1.2`; comparing them needs a common
// `YYYY.M` prefix. This is a *format* transform, not a per-vendor rule.
enum VersionNormalizer {

    /// The leading `major.minor` of a dotted version, e.g. `2026.1.2` → `2026.1`.
    /// Returns nil when the string carries no such prefix.
    static func majorMinor(_ raw: String) -> String? {
        guard let match = raw.range(of: #"\d+\.\d+"#, options: .regularExpression) else {
            return nil
        }
        return String(raw[match])
    }

    /// The version embedded in a directory name like `GoLand2026.1` or
    /// `Python 3.11`, normalised to `major.minor`.
    static func fromDirectoryName(_ name: String) -> String? {
        guard let match = name.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else {
            return nil
        }
        return majorMinor(String(name[match]))
    }
}
