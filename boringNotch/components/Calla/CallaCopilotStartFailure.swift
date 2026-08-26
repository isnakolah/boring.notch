//
//  CallaCopilotStartFailure.swift
//  boringNotch
//

import SwiftUI

/// Why a call did not start, and what can be done about it.
///
/// The first version of the failure panel had one state: "it failed", the raw
/// `lastResult` printed underneath, and a Try again button. That reads badly and
/// in one case reads *wrongly* — the engine refuses a second host with "Call
/// already running", and a panel headlined "the capture host never started"
/// while its footnote says a call is already running is telling the reader two
/// opposite things at once. Trying again does nothing, because the refusal will
/// be identical.
///
/// So the engine's replies are classified. Every case here is a real string the
/// engine can put in `copilotResult` on the start path, or a state the client
/// can reach on its own, and each one carries the action that actually resolves
/// it rather than a Try again that cannot work.
enum CopilotStartFailure: Equatable {
    /// A host process is alive that this app cannot see as a call. Usually a
    /// prewarm or a host left behind by a previous launch of Boring.
    case alreadyRunning
    /// The Calla runtime is not deployed.
    case hostNotInstalled
    /// The persona or guidance in Settings failed validation.
    case promptsRejected
    /// The meeting attached to the call failed validation. The call can start
    /// without one.
    case meetingRejected
    /// The gateway URL in the build is not a valid route.
    case gatewayRouteInvalid
    /// The host came up and then exited.
    case hostStopped
    /// The host could not be spawned at all.
    case couldNotSpawn(String)
    /// macOS has not granted the capture host what it records with.
    case permissionsMissing
    /// Nothing was ever reported and the launch deadline expired.
    case timedOut
    /// Something the engine said that is not in the list above.
    case unknown(String)

    /// Reads the engine's own words. Matching on prefixes rather than equality
    /// because three of these interpolate a detail onto the end, and matching
    /// the whole string would silently fall through to `.unknown` the first time
    /// one of them gained a full stop.
    static func classify(reason: String?, copilot: CallaCopilotStatus) -> CopilotStartFailure {
        let text = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if text.hasPrefix("Call already running") { return .alreadyRunning }
        if text.hasPrefix("Call host is not installed") { return .hostNotInstalled }
        if text.hasPrefix("Prompt settings were rejected") { return .promptsRejected }
        if text.hasPrefix("The meeting details were rejected") { return .meetingRejected }
        if text.hasPrefix("Copilot gateway route is not valid") { return .gatewayRouteInvalid }
        if text.hasPrefix("Call host stopped") { return .hostStopped }
        if text.hasPrefix("Could not start call host") {
            return .couldNotSpawn(String(text.dropFirst("Could not start call host: ".count)))
        }

        // Nothing useful said. The grants are the likeliest silent cause, and
        // they are worth naming because macOS will not prompt for them twice.
        if !copilot.hostNotInstalledOrUnknown,
           copilot.hostPermissionsKnown, !copilot.hostMicGranted {
            return .permissionsMissing
        }
        if text.isEmpty { return .timedOut }
        return .unknown(text)
    }

    /// One line, in the concrete, saying what happened.
    var headline: String {
        switch self {
        case .alreadyRunning: "A call is already running"
        case .hostNotInstalled: "The call host is not installed"
        case .promptsRejected: "Your prompt settings were rejected"
        case .meetingRejected: "The meeting details were rejected"
        case .gatewayRouteInvalid: "The gateway route is not valid"
        case .hostStopped: "The call host stopped"
        case .couldNotSpawn: "The call host could not start"
        case .permissionsMissing: "The capture host has no microphone access"
        case .timedOut: "The call host never reported in"
        case .unknown: "The call could not be started"
        }
    }

    /// What it means and what happens next. Two sentences at most — this sits in
    /// a compact panel, not a dialog.
    func detail(copilot: CallaCopilotStatus) -> String {
        switch self {
        case .alreadyRunning:
            return "A capture host is alive but is not reporting a call, so Boring cannot show it. Ending it and starting again is safe: nothing has been recorded."
        case .hostNotInstalled:
            return "The copilot ships with Boring's Calla runtime. Redeploy Boring to install it."
        case .promptsRejected:
            return "The call was not started. Fix the persona or guidance and press start again."
        case .meetingRejected:
            return "The call was not started. Starting without the meeting attached will work; the copilot just will not have its notes."
        case .gatewayRouteInvalid:
            return "This build's gateway address cannot be parsed, so no remote brain can be reached. Switching answers to this Mac avoids it."
        case .hostStopped:
            return "It came up and then exited. Nothing was recorded. Trying again is usually enough; if it is not, the engine's diagnostics say more."
        case let .couldNotSpawn(reason):
            return reason.isEmpty ? "The process could not be launched." : reason
        case .permissionsMissing:
            let missing = copilot.hostScreenGranted
                ? "microphone access"
                : "microphone and screen recording access"
            return "macOS has not given the capture host \(missing), and it will not ask twice. Grant it by hand, then start the call again."
        case .timedOut:
            return "Thirty seconds passed with no word from the capture host. Nothing was recorded."
        case let .unknown(text):
            return text
        }
    }

    /// The action that actually resolves this, where there is one. Never a Try
    /// again that is known in advance to fail the same way.
    var remedy: Remedy? {
        switch self {
        case .alreadyRunning: .endAndRetry
        case .hostNotInstalled: nil
        case .promptsRejected: .openSettings(.copilotPrompts, "Open Prompts")
        case .meetingRejected: .retry
        case .gatewayRouteInvalid: .openSettings(.copilotModels, "Open Models")
        case .hostStopped: .retry
        case .couldNotSpawn: .retry
        case .permissionsMissing: .openSettings(.copilotCall, "Open Permissions")
        case .timedOut: .retry
        case .unknown: .retry
        }
    }

    /// Whether the engine has already refused for good, as opposed to a start
    /// that is merely still in flight.
    ///
    /// The client claims a launch optimistically and holds it for thirty seconds
    /// so a cold model load and a TCC prompt both fit inside it. That is right
    /// for a slow start and wrong for a refusal: the engine answers "Call
    /// already running" in milliseconds, and waiting out the deadline showed
    /// half a minute of a progress bar for a call that was never going to exist.
    /// These are the replies that mean it is over now.
    var isTerminalRefusal: Bool {
        switch self {
        case .alreadyRunning, .hostNotInstalled, .promptsRejected,
             .meetingRejected, .gatewayRouteInvalid, .couldNotSpawn:
            true
        // Not these: `hostStopped` can arrive for a *previous* call while this
        // one is still coming up, and the other two are the absence of an answer
        // rather than an answer.
        case .hostStopped, .permissionsMissing, .timedOut, .unknown:
            false
        }
    }

    enum Remedy: Equatable {
        /// Press start again, unchanged.
        case retry
        /// Bring down whatever is holding the host, then start again.
        case endAndRetry
        /// The fix is a setting, so go to the page that holds it.
        case openSettings(SettingsPage, String)

        var title: String {
            switch self {
            case .retry: "Try again"
            case .endAndRetry: "End it and start over"
            case let .openSettings(_, title): title
            }
        }
    }
}

private extension CallaCopilotStatus {
    /// Whether the "no host" explanation is already the better one.
    var hostNotInstalledOrUnknown: Bool { !available }
}
