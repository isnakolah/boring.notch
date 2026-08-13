import Foundation

// C4 as data. Never nominated, never classified, never deleted — sized only, so
// totals stay honest.
//
// This list is a floor. It may grow; nothing may remove from it. The Settings
// exclusion editor (Phase 10) adds user entries on top of these and cannot
// subtract from them, which is why the built-ins are a `let` and the user
// additions are a separate set.
//
// Phase 12 added `descentReason`, the form the walk uses. Every C4 rule excludes
// a *subtree*, and the sizer descends top-down and never enters an excluded
// directory — so at the moment a child is tested, the only question that can
// still be open is whether the child is itself the top of an excluded subtree.
// That is a set lookup and two parent comparisons, where `reason(for:)` has to
// prefix-match every rule and split the path. The two agree for every path a
// walk can reach, which `ExclusionsTests` asserts.
struct Exclusions: Sendable {

    /// Reasons are carried so a caller can say *why* something was excluded
    /// rather than silently omitting it.
    enum Reason: Equatable {
        case userData               // Documents, Desktop, Downloads
        case photoLibrary
        case cloudSynced            // eviction propagates off-machine
        case credentials
        case appleGroupContainer
        case versionControl         // any .git directory
        case outsideBootVolume
        case userDefined

        var explanation: String {
            switch self {
            case .userData: return "personal documents"
            case .photoLibrary: return "a Photos library"
            case .cloudSynced: return "synced to iCloud, where local eviction propagates to the cloud"
            case .credentials: return "credentials or private keys"
            case .appleGroupContainer: return "a system group container"
            case .versionControl: return "a Git repository's own history"
            case .outsideBootVolume: return "outside the boot volume"
            case .userDefined: return "excluded in Settings"
            }
        }
    }

    /// The home-relative subtrees excluded outright, as data.
    static let homeRelativePaths: [(String, Reason)] = [
        ("Documents", .userData),
        ("Desktop", .userData),
        ("Downloads", .userData),
        ("Library/Mobile Documents", .cloudSynced),
        ("Library/CloudStorage", .cloudSynced),
        ("Library/Keychains", .credentials),
        (".ssh", .credentials),
        (".gnupg", .credentials),
        (".aws", .credentials),
        (".config", .credentials),
        (".kube", .credentials),
    ]

    static let versionControlDirectoryName = ".git"
    static let photoLibrarySuffix = ".photoslibrary"
    static let appleGroupInfix = ".apple."

    private let home: URL
    private let userDefined: [URL]

    // Resolved once in `init`: this type is consulted once per filesystem entry.
    private let builtInPaths: [(path: String, reason: Reason)]
    private let userDefinedPaths: [String]
    private let picturesPath: String
    private let groupContainersPath: String
    /// Exact paths that are the top of an excluded subtree, for the walk's O(1)
    /// lookup. Component-shaped rules (`.git`, `*.photoslibrary`, `*.apple.*`)
    /// cannot be enumerated and are handled by name in `descentReason`.
    private let exclusionRoots: [String: Reason]

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         userDefined: [URL] = []) {
        self.home = home
        self.userDefined = userDefined.map { $0.standardizedFileURL }
        let standardHome = home.standardizedFileURL
        self.builtInPaths = Self.homeRelativePaths.map {
            (standardHome.appendingPathComponent($0.0).standardizedFileURL.path, $0.1)
        }
        self.userDefinedPaths = self.userDefined.map(\.path)
        self.picturesPath = standardHome.appendingPathComponent("Pictures").standardizedFileURL.path
        self.groupContainersPath = standardHome
            .appendingPathComponent("Library/Group Containers").standardizedFileURL.path

        var roots: [String: Reason] = [:]
        for path in self.userDefinedPaths { roots[path] = .userDefined }
        for entry in self.builtInPaths where roots[entry.path] == nil { roots[entry.path] = entry.reason }
        self.exclusionRoots = roots
    }

    /// Why this URL is excluded, or nil if it is not. The general entry point:
    /// correct for any path, including one excluded by an ancestor.
    func reason(for url: URL) -> Reason? {
        let path = url.standardizedFileURL.path

        for candidate in userDefinedPaths where matches(path, candidate) {
            return .userDefined
        }
        for entry in builtInPaths where matches(path, entry.path) {
            return entry.reason
        }

        // Any .git directory, at any depth — the repository's own history is not
        // Sweep's to reclaim.
        var sawPhotoLibrary = false
        for component in path.split(separator: "/") {
            if component == Self.versionControlDirectoryName { return .versionControl }
            if component.hasSuffix(Self.photoLibrarySuffix) { sawPhotoLibrary = true }
        }

        // ~/Pictures/*.photoslibrary
        if sawPhotoLibrary, matches(path, picturesPath) { return .photoLibrary }

        // ~/Library/Group Containers/*.apple.*
        if isDescendant(path, of: groupContainersPath) {
            let relative = path.dropFirst(groupContainersPath.count + 1)
            if let first = relative.split(separator: "/").first, first.contains(Self.appleGroupInfix) {
                return .appleGroupContainer
            }
        }

        return nil
    }

    /// The walk's form. `path` must be standardised and `parentPath` must already
    /// have been cleared by this same check — both hold in `Sizer`, which builds
    /// each child path by appending to a cleared, standardised parent.
    func descentReason(path: String, parentPath: String, name: String) -> Reason? {
        if name == Self.versionControlDirectoryName { return .versionControl }
        if let reason = exclusionRoots[path] { return reason }
        if parentPath == picturesPath, name.hasSuffix(Self.photoLibrarySuffix) { return .photoLibrary }
        if parentPath == groupContainersPath, name.contains(Self.appleGroupInfix) { return .appleGroupContainer }
        return nil
    }

    func contains(url: URL) -> Bool {
        reason(for: url) != nil
    }

    /// Whether a node sits on the same volume as the scan root. Everything
    /// outside the boot volume is excluded (C4), which the sizer enforces by
    /// comparing volume identifiers during the walk.
    func isOnBootVolume(_ attributes: FileAttributes, rootVolumeID: UInt64?) -> Bool {
        guard let rootVolumeID else { return true }
        guard let id = attributes.volumeID else { return false }
        return id == rootVolumeID
    }

    // MARK: Path arithmetic

    private func matches(_ path: String, _ ancestor: String) -> Bool {
        path == ancestor || isDescendant(path, of: ancestor)
    }

    private func isDescendant(_ path: String, of ancestor: String) -> Bool {
        // Prefix comparison alone would treat ~/Documents-old as inside
        // ~/Documents; the separator makes it a real path boundary.
        let ancestorBytes = ancestor.utf8
        let pathBytes = path.utf8
        guard pathBytes.count > ancestorBytes.count, path.hasPrefix(ancestor) else { return false }
        if ancestor.hasSuffix("/") { return true }
        let boundary = pathBytes.index(pathBytes.startIndex, offsetBy: ancestorBytes.count)
        return pathBytes[boundary] == UInt8(ascii: "/")
    }
}
