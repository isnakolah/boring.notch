//
//  SettingsRouter.swift
//  boringNotch
//

import SwiftUI

/// Who owns where the window is.
///
/// An `ObservableObject` rather than `@State` in a view, for three reasons that
/// are all about lifetime:
///
/// 1. `SettingsWindowController` needs to reach it. Deep links used to rebuild
///    `window.contentView` with a fresh `NSHostingView` on every call, throwing
///    away a half-typed prompt and a running Sweep scan along with it. With a
///    router the controller can hold, a deep link is one assignment.
/// 2. The accent-colour refresh replaces the view tree by `.id()`. State held
///    above that survives; state held below it does not.
/// 3. A struct of closures in the environment is not `Equatable`, so every view
///    reading it would invalidate on every change.
@MainActor
final class SettingsRouter: ObservableObject {
    @Published var route: SettingsRoute

    init(_ route: SettingsRoute = .init(.general)) {
        self.route = route
    }

    /// Bound straight into `NavigationStack(path:)`.
    var path: Binding<[SettingsPage]> {
        Binding(get: { self.route.path }, set: { self.route.path = $0 })
    }

    /// Bound into the sidebar's `List(selection:)`.
    ///
    /// Setting it clears the path: choosing a section in the sidebar always
    /// lands on that section's own front page, never halfway into where you
    /// happened to be last time. Re-selecting the current section is how you get
    /// back to its top, which is what the sidebar already means everywhere else
    /// in macOS.
    var section: Binding<SettingsSection> {
        Binding(
            get: { self.route.section },
            set: { [weak self] new in
                guard let self else { return }
                withAnimation(NotchMotion.settle) { self.route = .init(new) }
            }
        )
    }

    func go(_ route: SettingsRoute) { self.route = route }
    func go(legacyIdentifier: String) { route = .init(legacyIdentifier: legacyIdentifier) }

    func push(_ page: SettingsPage) { route.path.append(page) }
    func pop() { _ = route.path.popLast() }

    /// The breadcrumb's only verb. Depth 0 is the section's landing pane.
    func popTo(depth: Int) {
        guard depth >= 0, depth < route.path.count else { return }
        route.path.removeSubrange(depth...)
    }

    func popToRoot() { route.path.removeAll() }
}

// MARK: - Reaching it

private struct SettingsRouterKey: EnvironmentKey {
    /// Optional, and not because of Swift concurrency.
    ///
    /// A view rendered outside the Settings window — a `#Preview`, a pane pulled
    /// into some other context — genuinely has no router, and manufacturing a
    /// default one would hand it a live-looking object whose pushes went
    /// nowhere. Absent is the truth, so the type says so and the few readers
    /// degrade honestly: no breadcrumb, no drill rows.
    static let defaultValue: SettingsRouter? = nil
}

extension EnvironmentValues {
    /// Panes read this rather than being handed a binding. A pane that has to be
    /// told its own breadcrumb is a pane that can be wrong about it.
    var settingsRouter: SettingsRouter? {
        get { self[SettingsRouterKey.self] }
        set { self[SettingsRouterKey.self] = newValue }
    }
}
