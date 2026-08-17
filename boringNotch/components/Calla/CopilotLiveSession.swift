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
        /// Pointer only, back at `openNotchSize` — still listening, out of the way.
        case compact
    }

    /// Mirrors the engine's `copilot.running`, which is the only authority on
    /// whether a call exists. Never set this directly.
    @Published private(set) var isLive = false

    @Published private(set) var layout: Layout = .full

    /// Whether the session currently wants the notch held open. Cleared by
    /// `dismiss()` without ending the call.
    @Published private(set) var pinned = false

    /// A sign-in is waiting for the user, so the notch shows a field for the code
    /// instead of a call.
    ///
    /// Deliberately separate from `isLive`: this happens *before* a call exists —
    /// typically because someone started a meeting without being signed in — and it
    /// must hold the notch open on its own.
    @Published private(set) var signInActive = false

    /// The single question `BoringViewModel.close()` and the panel's sharing
    /// type both ask.
    var pinsNotchOpen: Bool { (isLive || signInActive) && pinned }

    /// The size the notch should open to right now.
    var preferredOpenSize: CGSize {
        // A sign-in needs a line of text and a field, so it uses the compact size
        // whatever the call layout happens to be.
        if signInActive { return openNotchSize }
        return isLive && layout == .full ? copilotNotchSize : openNotchSize
    }

    private var cancellables: Set<AnyCancellable> = []

    private init() {
        CallaEngineClient.shared.$status
            .map(\.copilot.running)
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
