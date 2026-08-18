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
let copilotNotchSize: CGSize = .init(width: 600, height: 340)

/// The notch for the compact call panel — pointer or account alone, no transcript.
///
/// Taller than a normal tab's `openNotchSize` and deliberately not shared with
/// one: this is the layout a call spends most of its time in, and at 168pt it
/// showed about three lines of an account that is worth reading five of.
let copilotCompactNotchSize: CGSize = .init(width: openNotchSize.width, height: 260)

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
let maxOpenNotchSize: CGSize = .init(
    width: max(openNotchSize.width, max(copilotNotchSize.width, knowledgeNotchSize.width)),
    height: max(
        max(openNotchSize.height, dropChooserNotchSize.height),
        max(copilotCompactNotchSize.height, max(copilotNotchSize.height, knowledgeNotchSize.height))))

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
