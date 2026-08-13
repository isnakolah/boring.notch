import Foundation

// Structural markers a node can carry that make it worth judging regardless of
// size (C2). Every test here reads the node's own shape — its name, its
// extension, a sentinel file inside it — never a catalogue of known tools. This
// is the whole point: `GoLand2026.1` is interesting because its name is a program
// name followed by a version, not because "GoLand" appears in a list.
enum StructuralMarkers {

    /// Filesystem extensions that denote a disk image. These are format facts
    /// (a `.dmg` is a disk image on any Mac), not product names.
    static let diskImageExtensions: Set<String> = [
        "dmg", "sparseimage", "sparsebundle", "img", "iso", "raw", "qcow2", "vdi", "vmdk", "hds",
    ]

    /// The freedesktop cache sentinel. A directory containing a `CACHEDIR.TAG`
    /// file declares *itself* regenerable cache; nothing external is consulted.
    static let cacheTagName = "CACHEDIR.TAG"

    static func hasDiskImageExtension(_ url: URL) -> Bool {
        diskImageExtensions.contains(url.pathExtension.lowercased())
    }

    /// The same test against a bare file name. The walk has the name already and
    /// building a `URL` per entry just to read its extension is the kind of cost
    /// that only shows up when it is paid a few million times.
    static func hasDiskImageExtension(name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...]
        return diskImageExtensions.contains(ext.lowercased())
    }

    /// A directory whose name is a program name immediately followed by a version
    /// — `GoLand2026.1`, `RustRover2026.1.2`, `Python 3.11`. The version suffix is
    /// what marks it: several such siblings are the signature of leftover old
    /// versions, and the comparison against the installed version happens later
    /// (Phase 06). Here we only notice the shape.
    static func hasVersionSuffix(_ name: String) -> Bool {
        // Require a letter-then-digit boundary so a bare version (`2026.1`) or an
        // ordinary word does not match; the name must look like NAME + VERSION.
        guard let regex = versionSuffixRegex else { return false }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        return regex.firstMatch(in: name, range: range) != nil
    }

    /// A directory whose name is bundle-identifier-shaped — three or more
    /// dot-separated reverse-DNS labels, `com.docker.docker`. Such a name is how
    /// per-application data is stored, so the directory is worth attributing and
    /// judging. The shape is the signal; no specific identifier is listed.
    static func isBundleIdentifierShaped(_ name: String) -> Bool {
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3 else { return false }
        // Every label a valid DNS-ish token: starts alphanumeric, no spaces.
        let labelPattern = #"^[A-Za-z0-9][A-Za-z0-9-]*$"#
        return labels.allSatisfy {
            !$0.isEmpty && $0.range(of: labelPattern, options: .regularExpression) != nil
        }
    }

    private static let versionSuffixRegex: NSRegularExpression? = {
        // <name ending in a letter><version: digits(.digits)*> to end of string.
        try? NSRegularExpression(pattern: #"[A-Za-z]\s?\d+(\.\d+)+$"#)
    }()
}
