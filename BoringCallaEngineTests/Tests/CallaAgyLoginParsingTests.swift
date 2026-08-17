import XCTest
@testable import CallaEngineValidation

/// Pinned against output captured from the real `agy` CLI (v1.1.13). This parses
/// another program's console text, so the point of these tests is to fail loudly
/// when an upgrade changes the wording — rather than the app silently losing the
/// ability to sign in.
final class CallaAgyLoginParsingTests: XCTestCase {
    /// Verbatim, including the blank lines and two-space indent.
    private let realPrompt = """
    Authentication required. Please visit the URL to log in:
      https://accounts.google.com/o/oauth2/auth?access_type=offline&client_id=1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com&code_challenge=2P_1NokAz4hOZozlGNTR6bCIjyhUd3rQ9Yi8FJ0DM20&code_challenge_method=S256&prompt=consent&redirect_uri=https%3A%2F%2Fantigravity.google%2Foauth-callback&response_type=code&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcloud-platform+openid&state=oJO77n3YnjaD-C5U6_BoXQ

    Waiting for authentication (timeout 60s)...
    Or, paste the authorization code here and press Enter:
    """

    func testExtractsTheSignInURL() throws {
        let url = try XCTUnwrap(CallaAgyLoginParsing.signInURL(in: realPrompt))
        XCTAssertTrue(url.hasPrefix("https://accounts.google.com/o/oauth2/auth?"))
        // The whole query must survive: without `state` and `code_challenge` the
        // callback cannot complete.
        XCTAssertTrue(url.contains("state=oJO77n3YnjaD-C5U6_BoXQ"))
        XCTAssertTrue(url.contains("code_challenge="))
        XCTAssertTrue(url.contains("redirect_uri=https%3A%2F%2Fantigravity.google%2Foauth-callback"))
        // And it must stop at the line end rather than swallowing what follows.
        XCTAssertFalse(url.contains("Waiting"))
        XCTAssertFalse(url.contains("\n"))
    }

    func testNoURLBeforeItHasBeenPrinted() {
        XCTAssertNil(CallaAgyLoginParsing.signInURL(in: ""))
        XCTAssertNil(CallaAgyLoginParsing.signInURL(in: "Authentication required. Please visit"))
        // A different Google URL is not the sign-in URL.
        XCTAssertNil(CallaAgyLoginParsing.signInURL(in: "see https://accounts.google.com/signin/help"))
    }

    func testURLSurvivesPartialAndQuotedOutput() throws {
        // The pty arrives in chunks, so the buffer is often mid-stream.
        let chunked = "…log in:\n  https://accounts.google.com/o/oauth2/auth?client_id=x&state=y\nWaiting"
        XCTAssertEqual(
            try XCTUnwrap(CallaAgyLoginParsing.signInURL(in: chunked)),
            "https://accounts.google.com/o/oauth2/auth?client_id=x&state=y")
    }

    func testDetectsThePastePrompt() {
        XCTAssertTrue(CallaAgyLoginParsing.isAwaitingCode(realPrompt))
        XCTAssertFalse(CallaAgyLoginParsing.isAwaitingCode("Waiting for authentication (timeout 60s)..."))
    }

    /// The exact text a wrong code produces, confirmed by pasting one.
    func testClassifiesARejectedCode() {
        let output = """
        Or, paste the authorization code here and press Enter:
        bogus-code-123
        Error: authentication failed: token exchange failed: oauth2: "invalid_grant" "Malformed auth code."
        """
        let message = CallaAgyLoginParsing.failureMessage(from: output, status: 1)
        XCTAssertTrue(message.contains("not valid"), message)
        XCTAssertFalse(message.contains("status"), "an exit code tells the user nothing here")
    }

    func testClassifiesATimeout() {
        let message = CallaAgyLoginParsing.failureMessage(
            from: "Waiting for authentication (timeout 60s)...\nError: authentication timed out.",
            status: 1)
        XCTAssertTrue(message.contains("timed out"), message)
    }

    /// What `agy` says when stdin is not a terminal. No amount of retrying inside
    /// the app fixes this, so it must not be reported as a generic failure.
    func testClassifiesARefusalToRunNonInteractively() {
        let message = CallaAgyLoginParsing.failureMessage(
            from: "Error: authentication required. Run 'agy' to log in, then retry.",
            status: 1)
        XCTAssertTrue(message.contains("terminal"), message)
    }

    func testUnrecognisedFailureStillNamesTheExitCode() {
        let message = CallaAgyLoginParsing.failureMessage(from: "something new went wrong", status: 3)
        XCTAssertTrue(message.contains("3"), message)
    }

    // MARK: - The TUI (the flow the app actually drives)

    /// Verbatim from the TUI, which is used instead of print mode because print
    /// mode kills the flow after 60s — shorter than a human browser round-trip.
    private let tuiMenu = """
     Welcome to the Antigravity CLI. You are currently not signed in.

     ⣷  Signing in... Select login method:
     > 1. Google OAuth
    2. Use a Google Cloud project

     [Use arrow keys to navigate, Enter to select]
    """

    func testDetectsTheLoginMethodMenu() {
        XCTAssertTrue(CallaAgyLoginParsing.isAtLoginMethodMenu(tuiMenu))
        XCTAssertFalse(CallaAgyLoginParsing.isAtLoginMethodMenu("Welcome to the Antigravity CLI."))
    }

    /// The regression that produced a 1415-character "URL": the TUI draws a
    /// divider immediately after the link, and box-drawing glyphs are not
    /// whitespace, so a `[^\s]+` match ran straight through them.
    func testURLIsNotExtendedByBoxDrawingGlyphs() throws {
        let screen = "  https://accounts.google.com/o/oauth2/auth?client_id=x&state=abc"
            + String(repeating: "─", count: 200)
        let url = try XCTUnwrap(CallaAgyLoginParsing.signInURL(in: screen))
        XCTAssertEqual(url, "https://accounts.google.com/o/oauth2/auth?client_id=x&state=abc")
        XCTAssertFalse(url.contains("─"))
    }

    func testURLStopsAtSurroundingPunctuationTheTUIDraws() throws {
        let url = try XCTUnwrap(CallaAgyLoginParsing.signInURL(
            in: "│ https://accounts.google.com/o/oauth2/auth?a=1&b=2 │"))
        XCTAssertEqual(url, "https://accounts.google.com/o/oauth2/auth?a=1&b=2")
    }

    /// How the TUI reports a bad code, as opposed to print mode's `Error:` line.
    func testDetectsAndClassifiesTheTUIErrorLine() {
        let screen = """
        M Got an error: token exchange failed: oauth2: "invalid_grant" "Malformed auth code."
         Press any key to go back.
        """
        XCTAssertTrue(CallaAgyLoginParsing.hasError(screen))
        XCTAssertTrue(CallaAgyLoginParsing.failureMessage(from: screen, status: 0).contains("not valid"))
        XCTAssertFalse(CallaAgyLoginParsing.hasError(tuiMenu))
    }

    func testSuccessIsRecognised() {
        XCTAssertTrue(CallaAgyLoginParsing.didSucceed("Print mode: silent auth succeeded"))
        XCTAssertFalse(CallaAgyLoginParsing.didSucceed(realPrompt))
    }
}
