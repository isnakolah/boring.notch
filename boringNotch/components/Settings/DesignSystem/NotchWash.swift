//
//  NotchWash.swift
//  boringNotch
//

import SwiftUI

/// A soft tinted wash that fades out across the surface.
///
/// Promoted from a private function in `BoringCalendar`, where it tinted each
/// event card by its calendar's colour. It was the one piece of genuine visual
/// character in the app and it was reachable from exactly one view.
///
/// It is a *wash*, not a fill: the tint is strongest at the leading edge and
/// gone by the trailing one, so it colours a surface without turning it into a
/// coloured surface. That distinction is what keeps it usable behind text.
///
/// The window is achromatic by policy — see `NotchSurface` — so this is applied
/// only where colour already carries meaning: a card reporting live status, a
/// permission that is missing, a figure that has crossed a threshold. It is not
/// decoration, and it is never used to tell two panes apart.
struct NotchWash: View {
    let tint: Color
    var radius: CGFloat = NotchRadius.card

    var body: some View {
        LinearGradient(
            colors: [tint.opacity(0.16), tint.opacity(0.05), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    /// Lays the wash behind this view.
    func notchWash(_ tint: Color, radius: CGFloat = NotchRadius.card) -> some View {
        background(NotchWash(tint: tint, radius: radius))
    }
}
