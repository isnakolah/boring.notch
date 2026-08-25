//
//  SettingsRoute.swift
//  boringNotch
//

import Foundation

/// Where the window is: which section, and how far into it.
struct SettingsRoute: Hashable {
    var section: SettingsSection
    var path: [SettingsPage]

    init(_ section: SettingsSection, _ path: [SettingsPage] = []) {
        self.section = section
        self.path = path
    }

    /// The page actually on screen, or `nil` at a section's landing pane.
    var leaf: SettingsPage? { path.last }

    /// The trail, outermost first. The breadcrumb is a pure function of this —
    /// there is no navigation state to keep in sync, because the array is the
    /// path.
    var crumbs: [LocalizedStringResource] { [section.title] + path.map(\.title) }
}

// MARK: - The string form

extension SettingsRoute {
    /// `"system"`, `"system.battery"`, `"copilot.knowledge.event:F3A1-…"`.
    var identifier: String {
        leaf.map(\.identifier) ?? section.rawValue
    }

    init?(identifier: String) {
        if let page = SettingsPage(identifier: identifier) {
            // A detail page is only reachable through the page it details.
            if case let .copilotKnowledgeDetail(route) = page {
                self.init(.copilot, [.copilotKnowledge, .copilotKnowledgeDetail(route)])
            } else if case let .copilotCallDetail(id) = page {
                self.init(.copilot, [.copilotHistory, .copilotCallDetail(id: id)])
            } else {
                self.init(page.section, [page])
            }
            return
        }
        guard let section = SettingsSection(rawValue: identifier) else { return nil }
        self.init(section)
    }
}

// MARK: - Deep links

extension SettingsRoute {
    /// Deep links, restored state and menu items still arrive as the old
    /// strings. Both spellings are accepted: the external names the rest of the
    /// app passes ("Tutor", "CopilotHistory") and the twenty-seven raw values of
    /// the flat `SettingsTab` this replaced, because that type's own initialiser
    /// fell through to `SettingsTab(rawValue:)` and callers may have relied on it.
    ///
    /// Two deliberate asymmetries: "Copilot" lands on the Call page and "Tutor"
    /// on Courses, rather than on their new landing panes. Those callers are
    /// pointing at a specific thing and should keep arriving where they always
    /// have.
    init(legacyIdentifier raw: String) {
        switch raw {
        case "General", "general": self = .init(.general)
        case "Appearance", "appearance": self = .init(.appearance)
        case "Layout", "NotchLayout", "layout": self = .init(.appearance, [.headerLayout])
        case "Advanced", "advanced": self = .init(.general, [.advanced])
        case "Media", "media": self = .init(.media)
        case "Calendar", "calendar": self = .init(.calendar)
        case "Battery", "battery": self = .init(.system, [.battery])
        case "HUD", "huds": self = .init(.system, [.huds])
        case "Usage", "usage": self = .init(.system, [.usage])
        case "Shelf", "shelf": self = .init(.shelf)
        case "Pomodoro", "pomodoro": self = .init(.pomodoro)
        case "Copilot", "CallCopilot", "copilotCall": self = .init(.copilot, [.copilotCall])
        case "CopilotIntelligence", "copilotIntelligence": self = .init(.copilot, [.copilotModels])
        case "CopilotPrompts", "copilotPrompts": self = .init(.copilot, [.copilotPrompts])
        case "CopilotKnowledge", "copilotKnowledge": self = .init(.copilot, [.copilotKnowledge])
        case "CopilotTranscription", "copilotTranscription": self = .init(.copilot, [.copilotModels])
        case "CopilotModels", "copilotModels": self = .init(.copilot, [.copilotModels])
        case "CopilotHistory", "copilotHistory": self = .init(.copilot, [.copilotHistory])
        case "Tutor", "tutorCourses": self = .init(.tutor, [.tutorCourses])
        case "tutorCreate": self = .init(.tutor, [.tutorCreate])
        case "tutorBehavior": self = .init(.tutor, [.tutorBehavior])
        case "tutorAccess": self = .init(.tutor, [.tutorBehavior])
        case "tutorEngine": self = .init(.tutor, [.tutorEngine])
        case "Sweep", "sweep": self = .init(.sweep)
        // Clean Up is the section's landing pane now, so the link that used to
        // push it lands on the section instead of pushing a page that is gone.
        case "sweepCleanUp": self = .init(.sweep)
        case "sweepHistory": self = .init(.sweep, [.sweepHistory])
        case "sweepOptions": self = .init(.sweep, [.sweepOptions])
        case "Shortcuts", "shortcuts": self = .init(.shortcuts)
        case "Privacy", "privacy": self = .init(.privacy)
        case "About", "about": self = .init(.about)
        default: self = SettingsRoute(identifier: raw) ?? .init(.general)
        }
    }
}
