//
//  SettingsDestinations.swift
//  boringNotch
//

import Sparkle
import SwiftUI

/// What each route actually draws.
///
/// One file, so the answer to "what is behind this row" is in one place rather
/// than spread across a switch in the shell and a second switch in the sidebar.
extension SettingsSection {
    @ViewBuilder var landingPane: some View {
        switch self {
        case .general: GeneralSettings()
        case .appearance: Appearance()
        case .media: Media()
        case .calendar: CalendarSettings()
        case .system: SystemPane()
        case .shelf: Shelf()
        case .pomodoro: PomodoroSettings()
        case .copilot: CopilotPane()
        case .tutor: TutorPane()
        case .sweep: SweepSettings(selectedTab: .overview)
        case .shortcuts: ShortcutsPane()
        case .privacy: PrivacyPane()
        case .about: AboutPaneHost()
        }
    }
}

extension SettingsPage {
    @ViewBuilder var view: some View {
        switch self {
        case .displays: DisplaysPane()
        case .gestures: GesturesPane()
        case .advanced: Advanced()
        case .accent: AccentPane()
        case .headerLayout: NotchLayoutPane()
        case .camera: CameraPane()
        case .controlSlots: MusicSlotConfigurationView()
        case .calendarSources: CalendarSourcesPane()
        case .battery: Charge()
        case .huds: HUD()
        case .usage: UsageMonitorSettings()
        case .localSend: LocalSendPane()
        case .kdeConnect: KDEConnectPane()
        case .copilotCall: CopilotCallPane()
        case .copilotIntelligence: CopilotIntelligencePane()
        case .copilotPrompts: CopilotPromptsPane()
        case .copilotKnowledge: CopilotKnowledgePane()
        case .copilotTranscription: CopilotTranscriptionPane()
        case .copilotHistory: CopilotHistoryPane()
        case let .copilotKnowledgeDetail(route): CopilotKnowledgeDetailPane(route: route)
        case let .copilotCallDetail(id): CopilotCallDetailPane(callID: id)
        case .tutorCourses: TutorCoursesPane()
        case .tutorCreate: TutorCreatePane()
        case .tutorBehavior: TutorBehaviorPane()
        case .tutorAccess: TutorAccessPane()
        case .tutorEngine: TutorEnginePane()
        case .sweepCleanUp: SweepSettings(selectedTab: .cleanUp)
        case .sweepHistory: SweepSettings(selectedTab: .history)
        case .sweepOptions: SweepSettings(selectedTab: .options)
        }
    }
}

/// About needs a Sparkle updater and the window controller injects one late, so
/// this reads the one the shell put in the environment rather than manufacturing
/// a throwaway controller the way the old switch did.
struct AboutPaneHost: View {
    @Environment(\.sparkleUpdater) private var updater

    var body: some View {
        About(updaterController: updater)
    }
}

private struct SparkleUpdaterKey: EnvironmentKey {
    static let defaultValue = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
}

extension EnvironmentValues {
    var sparkleUpdater: SPUStandardUpdaterController {
        get { self[SparkleUpdaterKey.self] }
        set { self[SparkleUpdaterKey.self] = newValue }
    }
}
