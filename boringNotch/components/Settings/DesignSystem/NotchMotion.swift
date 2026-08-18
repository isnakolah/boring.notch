//
//  NotchMotion.swift
//  boringNotch
//

import SwiftUI

/// The curves, taken from the notch rather than invented for the window.
///
/// `ContentView` opens the slab on one spring and closes it on another, and
/// every smaller change in the app is `.smooth`. Settings had been picking
/// durations per call site. These are the same four curves, named once.
///
/// A note on what is *not* here: `NavigationStack` supplies its own push
/// animation on macOS and exposes no hook to replace it. Hand-rolling the stack
/// to get a custom push would trade `navigationDestination`, focus management
/// and the VoiceOver rotor for a curve, which is a bad trade. The motion budget
/// goes to what the stack does not animate — the breadcrumb, the sidebar
/// selection, the preview well, and status changing under the reader.
enum NotchMotion {
    /// The notch expanding. Matches `ContentView`'s open spring exactly.
    static let open = Animation.spring(response: 0.42, dampingFraction: 0.80)
    /// The notch closing: critically damped, so it does not bounce shut.
    static let close = Animation.spring(response: 0.45, dampingFraction: 1.00)
    /// Something small resolving in place — a crumb appended, a selection moved,
    /// a badge changing what it says.
    static let settle = Animation.smooth(duration: 0.25)
    /// The preview well swapping what it is showing as the reader moves deeper.
    static let drill = Animation.smooth(duration: 0.30)
}
