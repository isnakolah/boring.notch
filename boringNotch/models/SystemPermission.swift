//
//  SystemPermission.swift
//  boringNotch
//

import AppKit

/// What macOS has to allow, and what stops working without it.
///
/// Five panes had each invented their own permission row. HUD tinted a whole
/// card; Calendar drew red centred text; Tutor and Copilot each wrote a private
/// `permissionRow` with different spacing; Sweep drew a card of its own. They
/// disagreed on the verb — "Request", "Grant", "Open Privacy Settings" — on
/// whether "not asked yet" was a failure, and on which colour a missing
/// permission is. None of those were decisions either.
///
/// This is the metadata only. Reading the live status stays with whoever already
/// knows how to ask: `XPCHelperClient` for accessibility, `CallaEngineClient`
/// for the capture host, `CalendarManager` for the two EventKit stores. A single
/// enum that also polled six subsystems would be the same mistake at a different
/// altitude.
enum SystemPermission: String, CaseIterable, Identifiable {
    case accessibility
    case screenRecording
    case microphone
    case calendars
    case reminders
    case fullDiskAccess

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .microphone: return "Microphone"
        case .calendars: return "Calendars"
        case .reminders: return "Reminders"
        case .fullDiskAccess: return "Full Disk Access"
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: return "accessibility"
        case .screenRecording: return "rectangle.inset.filled.and.person.filled"
        case .microphone: return "mic"
        case .calendars: return "calendar"
        case .reminders: return "checklist"
        case .fullDiskAccess: return "externaldrive"
        }
    }

    /// The pane of System Settings that grants it.
    var privacyPaneURL: URL {
        let anchor: String
        switch self {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .microphone: anchor = "Privacy_Microphone"
        case .calendars: anchor = "Privacy_Calendars"
        case .reminders: anchor = "Privacy_Reminders"
        case .fullDiskAccess: anchor = "Privacy_AllFiles"
        }
        // Force-unwrapped because the string is a literal and the set is closed:
        // if one of these six stops parsing, that is a build-time mistake.
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    /// What the reader loses without it, in the concrete. Printed under the row,
    /// and the reason Privacy is a destination rather than six switches.
    var whatItUnlocks: String {
        switch self {
        case .accessibility:
            return "Replacing the system volume and brightness HUDs with the notch's own."
        case .screenRecording:
            return "Tutor watching the screen to know which step of a lesson you are on."
        case .microphone:
            return "The call copilot hearing the call it is meant to be helping with."
        case .calendars:
            return "Showing what is next in the notch, and starting a call on time."
        case .reminders:
            return "Showing reminders alongside events."
        case .fullDiskAccess:
            return "Sweep seeing the caches and backups that account for most reclaimable space."
        }
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(privacyPaneURL)
    }
}
