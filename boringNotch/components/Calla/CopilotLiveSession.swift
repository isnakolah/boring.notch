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
    var pinsNotchOpen: Bool { (isLive || starting || signInActive || prerollActive) && pinned }

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
        if starting, !isLive { return CallaPanelSize.full }
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
        // Only opens the notch. Closing it is `apply(running:)`'s job: a call that
        // comes up hands straight over to the live panel, and one that fails to
        // come up is released by the client's launch timeout, which is the same
        // path a stopped call takes.
        guard starting, Defaults[.callaCopilotEnabled] else {
            if !starting, !isLive { pinned = false }
            NotificationCenter.default.post(name: .copilotLiveDidChange, object: nil)
            return
        }
        layout = .full
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
