import Foundation

// Configuration for the survey — thresholds, container roots, and scan roots.
// These are data so they are testable and user-extensible, not constants
// scattered through the walk. None of them names a specific tool: a container
// root is a *shape* (~/Library/Caches holds many tools' caches), never an entry
// for one product.
struct SurveyConfig: Sendable {

    /// The standard nomination depth. Named so the sizer can derive its retention
    /// depth from it without a second copy of the number.
    static let defaultMarkerDepth = 6

    /// A node at or above this allocated size is worth judging on size alone.
    var candidateThreshold: Int64

    /// How deep the nomination pass descends looking for structural markers.
    /// Container children and markers live near the top of these trees; an
    /// unbounded descent would stat the entire disk for no gain.
    var markerDepth: Int

    /// Directories whose *direct children* are each worth judging, because the
    /// directory exists to hold many independent tools' data. Expressed relative
    /// to home, resolved per-machine.
    var containerRootsRelativeToHome: [String]

    /// Where the survey starts. Home plus the shared developer directory; the
    /// user may add more in Settings.
    var scanRoots: [URL]

    static func standard(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        userScanRoots: [URL] = []
    ) -> SurveyConfig {
        SurveyConfig(
            candidateThreshold: 500 * 1024 * 1024,      // 500 MB
            markerDepth: defaultMarkerDepth,
            containerRootsRelativeToHome: [
                "Library/Caches",
                "Library/Application Support",
                "Library/Containers",
            ],
            scanRoots: [home, URL(fileURLWithPath: "/Library/Developer")] + userScanRoots)
    }

    func containerRoots(home: URL) -> [URL] {
        containerRootsRelativeToHome.map {
            home.appendingPathComponent($0).standardizedFileURL
        }
    }

    /// A direct child of home whose name begins with a dot is itself a container
    /// root — a dotfile directory holds one tool's data, so the directory *is*
    /// the candidate, judged as a whole.
    func isDotfileContainerChild(_ url: URL, home: URL) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        return parent.path == home.standardizedFileURL.path
            && url.lastPathComponent.hasPrefix(".")
    }
}
