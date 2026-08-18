//
//  SettingsView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Defaults
import Sparkle
import SwiftUI

/// The Settings window.
///
/// Thirteen sections in the sidebar and a `NavigationStack` in the detail
/// column. What this replaced was twenty-seven destinations in one flat list and
/// a twenty-seven-case switch here — which is why this file had grown to hold
/// eleven panes and an XPC subsystem alongside the shell.
struct SettingsView: View {
    @StateObject private var router: SettingsRouter

    /// Read so the tree re-renders when the accent changes.
    ///
    /// This used to be a `.id(UUID())` on the whole split view, poked by a
    /// `NotificationCenter` post, because `Color.effectiveAccent` is a static
    /// computed property that reads `Defaults` imperatively — SwiftUI had no
    /// dependency on it, so nothing invalidated. The hammer worked, and it also
    /// destroyed every piece of view state below it: a half-typed prompt, an
    /// expanded Sweep category, whatever Knowledge had loaded. Depending on the
    /// two keys directly gets the redraw without throwing the window away.
    @Default(.useCustomAccentColor) private var useCustomAccentColor
    @Default(.customAccentColorData) private var customAccentColorData

    let updaterController: SPUStandardUpdaterController?

    init(initialTab: String = "General", updaterController: SPUStandardUpdaterController? = nil) {
        _router = StateObject(wrappedValue: SettingsRouter(.init(legacyIdentifier: initialTab)))
        self.updaterController = updaterController
    }

    /// The window controller keeps one of these and drives deep links through
    /// it, rather than rebuilding `window.contentView` on every link.
    init(router: SettingsRouter, updaterController: SPUStandardUpdaterController? = nil) {
        _router = StateObject(wrappedValue: router)
        self.updaterController = updaterController
    }

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(router: router)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(232)
        } detail: {
            NavigationStack(path: router.path) {
                router.route.section.landingPane
                    .navigationDestination(for: SettingsPage.self) { $0.view }
            }
            // A section change replaces the stack rather than animating a pop
            // through pages the reader never chose.
            .id(router.route.section)
            // Applied here, above the stack, so it sees section changes and
            // never sees a page push. See `sweepLifetime(_:)`.
            .sweepLifetime(router)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            // Keeps SwiftUI from installing a title in a window that hides one.
            ToolbarItem(placement: .principal) {
                Text("")
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        // The window decides its size; this decides its minimum.
        .frame(minWidth: 880, minHeight: 560)
        .background(NotchSurface.base)
        // Injected once here instead of re-applied in eleven panes.
        .tint(.effectiveAccent)
        .environment(\.settingsRouter, router)
        .environment(\.sparkleUpdater, updaterController ?? SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil))
    }
}
