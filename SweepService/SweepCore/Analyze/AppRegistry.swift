import Foundation
#if canImport(AppKit)
import AppKit
#endif

// Everything the attributor needs to know about the machine's applications and
// environment, behind one protocol so attribution is testable with a fake and
// never touches NSWorkspace, the filesystem, or Spotlight directly.
//
// This protocol is not a registry of tools. It answers factual questions —
// "is this bundle id installed", "is there a binary named X on PATH" — and knows
// no product by name.
protocol AppRegistry: Sendable {
    /// The installed application for a bundle identifier, or nil if none.
    func url(forBundleIdentifier id: String) -> URL?

    /// Applications found in /Applications and ~/Applications.
    func installedApplications() -> [InstalledApp]

    /// Bundle identifiers of currently running applications.
    func runningBundleIdentifiers() -> Set<String>

    /// `CFBundleShortVersionString` for an installed bundle.
    func shortVersion(ofBundleAt url: URL) -> String?

    /// The URL of an executable named `name` on `PATH`, or nil.
    func executableOnPath(named name: String) -> URL?

    /// `kMDItemCFBundleIdentifier` reported by Spotlight for a node.
    func spotlightBundleIdentifier(for url: URL) -> String?

    /// `kMDItemContentType` (a UTI) reported by Spotlight for a node. Its
    /// reverse-DNS prefix names the vendor even when the app is gone.
    func spotlightContentType(for url: URL) -> String?
}

#if canImport(AppKit)
// The real registry over NSWorkspace, LaunchServices, Spotlight, and PATH.
struct SystemAppRegistry: AppRegistry {

    func url(forBundleIdentifier id: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    func installedApplications() -> [InstalledApp] {
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        var apps: [InstalledApp] = []
        for root in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil) else { continue }
            for entry in entries where entry.pathExtension == "app" {
                guard let bundle = Bundle(url: entry) else { continue }
                let name = entry.deletingPathExtension().lastPathComponent
                apps.append(InstalledApp(
                    name: name,
                    bundleIdentifier: bundle.bundleIdentifier,
                    url: entry,
                    version: bundle.infoDictionary?["CFBundleShortVersionString"] as? String))
            }
        }
        return apps
    }

    func runningBundleIdentifiers() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    func shortVersion(ofBundleAt url: URL) -> String? {
        Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    func executableOnPath(named name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    func spotlightBundleIdentifier(for url: URL) -> String? {
        metadata(url, attribute: kMDItemCFBundleIdentifier)
    }

    func spotlightContentType(for url: URL) -> String? {
        metadata(url, attribute: kMDItemContentType)
    }

    private func metadata(_ url: URL, attribute: CFString) -> String? {
        guard let item = MDItemCreate(nil, url.path as CFString) else { return nil }
        return MDItemCopyAttribute(item, attribute) as? String
    }
}
#endif
