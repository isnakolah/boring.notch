import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// The choices that were previously compiled in.
///
/// Which applications Calla may look at, how much detail leaves this Mac, and
/// how the overlay behaves were all constants in the source. They are the
/// user's decisions, not the build's, so they live here and are surfaced in the
/// menu bar. Everything persists in the host's own preferences domain.
@MainActor
final class TutorSettings: ObservableObject {
    static let shared = TutorSettings()

    /// Applications Calla is permitted to observe. A lesson may narrow this,
    /// never widen it.
    @Published var allowedBundleIDs: [String] {
        didSet { defaults.set(allowedBundleIDs, forKey: Key.allowedBundleIDs) }
    }

    /// Show the overlay only while the application being taught is in front.
    /// Off keeps it on screen wherever the learner goes, which is useful when
    /// following a lesson across two applications.
    /// How wide the lesson card is drawn, in points.
    ///
    /// A step's words are the thing the learner is actually reading, and how
    /// much of a line they get is a property of the screen and the eyes in front
    /// of it rather than something this app can pick once for everyone.
    @Published var tooltipWidth: Int {
        didSet {
            defaults.set(tooltipWidth, forKey: Key.tooltipWidth)
            PointerOverlay.shared.setTooltipWidth(tooltipWidth)
        }
    }
    /// Hide the tooltip while the learner's own pointer is over it, so it stops
    /// covering what is underneath. The pointer itself never hides.
    @Published var hideTooltipOnHover: Bool {
        didSet { defaults.set(hideTooltipOnHover, forKey: Key.hideTooltipOnHover) }
    }

    // Scoping the overlay to the application being taught is deliberately not a
    // preference. Calla annotating a window it is not teaching is a bug, not a
    // taste, so the overlay is always confined to that window and always hides
    // when the learner looks elsewhere.

    /// Long edge, in pixels, of the window capture sent for a lesson. Smaller
    /// keeps less legible detail off the network; larger helps the model read
    /// small labels.
    @Published var captureLongEdge: Int {
        didSet { defaults.set(captureLongEdge, forKey: Key.captureLongEdge) }
    }

    /// Point size of the pointer Calla draws. Larger is easier to follow on a
    /// dense interface; smaller covers less of it.
    @Published var cursorSize: Int {
        didSet { defaults.set(cursorSize, forKey: Key.cursorSize) }
    }

    /// Opacity of the lesson tooltip. A slightly translucent tooltip leaves
    /// more of the taught interface visible without making its text hard to
    /// read.
    @Published var tooltipOpacity: Double {
        didSet { defaults.set(tooltipOpacity, forKey: Key.tooltipOpacity) }
    }

    /// The small capsule naming what Calla is doing. Useful while learning what
    /// Calla does, noise once that is obvious.
    @Published var showStatusHUD: Bool {
        didSet { defaults.set(showStatusHUD, forKey: Key.showStatusHUD) }
    }

    // Two preferences used to live here and have been removed rather than
    // implemented: `overlayFollowsFocus` and `hideTooltipWhenIdle`. Both were
    // read by nothing. The first was answered for good by confining the overlay
    // to the taught window always — annotating a window Calla is not teaching is
    // a bug rather than a taste — and the second was a switch on the General
    // pane that had never once changed what the renderer did, because the
    // renderer has no notion of a lesson going quiet.

    /// Who is being taught, across lessons.
    ///
    /// A lesson's session id is deliberately short-lived — that is what keeps a
    /// transcript from running forever — so anything worth remembering about the
    /// learner has to be keyed on something that is not it. Minted once, never
    /// shown, and carrying nothing about the person: it exists so Calla's notes
    /// about how someone likes to be taught survive the session that learned it.
    let learnerID: String

    @Published private(set) var screenRecordingGranted = false
    /// Accessibility is deliberately requested only when Calla reaches a
    /// locally approved action. Explaining, observing, and pointing do not
    /// need it, so it must not block the ordinary teaching path.
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var accessibilityApprovalNeeded = false

    static let tooltipWidthChoices = [300, 340, 380, 440, 520]
    static let defaultTooltipWidth = 340
    static let captureLongEdgeChoices = [1024, 1600, 2048]
    /// Measured, not guessed: one 1600-pixel capture costs about 27,000 input
    /// tokens and 13 seconds of the model reading it — by some way the most
    /// expensive thing in a teaching step.
    ///
    /// It is still the right default. 1024 saves roughly 60% of the pixels and
    /// spends the saving in the wrong place: where a lesson runs in an
    /// application that exposes no Accessibility controls, nothing corrects the
    /// model's estimate and the pointer lands exactly where the picture let it
    /// guess. 2048 is available for genuinely small text, and costs about 44,000
    /// tokens a look.
    static let defaultCaptureLongEdge = 1600
    static let cursorSizeChoices = [24, 30, 38]
    static let tooltipOpacityChoices: [Double] = [0.85, 0.92, 1.0]
    static let defaultTooltipOpacity = 0.92
    static let defaultAllowedBundleIDs = ["org.blenderfoundation.blender"]

    private let defaults: UserDefaults

    private enum Key {
        static let allowedBundleIDs = "allowedBundleIDs"
        static let hideTooltipOnHover = "hideTooltipOnHover"
        static let tooltipWidth = "tooltipWidth"
        static let captureLongEdge = "captureLongEdge"
        static let cursorSize = "cursorSize"
        static let tooltipOpacity = "tooltipOpacity"
        static let showStatusHUD = "showStatusHUD"
        static let learnerID = "learnerID"
    }

    /// Both ids travel as words in a remote command string, so they are built
    /// from the one alphabet the sender will accept — `^[A-Za-z0-9-]+$` — rather
    /// than trusting a UUID to stay free of anything else.
    static func mintIdentifier(prefix: String) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let suffix = String((0..<12).map { _ in alphabet.randomElement()! })
        return "\(prefix)-\(suffix)"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.array(forKey: Key.allowedBundleIDs) as? [String]
        allowedBundleIDs = stored?.filter { !$0.isEmpty } ?? Self.defaultAllowedBundleIDs
        // `object(forKey:)` rather than `bool(forKey:)`: an absent preference
        // must mean the shipped default, and bool(forKey:) cannot tell absent
        // from false.
        hideTooltipOnHover = defaults.object(forKey: Key.hideTooltipOnHover) as? Bool ?? true
        let width = defaults.object(forKey: Key.tooltipWidth) as? Int ?? Self.defaultTooltipWidth
        tooltipWidth = Self.tooltipWidthChoices.contains(width) ? width : Self.defaultTooltipWidth
        let edge = defaults.object(forKey: Key.captureLongEdge) as? Int ?? Self.defaultCaptureLongEdge
        captureLongEdge = Self.captureLongEdgeChoices.contains(edge) ? edge : Self.defaultCaptureLongEdge
        let size = defaults.object(forKey: Key.cursorSize) as? Int ?? 30
        cursorSize = Self.cursorSizeChoices.contains(size) ? size : 30
        let opacity = defaults.object(forKey: Key.tooltipOpacity) as? Double ?? Self.defaultTooltipOpacity
        tooltipOpacity = Self.tooltipOpacityChoices.contains(opacity) ? opacity : Self.defaultTooltipOpacity
        showStatusHUD = defaults.object(forKey: Key.showStatusHUD) as? Bool ?? true
        if let stored = defaults.string(forKey: Key.learnerID),
           stored.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil {
            learnerID = stored
        } else {
            learnerID = Self.mintIdentifier(prefix: "learner")
            defaults.set(learnerID, forKey: Key.learnerID)
        }
    }

    /// Put appearance and behaviour back to the shipped defaults.
    ///
    /// The allowlist is deliberately not among them any more. This used to reset
    /// it too, from a button labelled "Reset everything" that asked nothing
    /// first, so one click left Calla unable to teach anything at all with no
    /// hint that this was why. Allowing an application is a decision about what
    /// Calla may look at rather than a preference about how it looks, and each
    /// one is removed on its own in the Applications pane.
    func resetToDefaults() {
        hideTooltipOnHover = true
        tooltipWidth = Self.defaultTooltipWidth
        captureLongEdge = Self.defaultCaptureLongEdge
        cursorSize = 30
        tooltipOpacity = Self.defaultTooltipOpacity
        showStatusHUD = true
    }

    /// Reveal the log folder in Finder.
    ///
    /// Reading them is Settings › Logs now. This stays for the cases a reader is
    /// the wrong shape for — attaching a file to a bug report, or opening one in
    /// something that can search a whole history rather than the recent end of it.
    func openLogs() {
        NSWorkspace.shared.open(CallaLog.directory)
    }

    /// What a lesson may actually observe: the applications the user allowed,
    /// narrowed by the ones this lesson asked for. A lesson naming an
    /// application the user has not allowed gets nothing.
    func effectiveAllowlist(requested: Set<String>?) -> Set<String> {
        let allowed = Set(allowedBundleIDs)
        guard let requested, !requested.isEmpty else { return allowed }
        return allowed.intersection(requested)
    }

    func allow(bundleID: String) {
        guard !bundleID.isEmpty, !allowedBundleIDs.contains(bundleID) else { return }
        allowedBundleIDs.append(bundleID)
    }

    func disallow(bundleID: String) {
        allowedBundleIDs.removeAll { $0 == bundleID }
    }

    /// The frontmost application, so the user can allow what they are looking
    /// at instead of typing a bundle identifier.
    func frontmostCandidate() -> (name: String, bundleID: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else { return nil }
        return (app.localizedName ?? bundleID, bundleID)
    }

    /// Course authoring needs only selected app identity and version. Settings
    /// necessarily becomes frontmost before its Import button is pressed, so
    /// requiring target focus here would make authoring impossible. Teaching
    /// still requires a focused app at lesson start.
    func runningAllowedApplication(bundleID expectedBundleID: String) -> (bundleID: String, version: String)? {
        guard allowedBundleIDs.contains(expectedBundleID),
              let app = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleIdentifier == expectedBundleID && !$0.isTerminated
              }),
              let bundleID = app.bundleIdentifier,
              let url = app.bundleURL,
              let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else { return nil }
        return (bundleID, version)
    }

    func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String else {
            return bundleID
        }
        return name
    }

    func refreshPermissionStatus() async {
        // Preflight is cheap and never shows a privacy prompt. The
        // ScreenCaptureKit check confirms the exact API the host will use.
        let preflightGranted = CGPreflightScreenCaptureAccess()
        screenRecordingGranted = preflightGranted ? await WindowCapture.isPermitted() : false
        accessibilityGranted = AXIsProcessTrusted()
    }

    /// Start the standard macOS Screen Recording consent flow at app launch.
    /// If macOS has already shown and denied its one-time sheet, opening the
    /// Privacy pane leaves the owner one click from changing the decision.
    func requestScreenRecordingApproval() {
        guard !CGPreflightScreenCaptureAccess() else {
            Task { await refreshPermissionStatus() }
            return
        }
        _ = CGRequestScreenCaptureAccess()
        openScreenRecordingSettings()
        Task { await refreshPermissionStatus() }
    }

    func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Accessibility has higher authority than capture, so request it only at
    /// the moment an owner-approved semantic action needs it. macOS presents
    /// its own consent sheet and this also opens the exact Settings pane for a
    /// one-click approval after a prior denial.
    func requestAccessibilityApproval() {
        accessibilityApprovalNeeded = true
        // Spell the documented Core Foundation key directly. Swift 6 treats
        // the imported C global as shared mutable state, while the key itself
        // is a fixed API contract.
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openAccessibilitySettings()
        accessibilityGranted = AXIsProcessTrusted()
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
