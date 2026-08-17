import Darwin
import XCTest
@testable import IntelligenceProviders

/// The bug this guards against presents as a lie: Settings reporting "signed in"
/// while a call opens a browser demanding a fresh sign-in.
///
/// `agy` keeps credentials in `$HOME/.gemini`. The app is sandboxed, so
/// `NSHomeDirectory()` there is the container — passing it as `HOME` to a spawned
/// `agy` points it at a `.gemini` that does not exist, so it starts a new OAuth
/// flow, while an unsandboxed process reading the real path reports credentials
/// as present. Both are "right"; they are answering from different homes.
final class AgyEnvironmentTests: XCTestCase {
    func testUserHomeComesFromThePasswdDatabaseNotTheSandbox() throws {
        let pw = try XCTUnwrap(getpwuid(getuid()))
        let expected = String(cString: try XCTUnwrap(pw.pointee.pw_dir))
        XCTAssertEqual(AgyEnvironment.userHome, expected)
        // The whole point: never a container path, whoever is asking.
        XCTAssertFalse(AgyEnvironment.userHome.contains("/Library/Containers/"))
    }

    func testSpawnEnvironmentPinsHomeToTheRealOne() {
        let environment = AgyEnvironment.processEnvironment()
        XCTAssertEqual(environment["HOME"], AgyEnvironment.userHome)
    }

    func testCredentialPathsHangOffThatSameHome() {
        XCTAssertEqual(
            AgyEnvironment.credentialsFile.path,
            AgyEnvironment.userHome + "/.gemini/oauth_creds.json")
        XCTAssertEqual(
            AgyEnvironment.accountsFile.path,
            AgyEnvironment.userHome + "/.gemini/google_accounts.json")
        // A child writing credentials and the app reporting on them must not be
        // able to disagree about where they live.
        XCTAssertTrue(AgyEnvironment.credentialsFile.path.hasPrefix(AgyEnvironment.userHome))
    }

    func testSpawnEnvironmentRepairsAMinimalGUIPath() {
        let environment = AgyEnvironment.processEnvironment()
        let path = environment["PATH"] ?? ""
        // A GUI app inherits a stub PATH; agy shells out to git and friends.
        XCTAssertTrue(path.contains("/usr/bin"), path)
        XCTAssertTrue(path.contains("/bin"), path)
    }

    func testExtraVariablesWinOverDefaults() {
        let environment = AgyEnvironment.processEnvironment(adding: ["ANTIGRAVITY_LS_ADDRESS": "127.0.0.1:1234"])
        XCTAssertEqual(environment["ANTIGRAVITY_LS_ADDRESS"], "127.0.0.1:1234")
        XCTAssertEqual(environment["HOME"], AgyEnvironment.userHome)
    }
}
