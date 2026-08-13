import Foundation

// Resolves who owns a candidate and whether they are still installed (C6).
//
// The resolution order is fixed, first hit wins:
//   1. a bundle-identifier-shaped component in the path;
//   2. a container-root (or home-level) directory named like an installed app;
//   3. Spotlight's bundle identifier for the node;
//   4. a reverse-DNS content-type UTI on the node or a child, naming a vendor
//      with no installed application — this is how the orphan is found;
//   5. a dotfile directory whose binary is on PATH;
//   6. unattributed.
//
// It never consults `KnownTools`, and it names no product in its own source: it
// reads facts from the machine (is this bundle id installed, is there a binary of
// this name on PATH) and from the node's own metadata. Enforced by test.
struct Attributor {

    let registry: AppRegistry
    let home: URL
    let containerRoots: Set<String>
    private let cache: Cache

    init(registry: AppRegistry,
         config: SurveyConfig = .standard(),
         home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.registry = registry
        self.home = home.standardizedFileURL
        self.containerRoots = Set(config.containerRoots(home: home).map(\.path))
        self.cache = Cache()
    }

    // UTIs that name no vendor: system and generic declarations. A vendor pulled
    // from one of these is not evidence of an owner.
    private static let genericUTIPrefixes = ["public.", "com.apple.", "dyn.", "org.freedesktop."]

    /// The owner of a node, or nil when Sweep cannot confidently name one. Nil is
    /// deliberate: guessing an owner would fabricate the evidence Phase 06 reads.
    func attribute(_ node: Node) -> Owner? {
        // 1. Bundle identifier in the path — the most specific, most reliable.
        if let bundleID = bundleIdentifierInPath(node.url) {
            return ownerFromBundleIdentifier(bundleID, provenance: .bundleIdentifierInPath)
        }

        let name = node.url.lastPathComponent
        let isDotfile = name.hasPrefix(".")

        // 2. A directory named like an installed app. Eligible when it is a
        //    container child or home-level directory, or when its name is
        //    version-suffixed — `GoLand2026.1` strips to `GoLand`, which is a
        //    strong enough name signal to match on its own, and it is exactly the
        //    comparison the version signal needs in Phase 06.
        if !isDotfile && (isNamedContainerCandidate(node.url) || StructuralMarkers.hasVersionSuffix(name)) {
            if let app = installedAppMatching(name: name) {
                return installedOwner(from: app, provenance: .installedAppName)
            }
        }

        // 3. Spotlight bundle identifier for the node itself.
        if let bundleID = cache.spotlightBundleID(for: node.url, registry: registry) {
            return ownerFromBundleIdentifier(bundleID, provenance: .spotlightBundleIdentifier)
        }

        // 4. A content-type UTI naming a vendor with no installed application —
        //    the orphan. Only for named (non-dotfile) directories, so a folder of
        //    source files with public.* UTIs is never mistaken for one.
        if !isDotfile && isNamedContainerCandidate(node.url),
           let vendor = vendorFromContentType(of: node),
           !anyInstalledApp(hasVendor: vendor) {
            return Owner(
                displayName: capitalizeVendor(vendor),
                bundleIdentifier: nil,
                installedURL: nil,
                installedVersion: nil,
                isRunning: false,
                provenance: .contentTypeVendor)
        }

        // 5. A dotfile directory whose binary is on PATH — a live toolchain.
        if isDotfile, let toolchain = toolchainOwner(node.url) {
            return toolchain
        }

        // 6. Unattributed.
        return nil
    }

    // MARK: Resolution steps

    private func bundleIdentifierInPath(_ url: URL) -> String? {
        // The deepest bundle-id-shaped component is the most specific owner.
        url.pathComponents.last { StructuralMarkers.isBundleIdentifierShaped($0) }
    }

    private func isNamedContainerCandidate(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        if containerRoots.contains(parent) { return true }
        // A direct, non-dotfile child of home — where an absent vendor's data tree lives.
        return parent == home.path
    }

    private func installedAppMatching(name: String) -> InstalledApp? {
        // Try the directory name as-is and, if it carries a version, its base:
        // `GoLand2026.1` → `GoLand`.
        var targets = [name.lowercased()]
        if let base = baseName(strippingVersionFrom: name) {
            targets.append(base.lowercased())
        }
        return cache.installedApps(registry: registry).first { app in
            let appName = app.name.lowercased()
            return targets.contains { target in
                // dir name equals the app name, or the app name is "<dir> <suffix>".
                appName == target
                    || appName.hasPrefix(target + " ")
                    || target.hasPrefix(appName + " ")
            }
        }
    }

    /// The name with a trailing version removed: `GoLand2026.1` → `GoLand`.
    /// Nil when the name carries no version.
    private func baseName(strippingVersionFrom name: String) -> String? {
        guard let range = name.range(of: #"\s?\d+(\.\d+)+$"#, options: .regularExpression) else {
            return nil
        }
        let base = String(name[name.startIndex..<range.lowerBound])
        return base.isEmpty ? nil : base
    }

    private func ownerFromBundleIdentifier(_ bundleID: String, provenance: Owner.Provenance) -> Owner {
        if let url = cache.url(forBundleID: bundleID, registry: registry) {
            let name = url.deletingPathExtension().lastPathComponent
            return Owner(
                displayName: name,
                bundleIdentifier: bundleID,
                installedURL: url,
                installedVersion: cache.version(ofBundleAt: url, registry: registry),
                isRunning: cache.running(registry: registry).contains(bundleID),
                provenance: provenance)
        }
        // Resolved by identifier but not installed — an orphan.
        return Owner(
            displayName: displayName(fromBundleID: bundleID),
            bundleIdentifier: bundleID,
            installedURL: nil,
            installedVersion: nil,
            isRunning: false,
            provenance: provenance)
    }

    private func installedOwner(from app: InstalledApp, provenance: Owner.Provenance) -> Owner {
        Owner(
            displayName: app.name,
            bundleIdentifier: app.bundleIdentifier,
            installedURL: app.url,
            installedVersion: app.version,
            isRunning: app.bundleIdentifier.map { cache.running(registry: registry).contains($0) } ?? false,
            provenance: provenance)
    }

    private func toolchainOwner(_ url: URL) -> Owner? {
        // A dotfile directory `.foo` is owned by the `foo` binary if one is on
        // PATH. The directory name *is* the binary name — a shape, not a table.
        let binaryName = String(url.lastPathComponent.dropFirst())
        guard !binaryName.isEmpty,
              let binary = cache.executableOnPath(named: binaryName, registry: registry)
        else { return nil }
        return Owner(
            displayName: binaryName,
            bundleIdentifier: nil,
            installedURL: binary,
            installedVersion: nil,
            isRunning: false,
            provenance: .toolchainOnPath)
    }

    // MARK: Vendor extraction

    private func vendorFromContentType(of node: Node) -> String? {
        // The node itself, then its direct children (a VM package, a document
        // bundle) — the UTI's vendor label survives the app's removal.
        if let vendor = vendor(fromUTI: cache.spotlightContentType(for: node.url, registry: registry)) {
            return vendor
        }
        for child in node.children.prefix(64) {
            if let vendor = vendor(fromUTI: cache.spotlightContentType(for: child.url, registry: registry)) {
                return vendor
            }
        }
        return nil
    }

    private func vendor(fromUTI uti: String?) -> String? {
        guard let uti else { return nil }
        if Self.genericUTIPrefixes.contains(where: uti.hasPrefix) { return nil }
        let labels = uti.split(separator: ".")
        // com.vendor.product.type → vendor is the second label.
        guard labels.count >= 2 else { return nil }
        return String(labels[1])
    }

    private func anyInstalledApp(hasVendor vendor: String) -> Bool {
        let prefix = "com.\(vendor.lowercased())."
        return cache.installedApps(registry: registry).contains { app in
            (app.bundleIdentifier?.lowercased().hasPrefix(prefix) ?? false)
                || app.name.lowercased().contains(vendor.lowercased())
        }
    }

    // MARK: Display names

    private func displayName(fromBundleID bundleID: String) -> String {
        let labels = bundleID.split(separator: ".")
        // com.docker.docker → "docker"; com.vendor.product → "vendor".
        let vendor = labels.count >= 2 ? String(labels[1]) : bundleID
        return capitalizeVendor(vendor)
    }

    private func capitalizeVendor(_ vendor: String) -> String {
        vendor.isEmpty ? vendor : vendor.prefix(1).uppercased() + vendor.dropFirst()
    }
}

// Per-survey memoisation. Resolving the same bundle id, the same installed-apps
// list, or the same PATH binary once per sweep rather than once per node.
private final class Cache: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String: URL?] = [:]
    private var versions: [String: String?] = [:]
    private var pathBinaries: [String: URL?] = [:]
    private var spotlightIDs: [String: String?] = [:]
    private var spotlightTypes: [String: String?] = [:]
    private var apps: [InstalledApp]?
    private var runningSet: Set<String>?

    func url(forBundleID id: String, registry: AppRegistry) -> URL? {
        memoize(&urls, key: id) { registry.url(forBundleIdentifier: id) }
    }
    func version(ofBundleAt url: URL, registry: AppRegistry) -> String? {
        memoize(&versions, key: url.path) { registry.shortVersion(ofBundleAt: url) }
    }
    func executableOnPath(named name: String, registry: AppRegistry) -> URL? {
        memoize(&pathBinaries, key: name) { registry.executableOnPath(named: name) }
    }
    func spotlightBundleID(for url: URL, registry: AppRegistry) -> String? {
        memoize(&spotlightIDs, key: url.path) { registry.spotlightBundleIdentifier(for: url) }
    }
    func spotlightContentType(for url: URL, registry: AppRegistry) -> String? {
        memoize(&spotlightTypes, key: url.path) { registry.spotlightContentType(for: url) }
    }
    func installedApps(registry: AppRegistry) -> [InstalledApp] {
        lock.lock(); defer { lock.unlock() }
        if let apps { return apps }
        let resolved = registry.installedApplications()
        apps = resolved
        return resolved
    }
    func running(registry: AppRegistry) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        if let runningSet { return runningSet }
        let resolved = registry.runningBundleIdentifiers()
        runningSet = resolved
        return resolved
    }

    private func memoize<V>(_ store: inout [String: V?], key: String, compute: () -> V?) -> V? {
        lock.lock(); defer { lock.unlock() }
        if let cached = store[key] { return cached }
        let value = compute()
        store[key] = value
        return value
    }
}
