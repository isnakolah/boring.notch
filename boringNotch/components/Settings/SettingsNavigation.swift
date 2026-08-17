import SwiftUI

/// Where the Settings window can go.
///
/// Tab identity used to be a bare `String` compared in a fourteen-case `switch`,
/// with a `default:` that quietly fell back to General — so a typo in a deep
/// link was indistinguishable from asking for General on purpose.
///
/// Tutor's sub-panes are destinations here rather than a segmented `Picker`
/// inside the Tutor pane. That picker, and Sweep's, meant the window had two
/// competing navigation models: fourteen items in the sidebar, and a second row
/// of tabs that appeared only on two of them. One model is the whole fix.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, advanced
    case media, battery, huds, calendar
    case shelf
    case tutorCourses, tutorCreate, tutorBehavior, tutorAccess, tutorEngine
    case pomodoro, sweep, usage
    case shortcuts, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .advanced: return "Advanced"
        case .media: return "Media"
        case .battery: return "Battery"
        case .huds: return "HUDs"
        case .calendar: return "Calendar"
        case .shelf: return "Shelf"
        case .tutorCourses: return "Courses"
        case .tutorCreate: return "Create"
        case .tutorBehavior: return "Behavior"
        case .tutorAccess: return "Access"
        case .tutorEngine: return "Engine"
        case .pomodoro: return "Pomodoro"
        case .sweep: return "Sweep"
        case .usage: return "Usage"
        case .shortcuts: return "Shortcuts"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gear"
        case .appearance: return "eye"
        case .advanced: return "gearshape.2"
        case .media: return "play.laptopcomputer"
        case .battery: return "battery.100.bolt"
        case .huds: return "dial.medium.fill"
        case .calendar: return "calendar"
        case .shelf: return "books.vertical"
        case .tutorCourses: return "books.vertical.fill"
        case .tutorCreate: return "wand.and.stars"
        case .tutorBehavior: return "slider.horizontal.3"
        case .tutorAccess: return "lock.shield"
        case .tutorEngine: return "bolt.horizontal.circle"
        case .pomodoro: return "timer.circle.fill"
        case .sweep: return "externaldrive.badge.checkmark"
        case .usage: return "chart.bar.xaxis"
        case .shortcuts: return "keyboard"
        case .about: return "info.circle"
        }
    }

    /// The sidebar group this belongs to, shown as the pane's eyebrow so the
    /// reader always knows where they are.
    var group: SettingsGroup {
        switch self {
        case .general, .appearance, .advanced: return .notch
        case .media, .battery, .huds, .calendar: return .activities
        case .shelf, .pomodoro, .sweep, .usage: return .tools
        case .tutorCourses, .tutorCreate, .tutorBehavior, .tutorAccess, .tutorEngine: return .tutor
        case .shortcuts, .about: return .app
        }
    }

    /// What the sidebar's notch preview shows while this pane is open. Panes
    /// with nothing of their own to draw fall to `.shape`, which is still the
    /// truth for them: General and Advanced are what set that geometry.
    var preview: NotchPreviewContent {
        switch self {
        case .media:
            return .media(title: "Windowlicker", artist: "Aphex Twin")
        case .battery:
            return .battery(percent: 68, charging: true)
        case .huds:
            return .hud(symbol: "speaker.wave.2.fill", fraction: 0.6)
        case .calendar:
            return .activity(symbol: "calendar", text: "Standup in 10m",
                             tint: NotchTint.active, caption: "Next event")
        case .shelf:
            return .activity(symbol: "tray.full.fill", text: "3 items on the shelf",
                             tint: NotchTint.active, caption: "Shelf activity")
        case .tutorCourses, .tutorCreate, .tutorBehavior, .tutorAccess, .tutorEngine:
            return .activity(symbol: "graduationcap.fill", text: "Shape the lamp base",
                             tint: NotchTint.active, caption: "A lesson in progress")
        case .pomodoro:
            return .activity(symbol: "timer", text: "24:10 focus",
                             tint: NotchTint.healthy, caption: "Focus timer")
        case .sweep:
            return .activity(symbol: "externaldrive.badge.checkmark", text: "12.4 GB reclaimable",
                             tint: NotchTint.attention, caption: "Sweep result")
        case .usage:
            return .activity(symbol: "chart.bar.xaxis", text: "CPU 32%",
                             tint: NotchTint.active, caption: "Usage monitor")
        case .general, .appearance, .advanced, .shortcuts, .about:
            return .shape
        }
    }

    /// Deep links and restored state still arrive as the old strings.
    init(legacyIdentifier: String) {
        switch legacyIdentifier {
        case "General": self = .general
        case "Appearance": self = .appearance
        case "Media": self = .media
        case "Calendar": self = .calendar
        case "HUD": self = .huds
        case "Battery": self = .battery
        case "Shelf": self = .shelf
        case "Tutor": self = .tutorCourses
        case "Usage": self = .usage
        case "Pomodoro": self = .pomodoro
        case "Sweep": self = .sweep
        case "Shortcuts": self = .shortcuts
        case "Advanced": self = .advanced
        case "About": self = .about
        default: self = SettingsTab(rawValue: legacyIdentifier) ?? .general
        }
    }
}

/// The four kinds of thing this window configures.
///
/// The grouping encodes something true rather than just shortening the list:
/// Notch panes change the slab's geometry and appearance, Activities are what it
/// displays, Tools are features that own their own data, App is the app itself.
enum SettingsGroup: String, CaseIterable, Identifiable {
    case notch, activities, tools, tutor, app

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notch: return "Notch"
        case .activities: return "Activities"
        case .tools: return "Tools"
        case .tutor: return "Tutor"
        case .app: return "App"
        }
    }

    var tabs: [SettingsTab] {
        switch self {
        case .notch: return [.general, .appearance, .advanced]
        case .activities: return [.media, .battery, .huds, .calendar]
        case .tools: return [.shelf, .pomodoro, .sweep, .usage]
        // Tutor gets a group rather than a disclosure under Tools. A
        // `DisclosureGroup` inside a selectable `List` rendered collapsed
        // regardless of its binding and would not toggle from the label, which
        // put five destinations behind a control that did not work. A group
        // header costs one line and hides nothing.
        case .tutor: return [.tutorCourses, .tutorCreate, .tutorBehavior, .tutorAccess, .tutorEngine]
        case .app: return [.shortcuts, .about]
        }
    }
}

/// The sidebar: the preview well, then the grouped destinations.
struct SettingsSidebar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        VStack(spacing: 0) {
            NotchPreviewWell(content: selection.preview)
            List(selection: $selection) {
                ForEach(SettingsGroup.allCases) { group in
                    Section(group.title) {
                        ForEach(group.tabs) { tab in
                            NavigationLink(value: tab) {
                                Label(tab.title, systemImage: tab.symbol)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(NotchSurface.base)
    }
}
