//
//  SettingsBreadcrumb.swift
//  boringNotch
//

import SwiftUI

/// The trail: which section, and how deep into it.
///
/// This is the eyebrow `SettingsPane` always drew, made navigable. The eyebrow
/// existed to answer "where am I" for a flat list that could not say; a window
/// with depth needs the same answer and one more level of it, so the breadcrumb
/// takes the same line, the same type and the same colour rather than adding a
/// strip of chrome above them.
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
    /// `nil` at depth 0, where there is nothing to go back to.
    var onBack: (() -> Void)?

    var body: some View {
        HStack(spacing: NotchSpace.tight) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 11, weight: .semibold))
                        .contentShape(Rectangle())
                }
                .buttonStyle(BreadcrumbBack())
                // On the visible button rather than a hidden one: zero-size and
                // `.hidden()` views do not reliably register key equivalents.
                .keyboardShortcut("[", modifiers: .command)
                .help("Back")
            }

            ForEach(Array(crumbs.enumerated()), id: \.element) { index, crumb in
                if index > 0 {
                    // An SF Symbol rather than a literal "›": the symbol flips
                    // under right-to-left layout and the character does not, and
                    // this window ships in sixteen languages.
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.quaternary)
                }
                if index == crumbs.count - 1 {
                    Text(crumb.title.uppercased())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // The leaf yields first: a ninety-character meeting
                        // title should truncate before it pushes the section
                        // name off the front of the trail.
                        .truncationMode(.middle)
                        .layoutPriority(0)
                } else {
                    Button { onSelect(crumb.depth) } label: {
                        Text(crumb.title.uppercased()).lineLimit(1)
                    }
                    .buttonStyle(BreadcrumbLink())
                    .layoutPriority(1)
                }
            }
            Spacer(minLength: 0)
        }
        .font(NotchType.eyebrow)
        .kerning(0.5)
        .animation(NotchMotion.settle, value: crumbs)
    }
}

private struct BreadcrumbLink: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(NotchMotion.settle, value: hovering)
    }
}

private struct BreadcrumbBack: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .opacity(configuration.isPressed ? 0.5 : 1)
            .onHover { hovering = $0 }
            .animation(NotchMotion.settle, value: hovering)
    }
}
