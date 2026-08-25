import CallaContracts
import XCTest
@testable import CallaCallHostKit

/// When the gateway socket opens, and — more importantly — when it must not.
///
/// The behaviour these pin down replaced a socket that connected on every call
/// regardless of settings, received every transcript turn whether or not the
/// gateway was allowed to answer, and was awaited before either microphone
/// opened. The last of those cost ~1s of measured startup; the second meant
/// "fall back to the gateway: off" still sent the call to it.
final class GatewayStandbyTests: XCTestCase {
    private func configuration(
        provider: CopilotAdvisor.Provider,
        fallback: Bool,
        standby: GatewayStandby
    ) -> CallSession.Configuration {
        CallSession.Configuration(
            gatewayURL: URL(string: "wss://example.invalid/stream")!,
            provider: provider,
            fallbackToGateway: fallback,
            gatewayStandby: standby)
    }

    // MARK: - Resolution

    func testFallbackOffForcesStandbyOff() {
        for requested in GatewayStandby.allCases {
            let config = configuration(provider: .local, fallback: false, standby: requested)
            XCTAssertEqual(
                config.gatewayStandby, .off,
                "a gateway that may never answer must not be kept warm (requested \(requested))")
        }
    }

    func testGatewayProviderIsAlwaysWarm() {
        // Not standing by — it is the brain. Even an explicit `off` cannot leave
        // a gateway-provider call with no socket, which would be a call that can
        // never answer anything.
        for requested in GatewayStandby.allCases {
            let config = configuration(provider: .gateway, fallback: false, standby: requested)
            XCTAssertEqual(config.gatewayStandby, .warm)
        }
    }

    func testLocalWithFallbackKeepsTheRequestedMode() {
        for requested in GatewayStandby.allCases {
            let config = configuration(provider: .local, fallback: true, standby: requested)
            XCTAssertEqual(config.gatewayStandby, requested)
        }
    }

    func testDefaultIsWarm() {
        let config = CallSession.Configuration(gatewayURL: URL(string: "wss://example.invalid")!)
        XCTAssertEqual(config.gatewayStandby, .warm,
                       "the default must match what every host did before this was a setting")
    }

    // MARK: - Spelling

    /// The command line says `on-failure`; JSON and `UserDefaults` say the raw
    /// value. Both have to land on the same mode, or a setting silently resolves
    /// to the default in the host.
    func testNamedAcceptsBothSpellings() {
        XCTAssertEqual(GatewayStandby.named("on-failure"), .onFailure)
        XCTAssertEqual(GatewayStandby.named("onFailure"), .onFailure)
        XCTAssertEqual(GatewayStandby.named("off"), .off)
        XCTAssertEqual(GatewayStandby.named("warm"), .warm)
    }

    func testNamedRejectsAnythingElse() {
        XCTAssertNil(GatewayStandby.named(nil))
        XCTAssertNil(GatewayStandby.named(""))
        XCTAssertNil(GatewayStandby.named("on_failure"))
        XCTAssertNil(GatewayStandby.named("always"))
    }

    func testArgumentRoundTripsThroughNamed() {
        for mode in GatewayStandby.allCases {
            XCTAssertEqual(GatewayStandby.named(mode.argument), mode)
        }
    }

    // MARK: - Startup progress

    /// The panel draws `gatewayWarm == nil` as "not part of this call" and
    /// `false` as "connecting". Collapsing them would make a deliberately local
    /// call look like one whose gateway had failed to come up.
    func testStartupProgressDistinguishesAbsentFromPending() {
        let absent = CallStartupProgress(stage: .model, gatewayWarm: nil)
        let pending = CallStartupProgress(stage: .model, gatewayWarm: false)
        XCTAssertNotEqual(absent, pending)
        XCTAssertNil(absent.gatewayWarm)
        XCTAssertEqual(pending.gatewayWarm, false)
    }

    /// A host older than the checklist writes no `startup` key at all, and that
    /// must decode rather than throwing the whole status away.
    func testLifecycleDecodesWithoutStartup() throws {
        let json = """
        {"contractVersion":2,"callID":"call-1","generation":3,"state":"capturing",
         "updatedAt":0,"capture":{"microphone":true,"systemAudio":true}}
        """
        let decoded = try JSONDecoder().decode(CallLifecycleSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(decoded.startup)
        XCTAssertEqual(decoded.state, .capturing)
    }

    func testStartingIsADistinctLifecycleState() {
        // The engine reports `starting` and `running` as mutually exclusive, so a
        // state that decoded as something else would draw a booting host as live.
        XCTAssertEqual(CallLifecycleState(rawValue: "starting"), .starting)
        XCTAssertNotEqual(CallLifecycleState.starting, .ready)
    }
}
