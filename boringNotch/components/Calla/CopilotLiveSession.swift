import AppKit
import Combine
import Defaults
import SwiftUI

/// Owns "a call is happening right now" for the whole app.
///
/// Three things key off this and nothing else: the notch refuses to close, the
/// notch grows to `copilotNotchSize`, and the panel drops out of screen
/// recordings. Keeping them on one flag is deliberate — a live panel that is
/// visible in a share, or one that closes when the pointer drifts away, is
/// worse than no panel, and both failures come from the same state getting out
/// of sync.
@MainActor
final class CopilotLiveSession: ObservableObject {
    static let shared = CopilotLiveSession()

    enum Layout {
        /// The answer with the transcript beside it.
        case full
        /// The answer alone, at `copilotCompactNotchSize` — still listening,
        /// out of the way.
        case compact
    }

    /// Mirrors the engine's `copilot.running`, which is the only authority on
    /// whether a call exists. Never set this directly.
    @Published private(set) var isLive = false

    @Published private(set) var layout: Layout = .full

    /// Whether the session currently wants the notch held open. Cleared by
    /// `dismiss()` without ending the call.
    @Published private(set) var pinned = false

    /// A meeting is about to start and the copilot is warm but not recording.
    ///
    /// Deliberately its own state alongside `signInActive` rather than a variant of
    /// `isLive`: a call does not exist yet, nothing is being captured, and the
    /// panel's job is to say both of those things and offer the three buttons. If
    /// this were folded into `isLive` the notch would claim a call was running
    /// while the microphones were off, which is the one lie this feature cannot
    /// afford to tell.
    @Published private(set) var prerollActive = false
    @Published private(set) var prerollTitle: String?
    @Published private(set) var prerollStartsAt: Date?

    /// A call has been asked for and has not come up yet.
    ///
    /// Its own state rather than a variant of `isLive`, for the same reason
    /// `prerollActive` is: nothing is being captured yet, and a notch that claimed
    /// otherwise would be making the one claim this feature cannot get wrong. What
    /// it buys is the panel appearing on the press instead of up to four seconds
    /// later, with the host's own startup drawn inside it.
    @Published private(set) var starting = false

    /// The call has stopped capturing and is being written up.
    ///
    /// Holds the notch the way `starting` does, and for the same reason: this is
    /// a stretch of seconds where the user has just pressed something and is
    /// owed an answer about what it did. Previously the panel simply went on
    /// showing the live call — `running` stayed true until the host exited — and
    /// then disappeared without ever acknowledging the press.
    @Published private(set) var ending = false

    /// A start was asked for and ended without a call.
    ///
    /// Its own state because the alternative was silence. `starting` going false
    /// without `isLive` going true was treated as "nothing to show": the notch
    /// unpinned, the panel was replaced by the tab with its Start button back on
    /// it, and a start that failed became indistinguishable from one that was
    /// never pressed. The host had already said what went wrong — it just had
    /// nowhere to say it.
    ///
    /// So a failed start holds the notch exactly the way a starting one does,
    /// and the panel says which step it got to and offers the press again.
    @Published private(set) var startupFailed = false

    /// What the host said on the way down, kept because `lastResult` is
    /// overwritten by whatever the engine does next.
    @Published private(set) var startupFailure: String?

    /// The last step the host reported before it stopped reporting. The status
    /// clears `startupStage` when the host goes, which would otherwise leave the
    /// failure panel unable to say where it got to.
    @Published private(set) var lastStartupStage: String?

    /// A sign-in is waiting for the user, so the notch shows a field for the code
    /// instead of a call.
    ///
    /// Deliberately separate from `isLive`: this happens *before* a call exists —
    /// typically because someone started a meeting without being signed in — and it
    /// must hold the notch open on its own.
    @Published private(set) var signInActive = false

    /// An answer has arrived that the reader has not looked at.
    ///
    /// Lives here rather than in the panel because two views need it: the panel,
    /// which clears it when the answer is shown, and the notch's header band,
    /// which is where the cue is drawn — a dot beside the capture glyphs, so an
    /// answer landing while the recap is up is visible without the panel
    /// changing under the reader.
    @Published private(set) var unreadAnswer = false

    func markUnreadAnswer() { unreadAnswer = true }
    func clearUnreadAnswer() { unreadAnswer = false }

    /// The single question `BoringViewModel.close()` and the panel's sharing
    /// type both ask.
    var pinsNotchOpen: Bool {
        (isLive || starting || ending || startupFailed || signInActive || prerollActive) && pinned
    }

    /// The size the notch should open to right now.
    var preferredOpenSize: CGSize {
        // A sign-in needs a line of text and a field, so it uses the compact size
        // whatever the call layout happens to be. The pre-roll card is the same
        // shape: a title, a line of state, and three buttons.
        // Filing a document outranks the rest: it is a two-column surface and at
        // a normal tab's height its own drop target falls off the bottom.
        if NotchDropRouter.shared.isChoosing { return dropChooserNotchSize }
        if CallaKnowledgeAttach.shared.isPresenting {
            // Only the drop needs the taller surface: it still has to show what
            // was dropped *and* the meetings it could go to. Arriving from the
            // calendar the meeting is already settled, so it is one column and
            // a line to type — a normal tab, like every other pane.
            return CallaKnowledgeAttach.shared.presetTarget == nil ? knowledgeNotchSize : openNotchSize
        }
        if signInActive || prerollActive { return openNotchSize }
        // A starting call uses the full live size it is about to become, so the
        // notch does not resize under the reader the moment capture begins.
        // Compact, not the live slab.
        //
        // Startup has four short lines to show and a failure has three; the live
        // panel has a transcript beside an answer. Opening at the full size for
        // all of them meant the notch went straight to a mostly empty rectangle
        // and stayed there whether or not a call ever arrived. It grows into the
        // full size in `apply(running:)` — at the moment recording begins, which
        // is the moment the room starts carrying something.
        if (starting || startupFailed || ending), !isLive { return CallaPanelSize.compact }
        guard isLive else { return openNotchSize }
        // Compact is genuinely smaller. Keeping the full slab for both layouts
        // meant collapsing bought nothing but empty card — the state and the
        // clock live in the header band either way, so the call is still
        // visibly running at the smaller size.
        // The user's own numbers, not the constants. Clamped on read.
        return layout == .full ? CallaPanelSize.full : CallaPanelSize.compact
    }

    /// Bumped whenever the panel-size settings change.
    ///
    /// The size itself is a computed property, so nothing can observe it. This
    /// is what `ContentView` watches to re-apply the size while a slider is
    /// being dragged — without it the setting reads as broken: you drag during a
    /// call, nothing moves, and the only way to see the result is to collapse
    /// the panel and open it again.
    @Published private(set) var panelSizeRevision = 0

    private var cancellables: Set<AnyCancellable> = []

    private init() {
        CallaEngineClient.shared.$status
            // Recording, not merely running: a prewarmed host exists but captures
            // nothing, and the live panel must not appear for it.
            .map(\.copilot.isRecording)
            .removeDuplicates()
            .sink { [weak self] running in
                self?.apply(running: running)
            }
            .store(in: &cancellables)

        Defaults.publisher(
            keys: .callaPanelWidth, .callaPanelHeight,
            .callaCompactPanelWidth, .callaCompactPanelHeight
        )
        .sink { [weak self] in
            guard let self else { return }
            self.panelSizeRevision &+= 1
        }
        .store(in: &cancellables)

        CallaEngineClient.shared.$launchingCall
            .combineLatest(CallaEngineClient.shared.$status.map(\.copilot.starting))
            .map { $0 || $1 }
            .removeDuplicates()
            .sink { [weak self] starting in
                self?.apply(starting: starting)
            }
            .store(in: &cancellables)

        // Remembered while it is being reported, because the failure panel needs
        // it after the host has stopped reporting anything.
        CallaEngineClient.shared.$status
            .map(\.copilot.startupStage)
            .removeDuplicates()
            .sink { [weak self] stage in
                guard let stage else { return }
                self?.lastStartupStage = stage
            }
            .store(in: &cancellables)

        CallaEngineClient.shared.$endingCall
            .combineLatest(CallaEngineClient.shared.$status.map(\.copilot.isFinishing))
            .map { $0 || $1 }
            .removeDuplicates()
            .sink { [weak self] ending in
                self?.apply(ending: ending)
            }
            .store(in: &cancellables)

        CallaEngineClient.shared.$status
            .map(\.copilot.isSigningIn)
            .removeDuplicates()
            .sink { [weak self] signingIn in
                self?.apply(signingIn: signingIn)
            }
            .store(in: &cancellables)
    }

    /// Arms the pre-roll host without disturbing the current notch. The user
    /// discovers the ready state by opening the Copilot tab themselves.
    ///
    /// Called by `MeetingPreroll` at the lead time, before the engine has spawned
    /// anything — so the card appears at the moment the user was promised it,
    /// rather than whenever the host finishes booting.
    func beginPreroll(title: String, startsAt: Date) {
        guard Defaults[.callaCopilotEnabled] else { return }
        prerollTitle = title
        prerollStartsAt = startsAt
        guard !prerollActive else { return }
        prerollActive = true
        layout = .compact
        pinned = false
    }

    func endPreroll() {
        guard prerollActive else { return }
        prerollActive = false
        prerollTitle = nil
        prerollStartsAt = nil
        // Hands the notch back to whatever the call is doing rather than closing
        // it out from under a call that just started, which is the same rule the
        // sign-in path follows when it finishes.
        pinned = isLive
        layout = isLive ? .full : .compact
        NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
    }

    private func apply(starting: Bool) {
        guard starting != self.starting else { return }
        self.starting = starting

        // Only opens the notch. A call that comes up hands straight over to the
        // live panel — `apply(running:)` does that, and clears this — so
        // reaching here with `starting` false and nothing live means the start
        // ended without a call: the host died, was refused a permission, or the
        // client's thirty-second launch deadline expired.
        //
        // That used to unpin and let the notch close. It is the one moment in
        // the whole flow where the user is definitely looking at the notch and
        // definitely wants to be told something, so it holds instead.
        guard starting, Defaults[.callaCopilotEnabled] else {
            if !starting, !isLive {
                if Defaults[.callaCopilotEnabled] {
                    startupFailed = true
                    startupFailure = CallaEngineClient.shared.status.copilot.lastResult
                    layout = .compact
                    pinned = true
                } else {
                    pinned = false
                }
            }
            NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
            return
        }
        clearStartupFailure()
        layout = .compact
        pinned = true
        reveal()
    }

    /// Forgets a failed start. Called when one succeeds, when the reader
    /// dismisses it, and when they press the button again.
    func clearStartupFailure() {
        guard startupFailed || startupFailure != nil else { return }
        startupFailed = false
        startupFailure = nil
    }

    /// Puts the notch back the way a dismissed call does: the panel goes, the
    /// call does not restart, and nothing else is disturbed.
    func dismissStartupFailure() {
        clearStartupFailure()
        lastStartupStage = nil
        pinned = false
        NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
    }

    private func apply(ending: Bool) {
        guard ending != self.ending else { return }
        self.ending = ending
        guard ending, Defaults[.callaCopilotEnabled] else {
            // The write-up is done. Nothing to hold the notch for any more, and
            // nothing to say — History has the recap.
            if !isLive { pinned = false }
            NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
            return
        }
        // Recording has stopped, so the live panel's claim has stopped being
        // true. `apply(running:)` will clear `isLive` on the same status, but
        // the order of the two is not guaranteed and the panel must not be a
        // live call for even one frame after capture closed.
        isLive = false
        layout = .compact
        pinned = true
        reveal()
    }

    private func apply(signingIn: Bool) {
        guard signingIn != signInActive else { return }
        signInActive = signingIn

        if signingIn {
            guard Defaults[.callaCopilotEnabled] else { return }
            layout = .compact
            pinned = true
            reveal()
        } else {
            // A finished sign-in hands the notch back to whatever the call is
            // doing, rather than closing it out from under a call that started.
            pinned = isLive
            layout = isLive ? .full : .compact
            NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
        }
    }

    private func apply(running: Bool) {
        guard running != isLive else { return }
        isLive = running

        if running {
            guard Defaults[.callaCopilotEnabled] else { return }
            // Recording has started, so the card's central claim — that nothing is
            // being captured — has stopped being true. The live panel takes over.
            starting = false
            ending = false
            clearStartupFailure()
            lastStartupStage = nil
            prerollActive = false
            prerollTitle = nil
            prerollStartsAt = nil
            layout = .full
            pinned = true
            reveal()
        } else {
            pinned = false
            layout = .full
            NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
        }
    }

    /// Brings the notch to the copilot tab and opens it at the live size.
    ///
    /// Refuses to steal the notch from a running lesson, the same rule the
    /// suggestion peek has followed since it shipped.
    private func reveal() {
        let coordinator = BoringViewCoordinator.shared
        if coordinator.currentView == .tutor,
           CallaEngineClient.shared.status.activeLesson?.active == true {
            return
        }
        coordinator.currentView = .copilot
        NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
    }

    func toggleLayout() {
        // Nothing to toggle while a sign-in owns the panel.
        guard isLive, !signInActive else { return }
        layout = layout == .full ? .compact : .full
        // A layout change is a size change, so the open notch has to be told.
        NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
    }

    /// Lets the notch close while the call keeps running.
    ///
    /// Re-pins on the next suggestion, so dismissing is "not now", not "never
    /// again for this call".
    func dismiss() {
        pinned = false
    }

    /// Changes whether a live call holds the notch open. Unpinning deliberately
    /// leaves the current panel on screen; normal notch close rules take over.
    func togglePin() {
        guard isLive, !signInActive else { return }
        pinned.toggle()
    }

    /// Re-arms the pin — called when a fresh suggestion arrives after a dismiss.
    func repin() {
        guard isLive else { return }
        pinned = true
    }
}

extension Notification.Name {
    /// Posted when the live session wants the notch opened or resized.
    static let copilotLiveDidChange = Notification.Name("copilotLiveDidChange")
}
