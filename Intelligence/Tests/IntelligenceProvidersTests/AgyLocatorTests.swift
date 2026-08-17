import XCTest
@testable import IntelligenceProviders

/// Picking the `agy` to run is not obvious, and getting it wrong is silent.
///
/// This machine had two installs: a Homebrew cask at 1.0.6 and a self-installed
/// 1.1.13. Version 1.0.6 has no `--output-format`, so both transports fail on it —
/// yet it launches, answers `--version`, and looks installed. Choosing the first
/// path that happened to exist meant a call transcribed perfectly and never
/// answered.
final class AgyLocatorTests: XCTestCase {
    func testVersionParsingHandlesWhatTheCLIActuallyPrints() {
        XCTAssertEqual(AgyLocator.versionComponents("1.1.13"), [1, 1, 13])
        XCTAssertEqual(AgyLocator.versionComponents("1.0.6"), [1, 0, 6])
        XCTAssertEqual(AgyLocator.versionComponents("agy version 1.2.0"), [1, 2, 0])
        XCTAssertEqual(AgyLocator.versionComponents("nonsense"), [])
    }

    func testComparisonOrdersByPrecedenceNotStringOrder() {
        // "1.1.13" sorts before "1.1.2" as text, which is the trap.
        XCTAssertEqual(AgyLocator.compare([1, 1, 13], [1, 1, 2]), 1)
        XCTAssertEqual(AgyLocator.compare([1, 0, 6], [1, 1, 0]), -1)
        XCTAssertEqual(AgyLocator.compare([1, 1], [1, 1, 0]), 0)
        XCTAssertEqual(AgyLocator.compare([2], [1, 9, 9]), 1)
    }

    func testSupportTracksTheFlagBothTransportsNeed() {
        // `--output-format` arrived in the 1.1 line.
        XCTAssertFalse(AgyLocator.Installation(path: "/x", version: "1.0.6").isSupported)
        XCTAssertTrue(AgyLocator.Installation(path: "/x", version: "1.1.0").isSupported)
        XCTAssertTrue(AgyLocator.Installation(path: "/x", version: "1.1.13").isSupported)
        XCTAssertFalse(AgyLocator.Installation(path: "/x", version: "unparseable").isSupported)
    }

    func testKnownPathsAreExpandedFromThePasswdDatabase() throws {
        // Never the container: `NSHomeDirectory()` in a sandboxed process points at
        // `~/Library/Containers/…`, where no install exists, and the search then
        // fell through to whatever else was on disk.
        XCTAssertTrue(AgyLocator.knownPaths.contains("~/.local/bin/agy"))
        guard let best = AgyLocator.bestInstallation() else {
            throw XCTSkip("no supported agy on this machine")
        }
        XCTAssertFalse(best.path.contains("/Library/Containers/"))
        XCTAssertTrue(best.isSupported, "chose \(best.version) at \(best.path)")
    }

    /// Whatever is installed here, the newest supported one must win.
    func testNewestSupportedInstallIsChosen() throws {
        let installs = AgyLocator.installations()
        try XCTSkipIf(installs.count < 2, "needs two installs to be meaningful")
        let chosen = try XCTUnwrap(AgyLocator.bestInstallation())
        for other in installs where other.isSupported {
            XCTAssertGreaterThanOrEqual(
                AgyLocator.compare(chosen.components, other.components), 0,
                "chose \(chosen.version) over \(other.version)")
        }
    }
}
