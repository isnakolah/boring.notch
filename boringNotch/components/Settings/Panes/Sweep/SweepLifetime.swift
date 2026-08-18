//
//  SweepLifetime.swift
//  boringNotch
//

import SwiftUI

extension View {
    /// Sweep's XPC service outlives its pages.
    ///
    /// The old rule was "the pane is on screen", hung off `onAppear` and
    /// `onDisappear` in `SweepSettings`. That was correct only while all four
    /// Sweep pages were one view selected from the sidebar. Now that Clean Up,
    /// History and Options are pushed, appearing and disappearing happens on
    /// every move within Sweep — and a survey takes minutes, so a service torn
    /// down on each push would never finish one.
    ///
    /// The real unit of lifetime is the *section*. This is applied once, to the
    /// detail column, above the `NavigationStack` — so it sees section changes
    /// and never sees a page change at all.
    ///
    /// The confirmation sheet rides along for the same reason: presented from a
    /// page, confirming a reclaim and then navigating would dismiss the sheet
    /// while the operation it authorised was still running.
    func sweepLifetime(_ router: SettingsRouter) -> some View {
        modifier(SweepLifetime(router: router))
    }
}

private struct SweepLifetime: ViewModifier {
    @ObservedObject var router: SettingsRouter
    @ObservedObject private var sweep = BoringSweepCoordinator.shared

    func body(content: Content) -> some View {
        content
            .onAppear { if router.route.section == .sweep { sweep.sectionOpened() } }
            .onChange(of: router.route.section) { old, new in
                if old == .sweep { sweep.sectionClosed() }
                if new == .sweep { sweep.sectionOpened() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .boringNotchSettingsWillClose)) { _ in
                sweep.settingsClosed()
            }
            .sheet(isPresented: $sweep.showConfirmation) { SweepConfirmationSheet() }
    }
}
