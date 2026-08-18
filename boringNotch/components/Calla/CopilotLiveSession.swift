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
        /// Transcript beside the pointer, at `copilotNotchSize`.
        case full
        /// Pointer or account alone, at `copilotCompactNotchSize` — still
        /// listening, out of the way.
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

    /// A sign-in is waiting for the user, so the notch shows a field for the code
    /// instead of a call.
    ///
    /// Deliberately separate from `isLive`: this happens *before* a call exists —
    /// typically because someone started a meeting without being signed in — and it
    /// must hold the notch open on its own.
    @Published private(set) var signInActive = false

    /// The single question `BoringViewModel.close()` and the panel's sharing
    /// type both ask.
    var pinsNotchOpen: Bool { (isLive || signInActive || prerollActive) && pinned }

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
        guard isLive else { return openNotchSize }
        // A call keeps the full slab whichever layout it is in: compact drops
        // the transcript, not the panel, and shrinking the notch under a live
        // call reads as the call having ended.
        return copilotNotchSize
    }

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

        CallaEngineClient.shared.$status
            .map(\.copilot.isSigningIn)
            .removeDuplicates()
            .sink { [weak self] signingIn in
                self?.apply(signingIn: signingIn)
            }
            .store(in: &cancellables)
    }

    /// Arms the pre-roll card and brings the notch to the copilot tab.
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
        pinned = true
        reveal()
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
