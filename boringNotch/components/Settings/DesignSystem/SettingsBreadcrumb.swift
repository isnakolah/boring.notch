//
//  SettingsBreadcrumb.swift
//  boringNotch
//

import SwiftUI

/// The trail, which is also the title.
///
/// The first version drew a 10pt uppercase trail and then the pane title
/// underneath it — so the page you were on was named twice, once in small caps
/// and once at 22pt, one line apart. That is two pieces of chrome saying the
/// same thing, and the small-caps copy read as a label stuck above the header
/// rather than as part of it.
///
/// System Settings does not do that. It puts one name at the top of the detail
/// pane and a way back beside it, and the path *is* the header rather than a
/// strip above it. So: the leaf is the pane title, at full size and weight, and
/// its ancestors lead into it on the same baseline at a smaller size — a path
/// you read left to right that ends in where you are.
///
/// It is a pure function of the route. There is no breadcrumb state to keep in
/// sync with the navigation stack, because the array *is* the path.
///
/// Not in the toolbar, deliberately. The Settings window never creates an
/// `NSToolbar` — it hides its title, keeps its titlebar only so the traffic
/// lights do not land on the notch preview, and installs an empty principal item
/// to stop SwiftUI adding one. A trail rendered up there would also span the
/// sidebar, which is not part of the path.
struct SettingsBreadcrumb: View {
    struct Crumb: Hashable {
        let title: String
        let depth: Int
    }

    let crumbs: [Crumb]
    /// Depth 0 is the section's landing pane.
    let onSelect: (Int) -> Void
    /// Kept for callers that had one. The trail carries its own way back now —
    /// see `backDepth` — so this is no longer drawn as a separate control.
    var onBack: (() -> Void)?

    private var parents: [Crumb] { crumbs.dropLast() }
    private var leaf: Crumb? { crumbs.last }

    /// Which parent is "up one". That crumb wears the back chevron and takes
    /// ⌘[, so the gesture and the glyph point at the same place — a back button
    /// that popped one level while the only visible chevron sat on the section
    /// name was two different meanings of "back" in one line.
    private var backDepth: Int? {
        crumbs.count >= 2 ? crumbs[crumbs.count - 2].depth : nil
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NotchSpace.tight) {
            ForEach(parents, id: \.self) { crumb in
                CrumbButton(crumb: crumb,
                            isBack: crumb.depth == backDepth,
                            action: { onSelect(crumb.depth) })
                Separator()
            }
            if let leaf {
                Text(leaf.title)
                    .font(NotchType.paneTitle)
                    .lineLimit(1)
                    // A ninety-character meeting title should lose its middle
                    // rather than push the section name off the front.
                    .truncationMode(.middle)
                    .layoutPriority(0)
            }
            Spacer(minLength: 0)
        }
        .animation(NotchMotion.settle, value: crumbs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(crumbs.map(\.title).joined(separator: ", "))
    }

    /// An SF Symbol rather than a literal "›": the symbol flips under
    /// right-to-left layout and the character does not, and this window ships in
    /// sixteen languages.
    private struct Separator: View {
        var body: some View {
            Image(systemName: "chevron.forward")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.quaternary)
                .layoutPriority(1)
        }
    }

    private struct CrumbButton: View {
        let crumb: Crumb
        let isBack: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 3) {
                    if isBack {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(crumb.title)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(CrumbLink())
            // On a visible button rather than a hidden one: zero-size and
            // `.hidden()` views do not reliably register key equivalents.
            .keyboardShortcut(isBack ? KeyboardShortcut("[", modifiers: .command) : nil)
            .help(isBack ? "Back to \(crumb.title)" : crumb.title)
            // Ancestors are short and known; the leaf is a meeting title
            // somebody else typed, so that is what gives way.
            .fixedSize()
            .layoutPriority(1)
        }
    }
}

/// An ancestor in the trail.
///
/// Smaller and lighter than the leaf but on its baseline, so the line reads as
/// one header with a path in it rather than as a label and a title. Rounded to
/// match `NotchType.paneTitle`, which it is leading into.
private struct CrumbLink: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .opacity(configuration.isPressed ? 0.5 : 1)
            .onHover { hovering = $0 }
            .animation(NotchMotion.settle, value: hovering)
    }
}
