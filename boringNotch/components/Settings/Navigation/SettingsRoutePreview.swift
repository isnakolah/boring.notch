//
//  SettingsRoutePreview.swift
//  boringNotch
//

import Defaults
import SwiftUI

extension SettingsRoute {
    /// What the well above the sidebar shows while this route is open.
    ///
    /// The section sets the scene and the subpage refines it, so moving deeper
    /// sharpens the preview rather than replacing it. Panes with nothing of
    /// their own to draw fall to `.shape`, which is still the truth for them:
    /// General, Appearance and Advanced are what set that geometry.
    var previewContent: NotchPreviewContent {
        if let leaf { return Self.preview(for: leaf) ?? Self.preview(for: section) }
        return Self.preview(for: section)
    }

    private static func preview(for page: SettingsPage) -> NotchPreviewContent? {
        switch page {
        case .battery: return .battery(percent: 68, charging: true)
        case .huds: return .hud(symbol: "speaker.wave.2.fill", fraction: 0.6)
        case .usage:
            return .meter(label: "CPU 32%", fraction: 0.32,
                          tint: NotchTint.active, caption: "Usage monitor")
        case .headerLayout:
            return .slots(leading: Defaults[.notchHeaderLeading].compactMap { $0 },
                          trailing: Defaults[.notchHeaderTrailing].compactMap { $0 })
        case .controlSlots:
            return .media(title: "Windowlicker", artist: "Aphex Twin")
        case .accent, .camera, .displays, .gestures, .advanced:
            return .shape
        default: return nil
        }
    }

    private static func preview(for section: SettingsSection) -> NotchPreviewContent {
        switch section {
        case .media:
            return .media(title: "Windowlicker", artist: "Aphex Twin")
        case .calendar:
            return .activity(symbol: "calendar", text: "Standup in 10m",
                             tint: NotchTint.active, caption: "Next event")
        case .system:
            return .battery(percent: 68, charging: true)
        case .shelf:
            return .activity(symbol: "tray.full.fill", text: "3 items on the shelf",
                             tint: NotchTint.active, caption: "Shelf activity")
        case .pomodoro:
            return .activity(symbol: "timer", text: "24:10 focus",
                             tint: NotchTint.healthy, caption: "Focus timer")
        case .copilot:
            return .activity(symbol: "waveform.badge.mic", text: "When could you start?",
                             tint: NotchTint.active, caption: "A pointer mid-call")
        case .tutor:
            return .activity(symbol: "graduationcap.fill", text: "Shape the lamp base",
                             tint: NotchTint.active, caption: "A lesson in progress")
        case .sweep:
            return .meter(label: "12.4 GB", fraction: 0.34,
                          tint: NotchTint.attention, caption: "Reclaimable space")
        case .general, .appearance, .shortcuts, .privacy, .about:
            return .shape
        }
    }
}
