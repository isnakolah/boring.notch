import Foundation

// The last analysis, on disk, so opening the popover after a restart shows
// findings immediately instead of a progress bar (C8: a file written when a
// survey finishes and read when the app launches — no daemon, no timer, no
// network).
//
// **What is cached is the conclusion, not the tree.** An earlier design cached
// the sized tree as well, so a survey could re-walk only the directories whose
// mtime had changed. That does not work on this filesystem, and the reason is
// worth recording where the next person will look for it: a directory's mtime
// records changes to *its own entries*, and nothing more. Measured here, a file
// grown from 5 MB to 50 MB moved no mtime at all — not its parent's, not any
// ancestor's — and a file added three levels down moved only the mtime of the
// directory it was added to. Reusing a subtree because its mtime matched would
// therefore report a stale size for a disk image growing in place, which is the
// exact case this tool exists to catch. See P-007.
//
// So the cache answers "show me what you found last time, now" and the refresh
// behind it is an honest full walk at `.utility` — which Phase 12 made cheap
// enough (33 s on this machine) that it can run unnoticed while the cached
// result is on screen.
struct SurveyCache {

    /// Bumped whenever the encoded shape changes. A mismatch discards the cache
    /// rather than attempting a migration: the cost of being wrong is a stale
    /// figure presented as current, and the cost of discarding is one walk.
    static let schemaVersion = 1

    struct Snapshot: Codable, Equatable {
        var schemaVersion: Int
        var generatedAt: Date
        /// The survey configuration this result came from. A cache produced under
        /// different settings describes a different question and is discarded.
        var fingerprint: String
        var targets: [Target]
        var unreadableRoots: [URL]
    }

    private let url: URL

    init(fileURL: URL? = nil) {
        self.url = fileURL ?? SurveyCache.defaultURL()
    }

    static func defaultURL() -> URL {
        SweepStorage.url("survey.json")
    }

    /// The configuration fingerprint for a set of preferences. Plain text rather
    /// than a hash so a stale cache can be diagnosed by reading the file.
    static func fingerprint(for preferences: Preferences,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let config = preferences.surveyConfig(home: home)
        let roots = config.scanRoots.map(\.path).sorted().joined(separator: ",")
        let exclusions = preferences.userExclusions.sorted().joined(separator: ",")
        return "v\(schemaVersion)|threshold=\(preferences.candidateThresholdBytes)"
            + "|depth=\(config.markerDepth)|roots=\(roots)|exclusions=\(exclusions)"
    }

    /// The cached analysis, or nil when there is none, it cannot be read, it was
    /// written by a different schema, or it answers a different configuration.
    /// Every one of those is a plain "no cache" — never a partial load.
    func load(fingerprint: String) -> AnalysisResult? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder.cacheDecoder.decode(Snapshot.self, from: data),
              snapshot.schemaVersion == Self.schemaVersion,
              snapshot.fingerprint == fingerprint
        else { return nil }

        // The volume is deliberately not cached: it is a handful of stat calls,
        // it changes constantly, and a stale free-space figure is exactly the
        // kind of number this project refuses to show.
        return AnalysisResult(
            volume: nil,
            targets: snapshot.targets,
            unreadableRoots: snapshot.unreadableRoots,
            generatedAt: snapshot.generatedAt)
    }

    /// Writes the analysis. Failure is silent by design — a cache that cannot be
    /// written costs a walk next launch, and there is nothing the user could do
    /// about it that is worth an error banner.
    func save(_ result: AnalysisResult, fingerprint: String) {
        let snapshot = Snapshot(
            schemaVersion: Self.schemaVersion,
            generatedAt: result.generatedAt,
            fingerprint: fingerprint,
            targets: result.targets,
            unreadableRoots: result.unreadableRoots)
        guard let data = try? JSONEncoder.cacheEncoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // There is deliberately no `clear()`. Deleting a file here would put a
    // deletion call outside `Reclaim/`, which the acceptance gate forbids and
    // which is worth keeping literal — the cache does not need one anyway: it
    // invalidates itself whenever the schema or the configuration changes, and a
    // stale file that never matches is simply never read.
}

private extension JSONEncoder {
    static var cacheEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var cacheDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
