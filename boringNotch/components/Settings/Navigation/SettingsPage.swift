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
    case copilotCall, copilotIntelligence, copilotPrompts
    case copilotKnowledge, copilotTranscription, copilotHistory
    case copilotKnowledgeDetail(KnowledgeRoute)
    // Tutor
    case tutorCourses, tutorCreate, tutorBehavior, tutorAccess, tutorEngine
    // Sweep
    case sweepCleanUp, sweepHistory, sweepOptions

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
        case .copilotCall, .copilotIntelligence, .copilotPrompts, .copilotKnowledge,
             .copilotTranscription, .copilotHistory, .copilotKnowledgeDetail:
            return .copilot
        case .tutorCourses, .tutorCreate, .tutorBehavior, .tutorAccess, .tutorEngine:
            return .tutor
        case .sweepCleanUp, .sweepHistory, .sweepOptions: return .sweep
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
        case .usage: return "Usage Monitor"
        case .localSend: return "LocalSend"
        case .kdeConnect: return "KDE Connect"
        case .copilotCall: return "Call"
        case .copilotIntelligence: return "Intelligence"
        case .copilotPrompts: return "Prompts"
        case .copilotKnowledge: return "Knowledge"
        case .copilotTranscription: return "Transcription"
        case .copilotHistory: return "History"
        case .copilotKnowledgeDetail: return "Details"
        case .tutorCourses: return "Courses"
        case .tutorCreate: return "Create"
        case .tutorBehavior: return "Behavior"
        case .tutorAccess: return "Access"
        case .tutorEngine: return "Engine"
        case .sweepCleanUp: return "Clean Up"
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
        case .usage: return "chart.bar.xaxis"
        case .localSend: return "antenna.radiowaves.left.and.right"
        case .kdeConnect: return "iphone.gen3.radiowaves.left.and.right"
        case .copilotCall: return "waveform.badge.mic"
        case .copilotIntelligence: return "brain"
        case .copilotPrompts: return "text.quote"
        case .copilotKnowledge: return "brain.head.profile"
        case .copilotTranscription: return "waveform"
        case .copilotHistory: return "clock.arrow.circlepath"
        case .copilotKnowledgeDetail: return "doc.text"
        case .tutorCourses: return "books.vertical.fill"
        case .tutorCreate: return "wand.and.stars"
        case .tutorBehavior: return "slider.horizontal.3"
        case .tutorAccess: return "lock.shield"
        case .tutorEngine: return "bolt.horizontal.circle"
        case .sweepCleanUp: return "sparkles"
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
        case .usage: return "CPU, memory and the quota meters beside the notch."
        case .localSend: return "Sending shelf items to other devices over the network."
        case .kdeConnect: return "Pairing with a phone through KDE Connect."
        case .copilotCall: return "Starting a call, and what shows in the notch during one."
        case .copilotIntelligence: return "Which model answers, and where it runs."
        case .copilotPrompts: return "Who you are, and how each kind of call should be handled."
        case .copilotKnowledge: return "What the copilot has been given for each meeting."
        case .copilotTranscription: return "The speech model, and what happens after a call."
        case .copilotHistory: return "Past calls, their transcripts and what was suggested."
        case .copilotKnowledgeDetail: return nil
        case .tutorCourses: return "Everything installed, and where you left off."
        case .tutorCreate: return "Building a new course or revising one."
        case .tutorBehavior: return "What the tutor watches, and how it points."
        case .tutorAccess: return "Which applications the tutor may look at."
        case .tutorEngine: return "The runtime, the gateway, and what it last did."
        case .sweepCleanUp: return "What can be reclaimed, by category."
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
        case .usage: return ["cpu", "memory", "ram", "quota", "claude"]
        case .localSend: return ["airdrop", "transfer", "share", "network"]
        case .kdeConnect: return ["phone", "android", "pair"]
        case .copilotCall: return ["meeting", "live", "zoom", "meet", "teams"]
        case .copilotIntelligence: return ["model", "gateway", "local", "agy", "gemini", "claude"]
        case .copilotPrompts: return ["persona", "about me", "guidance", "system prompt"]
        case .copilotKnowledge: return ["notes", "documents", "files", "context"]
        case .copilotTranscription: return ["whisper", "speech", "transcript", "download"]
        case .copilotHistory: return ["archive", "past calls", "export"]
        case .copilotKnowledgeDetail: return []
        case .tutorCourses: return ["lessons", "library", "resume"]
        case .tutorCreate: return ["author", "outline", "scene", "build"]
        case .tutorBehavior: return ["tooltip", "cursor", "capture", "watch"]
        case .tutorAccess: return ["allowed apps", "bundle", "permission"]
        case .tutorEngine: return ["runtime", "gateway", "diagnostics", "version"]
        case .sweepCleanUp: return ["reclaim", "delete", "cache", "junk"]
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
        .copilotCall, .copilotIntelligence, .copilotPrompts,
        .copilotKnowledge, .copilotTranscription, .copilotHistory,
        .tutorCourses, .tutorCreate, .tutorBehavior, .tutorAccess, .tutorEngine,
        .sweepCleanUp, .sweepHistory, .sweepOptions,
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
        return "\(section.rawValue).\(Self.stems[self] ?? "")"
    }

    init?(identifier: String) {
        if identifier.hasPrefix("copilot.knowledge."),
           let route = KnowledgeRoute(identifier: String(identifier.dropFirst("copilot.knowledge.".count))) {
            self = .copilotKnowledgeDetail(route)
            return
        }
        guard let match = Self.indexable.first(where: { $0.identifier == identifier }) else { return nil }
        self = match
    }

    /// The part after the section name. A table rather than a `switch` so the
    /// forward and reverse directions cannot disagree.
    private static let stems: [SettingsPage: String] = [
        .displays: "displays", .gestures: "gestures", .advanced: "advanced",
        .accent: "accent", .headerLayout: "header-layout", .camera: "camera",
        .controlSlots: "control-slots",
        .calendarSources: "sources",
        .battery: "battery", .huds: "huds", .usage: "usage",
        .localSend: "localsend", .kdeConnect: "kde-connect",
        .copilotCall: "call", .copilotIntelligence: "intelligence", .copilotPrompts: "prompts",
        .copilotKnowledge: "knowledge", .copilotTranscription: "transcription",
        .copilotHistory: "history",
        .tutorCourses: "courses", .tutorCreate: "create", .tutorBehavior: "behavior",
        .tutorAccess: "access", .tutorEngine: "engine",
        .sweepCleanUp: "clean-up", .sweepHistory: "history", .sweepOptions: "options",
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
