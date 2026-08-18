//
//  NotchHeaderItem.swift
//  boringNotch
//

import Defaults
import SwiftUI

/// One thing that can sit in the open notch's header.
///
/// The header used to be a run of `if Defaults[...]` blocks, each owning its own
/// toggle in a different settings pane, so what appeared beside the notch was
/// decided in five places and could grow past the width the slab actually has.
/// Placement now lives in two ordered slot lists — three per side — and every
/// toggle for it lives in one pane.
enum NotchHeaderItem: String, CaseIterable, Identifiable, Codable, Defaults.Serializable {
    /// Views the header can switch to.
    case home, pomodoro, usage, shelf, tutor, copilot
    /// Controls and indicators.
    case mirror, settings, battery
    /// An empty slot. Kept as a case so a side's list is always `slotsPerSide`
    /// long and an item's index is its position, not its rank.
    case none

    var id: String { rawValue }

    /// Three a side. The closed notch's width plus two 30pt controls is already
    /// most of a 13" menu bar; a fourth is what starts clipping.
    static let slotsPerSide = 3

    static let defaultLeading: [NotchHeaderItem] = [.home, .pomodoro, .usage]
    static let defaultTrailing: [NotchHeaderItem] = [.shelf, .tutor, .copilot]

    /// Everything the layout pane offers, in the order it offers it.
    static let placeable: [NotchHeaderItem] = [
        .home, .pomodoro, .usage, .shelf, .tutor, .copilot, .mirror, .settings, .battery
    ]

    var label: String {
        switch self {
        case .home: return "Home"
        case .pomodoro: return "Pomodoro"
        case .usage: return "Usage"
        case .shelf: return "Shelf"
        case .tutor: return "Calla"
        case .copilot: return "Call"
        case .mirror: return "Mirror"
        case .settings: return "Settings"
        case .battery: return "Battery"
        case .none: return "Empty slot"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .pomodoro: return "timer.circle.fill"
        case .usage: return "chart.bar.xaxis"
        case .shelf: return "tray.fill"
        case .tutor: return "graduationcap.fill"
        case .copilot: return "waveform.badge.mic"
        case .mirror: return "web.camera"
        case .settings: return "gear"
        case .battery: return "battery.100"
        case .none: return ""
        }
    }

    /// The view this item opens, when it opens one.
    var destination: NotchViews? {
        switch self {
        case .home: return .home
        case .pomodoro: return .pomodoro
        case .usage: return .usage
        case .shelf: return .shelf
        case .tutor: return .tutor
        case .copilot: return .copilot
        default: return nil
        }
    }

    /// The feature toggle this item needs, when it needs one.
    ///
    /// Placement and enablement stay separate on purpose: `boringShelf` also
    /// arms the closed-notch drop target, so pulling Shelf out of the header
    /// must not switch that off.
    var featureKey: Defaults.Key<Bool>? {
        switch self {
        case .pomodoro: return .pomodoroTab
        case .usage: return .usageMonitorTab
        case .shelf: return .boringShelf
        case .tutor: return .callaTutorEnabled
        case .copilot: return .callaCopilotEnabled
        case .mirror: return .showMirror
        default: return nil
        }
    }

    /// Where the reader turns that feature on.
    ///
    /// This was six hand-written strings — `"Tutor › Behavior"`, `"Call copilot"`
    /// — which is a breadcrumb typed out by hand, and it had already drifted
    /// from what the sidebar actually said. As a route it cannot drift, and the
    /// "Off in …" badge becomes something you can press.
    var featureRoute: SettingsRoute? {
        switch self {
        case .pomodoro: return .init(.pomodoro)
        case .usage: return .init(.system, [.usage])
        case .shelf: return .init(.shelf)
        case .tutor: return .init(.tutor, [.tutorBehavior])
        case .copilot: return .init(.copilot, [.copilotCall])
        case .mirror: return .init(.appearance, [.camera])
        default: return nil
        }
    }

    /// The route's own name, so nothing has to spell it out.
    var featurePaneName: String? {
        guard let route = featureRoute else { return nil }
        guard let leaf = route.leaf else { return String(localized: route.section.title) }
        return "\(String(localized: route.section.title)) › \(String(localized: leaf.title))"
    }

    var isEnabled: Bool {
        guard let featureKey else { return true }
        return Defaults[featureKey]
    }
}

extension Defaults.Keys {
    static let notchHeaderLeading = Key<[NotchHeaderItem]>(
        "notchHeaderLeading",
        default: NotchHeaderItem.defaultLeading
    )
    static let notchHeaderTrailing = Key<[NotchHeaderItem]>(
        "notchHeaderTrailing",
        default: NotchHeaderItem.defaultTrailing
    )
}

/// Which run of slots is being read or written.
enum NotchHeaderSide: String, CaseIterable, Identifiable {
    case leading, trailing

    var id: String { rawValue }
    var title: String { self == .leading ? "Left" : "Right" }

    var key: Defaults.Key<[NotchHeaderItem]> {
        self == .leading ? .notchHeaderLeading : .notchHeaderTrailing
    }

    var defaults: [NotchHeaderItem] {
        self == .leading ? NotchHeaderItem.defaultLeading : NotchHeaderItem.defaultTrailing
    }
}

/// Reads and writes both sides, keeping each exactly `slotsPerSide` long and
/// each item in at most one slot.
enum NotchHeaderLayout {
    static func slots(_ side: NotchHeaderSide) -> [NotchHeaderItem] {
        padded(Defaults[side.key])
    }

    static func padded(_ slots: [NotchHeaderItem]) -> [NotchHeaderItem] {
        var result = Array(slots.prefix(NotchHeaderItem.slotsPerSide))
        result.append(contentsOf:
            Array(repeating: .none, count: NotchHeaderItem.slotsPerSide - result.count))
        return result
    }

    static func place(_ item: NotchHeaderItem, on side: NotchHeaderSide, at index: Int) {
        guard item != .none else { return remove(on: side, at: index) }
        remove(item)
        var slots = slots(side)
        guard slots.indices.contains(index) else { return }
        slots[index] = item
        Defaults[side.key] = slots
    }

    /// Puts the item in the first empty slot on that side. Returns false when
    /// there is none, which is what the pane reports instead of evicting
    /// something the reader chose.
    @discardableResult
    static func append(_ item: NotchHeaderItem, to side: NotchHeaderSide) -> Bool {
        guard item != .none else { return false }
        guard let index = slots(side).firstIndex(of: .none) else { return false }
        place(item, on: side, at: index)
        return true
    }

    static func remove(on side: NotchHeaderSide, at index: Int) {
        var slots = slots(side)
        guard slots.indices.contains(index) else { return }
        slots[index] = .none
        Defaults[side.key] = slots
    }

    /// Clears the item wherever it currently sits, so a move never duplicates it.
    static func remove(_ item: NotchHeaderItem) {
        guard item != .none else { return }
        for side in NotchHeaderSide.allCases {
            var slots = slots(side)
            var changed = false
            for index in slots.indices where slots[index] == item {
                slots[index] = .none
                changed = true
            }
            if changed { Defaults[side.key] = slots }
        }
    }

    static func move(from: (side: NotchHeaderSide, index: Int),
                     to: (side: NotchHeaderSide, index: Int)) {
        guard from.side != to.side || from.index != to.index else { return }
        let moving = slots(from.side)[from.index]
        let displaced = slots(to.side)[to.index]
        var source = slots(from.side)
        source[from.index] = .none
        Defaults[from.side.key] = source

        var target = slots(to.side)
        target[to.index] = moving
        Defaults[to.side.key] = target

        // Swap rather than drop: the displaced item goes back where the moved
        // one came from, which is what a drag between two filled slots reads as.
        if displaced != .none {
            var back = slots(from.side)
            back[from.index] = displaced
            Defaults[from.side.key] = back
        }
    }

    static func side(of item: NotchHeaderItem) -> NotchHeaderSide? {
        NotchHeaderSide.allCases.first { slots($0).contains(item) }
    }

    static func resetToDefaults() {
        Defaults[.notchHeaderLeading] = NotchHeaderItem.defaultLeading
        Defaults[.notchHeaderTrailing] = NotchHeaderItem.defaultTrailing
    }
}
