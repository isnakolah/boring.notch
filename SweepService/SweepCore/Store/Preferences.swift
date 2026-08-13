import Foundation

// User-tunable survey settings, persisted so they survive relaunch. Kept as plain
// data so the survey pipeline can be built from them off the main actor.
//
// The exclusion list here is *add-only* with respect to C4: it holds only the
// user's additions. The built-in C4 exclusions live in `Exclusions` as constants
// and are never represented here, so there is no way to remove one — the contract
// that the exclusion list ratchets one direction is structural, not enforced by a
// guard that could be forgotten.
struct Preferences: Equatable, Sendable {
    var candidateThresholdBytes: Int64
    var extraScanRoots: [String]
    var userExclusions: [String]
    var resurveyInterval: TimeInterval

    static let `default` = Preferences(
        candidateThresholdBytes: 500 * 1024 * 1024,
        extraScanRoots: [],
        userExclusions: [],
        resurveyInterval: 5 * 60)

    // MARK: Persistence

    private enum Key {
        static let threshold = "sweep.survey.thresholdBytes"
        static let scanRoots = "sweep.survey.extraScanRoots"
        static let exclusions = "sweep.survey.userExclusions"
        static let resurvey = "sweep.survey.resurveyInterval"
    }

    static func load(from defaults: UserDefaults) -> Preferences {
        var prefs = Preferences.default
        if let t = defaults.object(forKey: Key.threshold) as? NSNumber { prefs.candidateThresholdBytes = t.int64Value }
        if let roots = defaults.stringArray(forKey: Key.scanRoots) { prefs.extraScanRoots = roots }
        if let ex = defaults.stringArray(forKey: Key.exclusions) { prefs.userExclusions = ex }
        if let r = defaults.object(forKey: Key.resurvey) as? NSNumber, r.doubleValue > 0 { prefs.resurveyInterval = r.doubleValue }
        return prefs
    }

    func persist(to defaults: UserDefaults) {
        defaults.set(NSNumber(value: candidateThresholdBytes), forKey: Key.threshold)
        defaults.set(extraScanRoots, forKey: Key.scanRoots)
        defaults.set(userExclusions, forKey: Key.exclusions)
        defaults.set(NSNumber(value: resurveyInterval), forKey: Key.resurvey)
    }

    // MARK: Derived survey inputs

    func surveyConfig(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SurveyConfig {
        var config = SurveyConfig.standard(
            home: home,
            userScanRoots: extraScanRoots.map { URL(fileURLWithPath: $0) })
        config.candidateThreshold = candidateThresholdBytes
        return config
    }

    func exclusions(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Exclusions {
        Exclusions(home: home, userDefined: userExclusions.map { URL(fileURLWithPath: $0) })
    }

    // MARK: Add-only exclusion editing

    /// Adds a user exclusion. A path already covered by C4 or already added is a
    /// no-op — the list only grows, and never with duplicates.
    func addingExclusion(_ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Preferences {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !userExclusions.contains(standardized) else { return self }
        guard !Exclusions(home: home).contains(url: URL(fileURLWithPath: standardized)) else { return self }
        var copy = self
        copy.userExclusions.append(standardized)
        return copy
    }

    /// Removes a *user* exclusion. It has no effect on the built-in C4 list, which
    /// is not represented here and cannot be removed.
    func removingUserExclusion(_ path: String) -> Preferences {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        var copy = self
        copy.userExclusions.removeAll { $0 == standardized }
        return copy
    }
}
