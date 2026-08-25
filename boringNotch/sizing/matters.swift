//
//  sizeMatters.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 05/08/24.
//

import Defaults
import Foundation
import SwiftUI

let downloadSneakSize: CGSize = .init(width: 65, height: 1)
let batterySneakSize: CGSize = .init(width: 160, height: 1)

let shadowPadding: CGFloat = 20
let openNotchSize: CGSize = .init(width: 512, height: 168)

/// The notch while a call copilot session is live.
///
/// Wider and much taller than a normal tab: it carries a running transcript
/// beside the pointer, and a transcript that only shows two turns is not one.
///
/// The default. What is actually used is `CallaPanelSize.full`, which lets the
/// user resize the panel — how much of a call you want on screen is a matter of
/// screen size and taste, and no single pair of numbers is right for everyone.
let copilotNotchSize: CGSize = .init(width: 600, height: 340)

/// How far the call panel may be resized.
///
/// The window behind the notch is created **once** at `maxOpenNotchSize` and
/// never resized — the shape is clipped to `vm.notchSize` and anything unused
/// stays transparent. So a user-chosen size larger than that ceiling would be
/// silently cut off rather than shown, which is why the ceiling below is
/// computed from these maxima and not from the defaults.
enum CallaPanelBounds {
    static let width: ClosedRange<CGFloat> = 460...900
    static let fullHeight: ClosedRange<CGFloat> = 240...560
    /// The floor is not arbitrary: below about 150 the answer, the caption strip
    /// and the controls cannot all be on screen, and the answer is what gives
    /// way. See the note on `copilotCompactNotchSize`.
    static let compactHeight: ClosedRange<CGFloat> = 150...420

    static func clampWidth(_ value: CGFloat) -> CGFloat {
        min(max(value, width.lowerBound), width.upperBound)
    }

    static func clampFullHeight(_ value: CGFloat) -> CGFloat {
        min(max(value, fullHeight.lowerBound), fullHeight.upperBound)
    }

    static func clampCompactHeight(_ value: CGFloat) -> CGFloat {
        min(max(value, compactHeight.lowerBound), compactHeight.upperBound)
    }
}

/// The notch while the call panel is collapsed to the answer alone.
///
/// Deleted once, as an unused constant, on the reasoning that a call should keep
/// the full slab in both layouts so collapsing could never read as the call
/// having ended. Watching it run says otherwise: the answer alone in a 600x340
/// panel is mostly empty card, and "compact" that is the same size as "full" is
/// not compact. The header band keeps the state and the clock, so the call is
/// still plainly running at this size.
// The default. `CallaPanelSize.compact` is what is used.
//
// 200 rather than 220, 220 rather than 250, and 250 rather than 210.
//
// At 210 the column had ~124pt after the header band, the insets and the
// controls' strip, and a three-line answer plus a two-line caption wanted about
// 150 — SwiftUI resolved that by compressing the answer to a single ellipsised
// line, so the one thing the panel exists to show was the one thing that could
// not be read.
//
// 220 bought the height back from the caption rather than from the answer: the
// strip is one line here instead of two (`captionStream`), which is 15pt, and
// the newest words are still the ones on screen because it truncates from the
// head. 200 takes the rest out of the gaps between recap lines, which had more
// air than the lines needed.
let copilotCompactNotchSize: CGSize = .init(width: openNotchSize.width, height: 200)

/// The notch while a file is being filed against a meeting.
///
/// Two columns — drop on one side, choose on the other — so it needs the copilot's
/// width rather than a normal tab's. At `openNotchSize`'s 168pt the drop target
/// and the list of what is already attached could not both be on screen, and the
/// whole point of the surface is seeing the second while you use the first.
let knowledgeNotchSize: CGSize = .init(width: copilotNotchSize.width, height: 300)

/// The notch while a dragged file is being aimed at one half or the other.
///
/// Two tiles side by side need width more than height; taller than a normal tab
/// only because each tile says what it will do rather than just naming itself.
let dropChooserNotchSize: CGSize = .init(width: openNotchSize.width, height: 200)

/// The largest the open notch can ever be.
///
/// The panel is created once at this size and never resized — the notch shape
/// is clipped to `vm.notchSize` and pinned to the top, so anything the current
/// mode does not use stays transparent. That is already how the 185pt closed
/// notch lives inside a 512pt window; growing the ceiling just extends it.
/// The largest the open notch can ever be.
///
/// Driven by `CallaPanelBounds`' upper limits rather than by the copilot's
/// current size, because the call panel is user-resizable and the window is
/// created once. Sizing this to today's default would clip anyone who made the
/// panel bigger, and the symptom — a panel cut off at the bottom — would look
/// like a layout bug rather than a window that was never big enough.
let maxOpenNotchSize: CGSize = .init(
    width: max(openNotchSize.width,
               max(CallaPanelBounds.width.upperBound, knowledgeNotchSize.width)),
    height: max(
        max(openNotchSize.height, dropChooserNotchSize.height),
        max(CallaPanelBounds.compactHeight.upperBound,
            max(CallaPanelBounds.fullHeight.upperBound, knowledgeNotchSize.height))))

let windowSize: CGSize = .init(width: maxOpenNotchSize.width, height: maxOpenNotchSize.height + shadowPadding)
let cornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) = (opened: (top: 19, bottom: 24), closed: (top: 6, bottom: 14))

enum MusicPlayerImageSizes {
    static let cornerRadiusInset: (opened: CGFloat, closed: CGFloat) = (opened: 13.0, closed: 4.0)
    static let size = (opened: CGSize(width: 90, height: 90), closed: CGSize(width: 20, height: 20))
}

@MainActor func getScreenFrame(_ screenUUID: String? = nil) -> CGRect? {
    var selectedScreen = NSScreen.main

    if let uuid = screenUUID {
        selectedScreen = NSScreen.screen(withUUID: uuid)
    }
    
    if let screen = selectedScreen {
        return screen.frame
    }
    
    return nil
}

@MainActor func getClosedNotchSize(screenUUID: String? = nil) -> CGSize {
    // Default notch size, to avoid using optionals
    var notchHeight: CGFloat = Defaults[.nonNotchHeight]
    var notchWidth: CGFloat = 185

    var selectedScreen = NSScreen.main

    if let uuid = screenUUID {
        selectedScreen = NSScreen.screen(withUUID: uuid)
    }

    // Check if the screen is available
    if let screen = selectedScreen {
        // Calculate and set the exact width of the notch
        if let topLeftNotchpadding: CGFloat = screen.auxiliaryTopLeftArea?.width,
           let topRightNotchpadding: CGFloat = screen.auxiliaryTopRightArea?.width
        {
            notchWidth = screen.frame.width - topLeftNotchpadding - topRightNotchpadding + 4
        }

        // Check if the Mac has a notch
        if screen.safeAreaInsets.top > 0 {
            // This is a display WITH a notch - use notch height settings
            notchHeight = Defaults[.notchHeight]
            if Defaults[.notchHeightMode] == .matchRealNotchSize {
                notchHeight = screen.safeAreaInsets.top
            } else if Defaults[.notchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        } else {
            // This is a display WITHOUT a notch - use non-notch height settings
            notchHeight = Defaults[.nonNotchHeight]
            if Defaults[.nonNotchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        }
    }

    return .init(width: notchWidth, height: notchHeight)
}


/// The call panel's size, as the user has set it.
///
/// A type rather than two `Defaults` reads at the call site, for one reason:
/// every read has to be clamped. The window behind the notch is created once at
/// `maxOpenNotchSize`, so a stored value outside `CallaPanelBounds` would draw a
/// panel the window cannot contain — and the symptom is a panel quietly cut off
/// at the bottom, which reads as a layout bug rather than a setting out of range.
enum CallaPanelSize {
    static var full: CGSize {
        CGSize(
            width: CallaPanelBounds.clampWidth(CGFloat(Defaults[.callaPanelWidth])),
            height: CallaPanelBounds.clampFullHeight(CGFloat(Defaults[.callaPanelHeight])))
    }

    static var compact: CGSize {
        CGSize(
            width: CallaPanelBounds.clampWidth(CGFloat(Defaults[.callaCompactPanelWidth])),
            height: CallaPanelBounds.clampCompactHeight(
                CGFloat(Defaults[.callaCompactPanelHeight])))
    }

    /// Puts both layouts back to the shipped numbers.
    static func reset() {
        Defaults[.callaPanelWidth] = Double(copilotNotchSize.width)
        Defaults[.callaPanelHeight] = Double(copilotNotchSize.height)
        Defaults[.callaCompactPanelWidth] = Double(copilotCompactNotchSize.width)
        Defaults[.callaCompactPanelHeight] = Double(copilotCompactNotchSize.height)
    }

    static var isDefault: Bool {
        full == copilotNotchSize && compact == copilotCompactNotchSize
    }
}
