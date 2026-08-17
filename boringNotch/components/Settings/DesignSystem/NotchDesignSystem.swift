import SwiftUI

/// The vocabulary the Settings window is drawn from.
///
/// There was none. `SettingsView.swift` held twelve panes in 2201 lines of stock
/// `Form(.grouped)`, two more panes invented their own segmented tab bar inside
/// the sidebar selection, four badge helpers had drifted apart, and
/// `.accentColor(.effectiveAccent)` was re-applied by hand in eleven places.
/// None of that was a decision.
///
/// The organising idea: every pane in this app configures one physical surface —
/// a black rounded rectangle cut into the display that expands, contracts, and
/// shows live activities. So the window is shaped by the notch rather than by
/// System Settings, and `NotchPreviewWell` puts that surface at the top of the
/// sidebar where it can be seen while it is being configured.
///
/// Nothing here has behaviour. It is only the set of choices worth making once.

// MARK: - Surfaces

/// The neutral ground the window is built on.
///
/// Deliberately achromatic. The accent is the user's — eight presets and a
/// colour picker, archived in `Defaults[.customAccentColorData]` — so a design
/// system that also spent chroma would be competing with a choice they made.
enum NotchSurface {
    /// The window ground, behind everything.
    static var base: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    /// A card: one thing the reader can act on.
    static var raised: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    /// The notch void.
    ///
    /// This one does not flip with appearance, and that is the point. The notch
    /// is a hole in the display: it is black on every Mac, in every theme, at
    /// every hour. Drawing a light-grey "notch" in light mode would be a lie
    /// about the one thing this window exists to configure.
    static let sunken = Color(red: 0.04, green: 0.04, blue: 0.047)

    /// Card edges and dividers. Low enough to separate without ruling.
    static var hairline: Color { Color.primary.opacity(0.08) }
}

// MARK: - Colour

/// What a colour means, so no pane has to remember which green.
///
/// The same five stops the Tutor host already reasons in, which is why a
/// permission row, a Sweep run and a lesson can share one status vocabulary.
enum NotchTint {
    /// Working, granted, connected.
    static var healthy: Color { .green }
    /// Working on it, or waiting for a permission. Not a failure.
    static var attention: Color { .orange }
    /// Reserved for stopped.
    ///
    /// Orange means it is still getting somewhere; red means it is not. Spending
    /// red on an ordinary reconnect is how a reader is taught to ignore it, and
    /// then it is spent for good.
    static var stuck: Color { .red }
    /// The thing currently running, or being pointed at.
    static var active: Color { .effectiveAccent }
    /// Off, hidden, or not applicable — never wrong, just not running.
    static var paused: Color { .secondary }
}

// MARK: - Type

/// One scale.
///
/// No custom typeface: this window ships in sixteen languages through one String
/// Catalog, and a display face would need sixteen fallbacks to survive `ar`,
/// `ko`, `ru` and `zh-Hans`. The personality comes from how the system face is
/// set instead — SF Rounded for titles and figures, which is the notch's own
/// vocabulary, since the notch is nothing but corner radii.
enum NotchType {
    /// The name of a pane, once, at the top of it.
    static var paneTitle: Font { .system(size: 22, weight: .semibold, design: .rounded) }
    /// The small uppercase strip that says which group a pane belongs to.
    static var eyebrow: Font { .system(size: 10, weight: .semibold) }
    /// The sentence under a pane title that says what the pane is for.
    static var paneDetail: Font { .system(size: 12) }
    /// The heading of a card.
    static var cardTitle: Font { .system(size: 13, weight: .semibold) }
    /// The subject of a row.
    static var rowTitle: Font { .system(size: 13) }
    /// The sentence under a row that explains it.
    static var rowDetail: Font { .system(size: 11) }
    /// A number worth reading at a glance.
    ///
    /// Monospaced digits are not a flourish here. Battery, Sweep, Usage,
    /// Pomodoro and Tutor all render figures that update in place, and
    /// proportional digits make them jitter as the glyph widths change.
    static var stat: Font { .system(size: 17, weight: .semibold, design: .rounded).monospacedDigit() }
    /// Any smaller number that changes in place.
    static var figure: Font { .system(size: 11, design: .rounded).monospacedDigit() }
    /// A bundle id, a key combination, a digest — read character by character.
    static var mono: Font { .system(size: 11, design: .monospaced) }
}

// MARK: - Shape

enum NotchRadius {
    static let card: CGFloat = 12
    static let control: CGFloat = 8
    /// The tinted square behind a glyph.
    static let chip: CGFloat = 10
    /// The preview well the notch silhouette sits in.
    static let well: CGFloat = 14
}
