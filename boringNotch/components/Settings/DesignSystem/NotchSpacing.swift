//
//  NotchSpacing.swift
//  boringNotch
//

import SwiftUI

/// The distances, so a new pane does not invent a fifteenth one.
///
/// Nothing here is new. These are the values `SettingsPane`, `SettingCard` and
/// `SettingRow` already use; naming them is the whole change. The system had a
/// radius scale and a type scale from the start but left spacing to whoever was
/// typing, which is why a Sweep card sets its rows 12pt apart and a Copilot card
/// sets the same rows at 10.
///
/// Migrating the existing literals onto these names is mechanical and can lag;
/// what matters is that nothing new picks a number by eye.
enum NotchSpace {
    /// A label to its own detail line. Close enough to read as one block.
    static let hair: CGFloat = 2
    /// Items inside a single control cluster.
    static let tight: CGFloat = 6
    /// Rows inside a card.
    static let snug: CGFloat = 10
    /// A label to the control it operates.
    static let row: CGFloat = 12
    /// A card's own padding.
    static let card: CGFloat = 14
    /// Card to card.
    static let stack: CGFloat = 16
    /// The pane margin.
    static let pane: CGFloat = 22
    /// Between named groups within one pane. The only new number here, and it
    /// exists so a long pane can be divided without a second card doing it.
    static let group: CGFloat = 28
}
