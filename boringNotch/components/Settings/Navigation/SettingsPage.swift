//
//  SettingsPage.swift
//  boringNotch
//

import SwiftUI

/// A destination inside a section.
///
/// Depth is almost always one. `copilotKnowledgeDetail` is the single exception
/// and the single case carrying a payload, which is why this is not a
/// `String`-raw enum. `Hashable` is the hard requirement — it is what
/// `NavigationStack` stores — and the string form needed for deep links is
/// built explicitly in `identifier` rather than synthesised, because synthesised
/// `Codable` over associated values produces an opaque encoding that no deep
/// link could ever be written by hand.
enum SettingsPage: Hashable {
    // General
    case displays, gestures, advanced
    // Appearance
    case accent, headerLayout, camera
    // Media
    case controlSlots
    // Calendar
    case calendarSources
    // System
    case battery, huds, usage
    // Shelf
    case localSend, kdeConnect
    // Call copilot
    //
    // `copilotModels` is Intelligence and Transcription merged. They were two
    // pages answering one question — which model does what — and the split put
    // "which brain answers" and "which ear hears" on opposite sides of a menu
    // even though choosing one constrains the other.
    case copilotCall, copilotModels, copilotPrompts
    case copilotKnowledge, copilotBackup, copilotHistory
    case copilotKnowledgeDetail(KnowledgeRoute)
    case copilotCallDetail(id: String)
    // Tutor
    //
    // Access folded into Behavior: what the tutor watches and what it is allowed
    // to watch is one question, and the answer to the second is what makes the
    // first work at all.
    case tutorCourses, tutorCreate, tutorBehavior, tutorEngine
    // Sweep
    //
    // No `cleanUp` page. The section's landing pane *is* the clean-up list —
    // Overview and Clean Up were reporting the same scan, and the first stood in
    // front of the only one anybody opened.
    case sweepHistory, sweepOptions

    /// The section this belongs to. One place, so a page can never be listed
    /// under one section and claim another in its breadcrumb.
    var section: SettingsSection {
        switch self {
        case .displays, .gestures, .advanced: return .general
        case .accent, .headerLayout, .camera: return .appearance
        case .controlSlots: return .media
        case .calendarSources: return .calendar
        case .battery, .huds, .usage: return .system
        case .localSend, .kdeConnect: return .shelf
        case .copilotCall, .copilotModels, .copilotPrompts, .copilotKnowledge,
             .copilotBackup, .copilotHistory, .copilotKnowledgeDetail, .copilotCallDetail:
            return .copilot
        case .tutorCourses, .tutorCreate, .tutorBehavior, .tutorEngine:
            return .tutor
        case .sweepHistory, .sweepOptions: return .sweep
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .displays: return "Displays"
        case .gestures: return "Gestures"
        case .advanced: return "Advanced"
        case .accent: return "Accent Colour"
        case .headerLayout: return "Header Layout"
        case .camera: return "Camera & Visualizers"
        case .controlSlots: return "Control Slots"
        case .calendarSources: return "Calendars & Lists"
        case .battery: return "Battery"
        case .huds: return "HUDs"
        case .usage: return "AI Usage"
        case .localSend: return "LocalSend"
        case .kdeConnect: return "KDE Connect"
        case .copilotCall: return "Live Call"
        case .copilotModels: return "Models"
        case .copilotPrompts: return "Prompts"
        case .copilotKnowledge: return "Knowledge"
        case .copilotBackup: return "Backup"
        case .copilotHistory: return "History"
        case .copilotKnowledgeDetail: return "Details"
        case .copilotCallDetail: return "Call"
        case .tutorCourses: return "Courses"
        case .tutorCreate: return "Create"
        case .tutorBehavior: return "Behaviour & Access"
        case .tutorEngine: return "Engine"
        case .sweepHistory: return "History"
        case .sweepOptions: return "Options"
        }
    }

    var symbol: String {
        switch self {
        case .displays: return "display.2"
        case .gestures: return "hand.draw"
        case .advanced: return "gearshape.2"
        case .accent: return "paintpalette"
        case .headerLayout: return "rectangle.3.group"
        case .camera: return "camera"
        case .controlSlots: return "slider.horizontal.below.rectangle"
        case .calendarSources: return "calendar.badge.checkmark"
        case .battery: return "battery.100.bolt"
        case .huds: return "dial.medium.fill"
        case .usage: return "gauge.with.needle"
        case .localSend: return "antenna.radiowaves.left.and.right"
        case .kdeConnect: return "iphone.gen3.radiowaves.left.and.right"
        case .copilotCall: return "waveform.badge.mic"
        case .copilotModels: return "brain"
        case .copilotPrompts: return "text.quote"
        case .copilotKnowledge: return "brain.head.profile"
        case .copilotBackup: return "arrow.up.arrow.down.square"
        case .copilotHistory: return "clock.arrow.circlepath"
        case .copilotKnowledgeDetail: return "doc.text"
        case .copilotCallDetail: return "waveform"
        case .tutorCourses: return "books.vertical.fill"
        case .tutorCreate: return "wand.and.stars"
        case .tutorBehavior: return "slider.horizontal.3"
        case .tutorEngine: return "bolt.horizontal.circle"
        case .sweepHistory: return "clock.arrow.circlepath"
        case .sweepOptions: return "slider.horizontal.3"
        }
    }

    /// The sentence on the drill row that says what is behind it, so the reader
    /// does not have to open a page to find out whether it is the one they want.
    var detail: LocalizedStringResource? {
        switch self {
        case .displays: return "Which screen the notch appears on, and what happens when you plug one in."
        case .gestures: return "Swiping the notch open and closed."
        case .advanced: return "Shadow, corner radius, lock screen, and hiding from screen recordings."
        case .accent: return "The colour used for anything active or selected."
        case .headerLayout: return "What sits either side of the notch, and in which order."
        case .camera: return "The mirror, its shape, and the music visualizer."
        case .controlSlots: return "Which playback controls appear, and where."
        case .calendarSources: return "Which calendars and reminder lists are shown."
        case .battery: return "Charge, power source, and the notifications about them."
        case .huds: return "Replacing the system volume and brightness overlays."
        case .usage: return "How much of your Claude and Codex allowance is left."
        case .localSend: return "Sending shelf items to other devices over the network."
        case .kdeConnect: return "Pairing with a phone through KDE Connect."
        case .copilotCall: return "What is captured during a call, and what shows in the notch."
        case .copilotModels: return "Which model hears the call, and which one answers."
        case .copilotPrompts: return "Who you are, and how each kind of call should be handled."
        case .copilotKnowledge: return "What the copilot has been given for each meeting."
        case .copilotBackup: return "Export these settings, bring them back, or start over."
        case .copilotHistory: return "Past calls, their transcripts and what was suggested."
        case .copilotKnowledgeDetail: return nil
        case .copilotCallDetail: return nil
        case .tutorCourses: return "Everything installed, and where you left off."
        case .tutorCreate: return "Building a new course or revising one."
        case .tutorBehavior: return "What the tutor watches, how it points, and which apps it may see."
        case .tutorEngine: return "The runtime, the gateway, and what it last did."
        case .sweepHistory: return "What has been freed, and what grew back."
        case .sweepOptions: return "Scan roots, exclusions, and when the helper stops."
        }
    }

    /// Words that should find this page in the sidebar search field but do not
    /// appear in its title. Merging twenty-seven rows into thirteen puts most
    /// destinations one click deep; this is what keeps them findable.
    var keywords: [String] {
        switch self {
        case .displays: return ["monitor", "screen", "external", "sidecar"]
        case .gestures: return ["swipe", "trackpad", "scroll"]
        case .advanced: return ["shadow", "corner radius", "lock screen", "screen recording", "app icon"]
        case .accent: return ["colour", "color", "tint", "theme"]
        case .headerLayout: return ["slots", "items", "left", "right", "arrange"]
        case .camera: return ["mirror", "selfie", "face", "spectrogram", "visualizer"]
        case .controlSlots: return ["playback", "buttons", "shuffle", "repeat", "next"]
        case .calendarSources: return ["reminders", "events", "ical", "google"]
        case .battery: return ["charge", "power", "percentage", "plugged in"]
        case .huds: return ["volume", "brightness", "overlay", "indicator"]
        case .usage: return ["claude", "codex", "quota", "allowance", "tokens", "limit", "cli"]
        case .localSend: return ["airdrop", "transfer", "share", "network"]
        case .kdeConnect: return ["phone", "android", "pair"]
        case .copilotCall: return ["meeting", "live", "zoom", "meet", "teams"]
        case .copilotModels: return ["model", "gateway", "local", "agy", "gemini", "claude",
                                     "intelligence", "whisper", "speech", "transcript",
                                     "transcription", "download"]
        case .copilotPrompts: return ["persona", "about me", "guidance", "system prompt"]
        case .copilotKnowledge: return ["notes", "documents", "files", "context"]
        case .copilotBackup: return ["export", "import", "reset", "settings", "json"]
        case .copilotHistory: return ["archive", "past calls", "export"]
        case .copilotKnowledgeDetail: return []
        case .copilotCallDetail: return []
        case .tutorCourses: return ["lessons", "library", "resume"]
        case .tutorCreate: return ["author", "outline", "scene", "build"]
        case .tutorBehavior: return ["tooltip", "cursor", "capture", "watch",
                                     "allowed apps", "bundle", "permission", "access"]
        case .tutorEngine: return ["runtime", "gateway", "diagnostics", "version"]
        case .sweepHistory: return ["freed", "regrowth", "space"]
        case .sweepOptions: return ["exclusions", "scan roots", "interval", "lifetime"]
        }
    }

    /// Every page without a payload: what search indexes, and what the tests
    /// walk. `copilotKnowledgeDetail` is excluded because its instances are
    /// user data, not destinations that exist before the data does.
    static let indexable: [SettingsPage] = [
        .displays, .gestures, .advanced,
        .accent, .headerLayout, .camera,
        .controlSlots,
        .calendarSources,
        .battery, .huds, .usage,
        .localSend, .kdeConnect,
        .copilotCall, .copilotModels, .copilotPrompts,
        .copilotKnowledge, .copilotBackup, .copilotHistory,
        .tutorCourses, .tutorCreate, .tutorBehavior, .tutorEngine,
        .sweepHistory, .sweepOptions,
    ]
}

// MARK: - The string form

extension SettingsPage {
    /// A stable, writable name for this page: `"system.battery"`,
    /// `"copilot.knowledge.event:F3A1-…"`.
    ///
    /// One mechanism doing four jobs — deep links, the legacy identifiers,
    /// window restoration, and any future URL scheme — instead of four mappings
    /// that drift apart. Hand-written rather than synthesised so it can be typed
    /// into a link by a person.
    var identifier: String {
        if case let .copilotKnowledgeDetail(route) = self {
            return "copilot.knowledge.\(route.identifier)"
        }
        if case let .copilotCallDetail(id) = self {
            return "copilot.history.call:\(id)"
        }
        return "\(section.rawValue).\(Self.stems[self] ?? "")"
    }

    init?(identifier: String) {
        if identifier.hasPrefix("copilot.history.call:") {
            self = .copilotCallDetail(id: String(identifier.dropFirst("copilot.history.call:".count)))
            return
        }
        if identifier.hasPrefix("copilot.knowledge."),
           let route = KnowledgeRoute(identifier: String(identifier.dropFirst("copilot.knowledge.".count))) {
            self = .copilotKnowledgeDetail(route)
            return
        }
        if let retired = Self.retired[identifier] {
            self = retired
            return
        }
        guard let match = Self.indexable.first(where: { $0.identifier == identifier }) else { return nil }
        self = match
    }

    /// Identifiers of pages that were merged away, pointing at whatever now
    /// answers their question. A link written before the merge still works, and
    /// arrives somewhere that contains what it asked for.
    private static let retired: [String: SettingsPage] = [
        "copilot.intelligence": .copilotModels,
        "copilot.transcription": .copilotModels,
        "tutor.access": .tutorBehavior,
    ]

    /// The part after the section name. A table rather than a `switch` so the
    /// forward and reverse directions cannot disagree.
    private static let stems: [SettingsPage: String] = [
        .displays: "displays", .gestures: "gestures", .advanced: "advanced",
        .accent: "accent", .headerLayout: "header-layout", .camera: "camera",
        .controlSlots: "control-slots",
        .calendarSources: "sources",
        .battery: "battery", .huds: "huds", .usage: "usage",
        .localSend: "localsend", .kdeConnect: "kde-connect",
        .copilotCall: "call", .copilotModels: "models", .copilotPrompts: "prompts",
        .copilotKnowledge: "knowledge", .copilotBackup: "backup",
        .copilotHistory: "history",
        .tutorCourses: "courses", .tutorCreate: "create", .tutorBehavior: "behavior",
        .tutorEngine: "engine",
        .sweepHistory: "history", .sweepOptions: "options",
    ]
}

extension KnowledgeRoute {
    var identifier: String {
        switch self {
        case let .event(id): return "event:\(id)"
        case .everyCall: return "every-call"
        case .byPersona: return "by-persona"
        case .orphaned: return "orphaned"
        }
    }

    init?(identifier: String) {
        switch identifier {
        case "every-call": self = .everyCall
        case "by-persona": self = .byPersona
        case "orphaned": self = .orphaned
        default:
            guard identifier.hasPrefix("event:") else { return nil }
            self = .event(id: String(identifier.dropFirst("event:".count)))
        }
    }
}
