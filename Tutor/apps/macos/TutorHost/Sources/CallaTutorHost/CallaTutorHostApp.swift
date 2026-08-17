import AppKit
import ApplicationServices
import SwiftUI

@main
struct CallaTutorHostApp: App {
    /// A client hanging up must never kill the host.
    ///
    /// This is what made a lesson vanish mid-step. Every caller reaches the host
    /// over a Unix socket, and some of them give up early — `calla-ask.sh` waits
    /// two seconds for its acknowledgement, and a turn can take far longer than
    /// that. Writing the reply to a socket whose reader has gone raises SIGPIPE,
    /// whose default action is to terminate the process. The host died, launchd
    /// restarted it, and the overlay renderer — which lives or dies with the
    /// stdin pipe its parent holds — went with it: the pointer and the whole
    /// step disappeared, then came back a turn later from a fresh helper.
    ///
    /// Ignoring the signal turns that into an `EPIPE` from `write`, which is
    /// what the socket code already handles: one dropped reply instead of a
    /// dead teaching session.
    init() { signal(SIGPIPE, SIG_IGN) }

    @NSApplicationDelegateAdaptor(CallaAppDelegate.self) private var appDelegate

    var body: some Scene {
        // Boring owns visible UI. This child exists only for protected capture,
        // overlay, socket, local course, and relay runtime.
        Settings { EmptyView() }
    }
}

// MenuBarExtra only builds its content when the menu is opened, so a `.task`
// there would delay the socket until a human clicked the icon. Start at launch.
final class CallaAppDelegate: NSObject, NSApplicationDelegate {
    private var preferenceTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
        // Started before any lesson: the application a lesson is about has to be
        // known from the moment the learner uses it, not from the moment they
        // get around to asking.
        LessonSubject.shared.startWatching {
            MainActor.assumeIsolated { Set(TutorSettings.shared.allowedBundleIDs) }
        }
        // The renderer owns the Ask shortcut, which has to answer before any
        // lesson exists, so it comes up with the app rather than with the first
        // lesson that needs to draw something.
        PointerOverlay.shared.startRenderer()
        Task {
            await TutorHostController.shared.start()
            await TutorSettings.shared.refreshPermissionStatus()
        }
        preferenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                TutorSettings.shared.reloadFromEngineSnapshot()
                // A grant made in System Settings after launch was otherwise
                // never noticed: the only refresh ran once, above. The settings
                // object throttles this itself, on the main actor.
                await TutorSettings.shared.refreshPermissionStatusIfDue()
            }
        }
    }

    /// The renderer is a child process, so Quit has to take it with it. Without
    /// this the overlay outlives the host whenever the pipe does not close on
    /// the way out, and there is then nothing left that can hide it.
    func applicationWillTerminate(_ notification: Notification) {
        preferenceTimer?.invalidate()
        MainActor.assumeIsolated { PointerOverlay.shared.shutdown() }
    }

}
