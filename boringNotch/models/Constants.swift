//
//  Constants.swift
//  boringNotch
//
//  Created by Richard Kunkli on 2024. 10. 17..
//

import SwiftUI
import Defaults

private let availableDirectories = FileManager
    .default
    .urls(for: .documentDirectory, in: .userDomainMask)
let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
let bundleIdentifier = Bundle.main.bundleIdentifier!
let appVersion = "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))"

let temporaryDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
let spacing: CGFloat = 16

struct CustomVisualizer: Codable, Hashable, Equatable, Defaults.Serializable {
    let UUID: UUID
    var name: String
    var url: URL
    var speed: CGFloat = 1.0
}

enum CalendarSelectionState: Codable, Defaults.Serializable {
    case all
    case selected(Set<String>)
}

enum HideNotchOption: String, Defaults.Serializable {
    case always
    case nowPlayingOnly
    case never
}

// Define notification names at file scope
extension Notification.Name {
    static let mediaControllerChanged = Notification.Name("mediaControllerChanged")
}

// Media controller types for selection in settings
enum MediaControllerType: String, CaseIterable, Identifiable, Defaults.Serializable {
    case nowPlaying = "Now Playing"
    case appleMusic = "Apple Music"
    case spotify = "Spotify"
    case youtubeMusic = "YouTube Music"
    
    var id: String { self.rawValue }
}

// Sneak peek styles for selection in settings
enum SneakPeekStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case standard = "Default"
    case inline = "Inline"
    
    var id: String { self.rawValue }
}

// Action to perform when Option (⌥) is held while pressing media keys
enum OptionKeyAction: String, CaseIterable, Identifiable, Defaults.Serializable {
    case openSettings = "Open System Settings"
    case showHUD = "Show HUD"
    case none = "No Action"

    var id: String { self.rawValue }
}

extension Defaults.Keys {
    // MARK: General
    static let menubarIcon = Key<Bool>("menubarIcon", default: true)
    static let showOnAllDisplays = Key<Bool>("showOnAllDisplays", default: false)
    static let automaticallySwitchDisplay = Key<Bool>("automaticallySwitchDisplay", default: true)
    static let releaseName = Key<String>("releaseName", default: "Flying Rabbit 🐇🪽")
    
    // MARK: Behavior
    static let minimumHoverDuration = Key<TimeInterval>("minimumHoverDuration", default: 0.3)
    static let enableHaptics = Key<Bool>("enableHaptics", default: true)
    static let openNotchOnHover = Key<Bool>("openNotchOnHover", default: true)
    static let extendHoverArea = Key<Bool>("extendHoverArea", default: false)
    static let notchHeightMode = Key<WindowHeightMode>(
        "notchHeightMode",
        default: WindowHeightMode.matchRealNotchSize
    )
    static let nonNotchHeightMode = Key<WindowHeightMode>(
        "nonNotchHeightMode",
        default: WindowHeightMode.matchMenuBar
    )
    static let nonNotchHeight = Key<CGFloat>("nonNotchHeight", default: 32)
    static let notchHeight = Key<CGFloat>("notchHeight", default: 32)
    //static let openLastTabByDefault = Key<Bool>("openLastTabByDefault", default: false)
    static let showOnLockScreen = Key<Bool>("showOnLockScreen", default: false)
    static let hideFromScreenRecording = Key<Bool>("hideFromScreenRecording", default: false)
    
    // MARK: Appearance
    static let showEmojis = Key<Bool>("showEmojis", default: false)
    //static let alwaysShowTabs = Key<Bool>("alwaysShowTabs", default: true)
    static let showMirror = Key<Bool>("showMirror", default: false)
    static let mirrorShape = Key<MirrorShapeEnum>("mirrorShape", default: MirrorShapeEnum.rectangle)
    static let settingsIconInNotch = Key<Bool>("settingsIconInNotch", default: true)
    static let lightingEffect = Key<Bool>("lightingEffect", default: true)
    static let enableShadow = Key<Bool>("enableShadow", default: true)
    static let cornerRadiusScaling = Key<Bool>("cornerRadiusScaling", default: true)

    static let showNotHumanFace = Key<Bool>("showNotHumanFace", default: false)
    static let tileShowLabels = Key<Bool>("tileShowLabels", default: false)
    static let showCalendar = Key<Bool>("showCalendar", default: false)
    static let hideCompletedReminders = Key<Bool>("hideCompletedReminders", default: true)
    static let sliderColor = Key<SliderColorEnum>(
        "sliderUseAlbumArtColor",
        default: SliderColorEnum.white
    )
    static let playerColorTinting = Key<Bool>("playerColorTinting", default: true)
    static let useMusicVisualizer = Key<Bool>("useMusicVisualizer", default: true)
    static let customVisualizers = Key<[CustomVisualizer]>("customVisualizers", default: [])
    static let selectedVisualizer = Key<CustomVisualizer?>("selectedVisualizer", default: nil)
    
    // MARK: Gestures
    static let enableGestures = Key<Bool>("enableGestures", default: true)
    static let closeGestureEnabled = Key<Bool>("closeGestureEnabled", default: true)
    static let gestureSensitivity = Key<CGFloat>("gestureSensitivity", default: 200.0)
    
    // MARK: Media playback
    static let coloredSpectrogram = Key<Bool>("coloredSpectrogram", default: true)
    static let enableSneakPeek = Key<Bool>("enableSneakPeek", default: false)
    static let sneakPeekStyles = Key<SneakPeekStyle>("sneakPeekStyles", default: .standard)
    static let waitInterval = Key<Double>("waitInterval", default: 3)
    static let showShuffleAndRepeat = Key<Bool>("showShuffleAndRepeat", default: false)
    static let enableLyrics = Key<Bool>("enableLyrics", default: false)
    static let musicControlSlots = Key<[MusicControlButton]>(
        "musicControlSlots",
        default: MusicControlButton.defaultLayout
    )
    static let musicControlSlotLimit = Key<Int>(
        "musicControlSlotLimit",
        default: MusicControlButton.defaultLayout.count
    )
    
    // MARK: Battery
    static let showPowerStatusNotifications = Key<Bool>("showPowerStatusNotifications", default: true)
    static let showBatteryIndicator = Key<Bool>("showBatteryIndicator", default: true)
    static let showBatteryPercentage = Key<Bool>("showBatteryPercentage", default: true)
    static let showPowerStatusIcons = Key<Bool>("showPowerStatusIcons", default: true)
    
    // MARK: Downloads
    static let enableDownloadListener = Key<Bool>("enableDownloadListener", default: true)
    static let enableSafariDownloads = Key<Bool>("enableSafariDownloads", default: true)
    static let selectedDownloadIndicatorStyle = Key<DownloadIndicatorStyle>("selectedDownloadIndicatorStyle", default: DownloadIndicatorStyle.progress)
    static let selectedDownloadIconStyle = Key<DownloadIconStyle>("selectedDownloadIconStyle", default: DownloadIconStyle.onlyAppIcon)
    
    // MARK: HUD
    static let hudReplacement = Key<Bool>("hudReplacement", default: false)
    static let inlineHUD = Key<Bool>("inlineHUD", default: false)
    static let enableGradient = Key<Bool>("enableGradient", default: false)
    static let systemEventIndicatorShadow = Key<Bool>("systemEventIndicatorShadow", default: false)
    static let systemEventIndicatorUseAccent = Key<Bool>("systemEventIndicatorUseAccent", default: false)
    static let showOpenNotchHUD = Key<Bool>("showOpenNotchHUD", default: true)
    static let showOpenNotchHUDPercentage = Key<Bool>("showOpenNotchHUDPercentage", default: true)
    static let showClosedNotchHUDPercentage = Key<Bool>("showClosedNotchHUDPercentage", default: false)
    static let showInlineHUDLabel = Key<Bool>("showInlineHUDLabel", default: false)
    // Option key modifier behaviour for media keys
    static let optionKeyAction = Key<OptionKeyAction>("optionKeyAction", default: OptionKeyAction.openSettings)
    
    // MARK: Shelf
    static let boringShelf = Key<Bool>("boringShelf", default: true)
    static let openShelfByDefault = Key<Bool>("openShelfByDefault", default: true)
    static let shelfTapToOpen = Key<Bool>("shelfTapToOpen", default: true)
    static let localSendDestination = Key<String>("localSendDestination", default: LocalSendDestination.phone.rawValue)
    static let localSendBindings = Key<String>("localSendBindings", default: "[]")
    static let localSendIdentity = Key<String>("localSendIdentity", default: "")
    static let shelfShareTransport = Key<String>("shelfShareTransport", default: ShelfShareTransport.localSend.rawValue)
    static let kdeConnectBindings = Key<String>("kdeConnectBindings", default: "[]")
    static let copyOnDrag = Key<Bool>("copyOnDrag", default: false)
    static let autoRemoveShelfItems = Key<Bool>("autoRemoveShelfItems", default: false)
    static let shelfRemoveAfterSend = Key<Bool>("shelfRemoveAfterSend", default: false)
    static let expandedDragDetection = Key<Bool>("expandedDragDetection", default: true)

    // MARK: Calla Tutor
    // These keys are intentionally Boring-owned. Never read the retired
    // com.calla.tutor-host preference domain.
    static let callaTutorEnabled = Key<Bool>("callaTutorEnabled", default: true)
    static let callaCaptureEnabled = Key<Bool>("callaCaptureEnabled", default: true)
    static let callaAllowedBundleIDs = Key<[String]>("callaAllowedBundleIDs", default: ["org.blenderfoundation.blender"])
    static let callaCaptureLongEdge = Key<Int>("callaCaptureLongEdge", default: 1600)
    static let callaTooltipWidth = Key<Int>("callaTooltipWidth", default: 340)
    static let callaHideTooltipOnHover = Key<Bool>("callaHideTooltipOnHover", default: true)
    static let callaCursorSize = Key<Int>("callaCursorSize", default: 30)
    static let callaTooltipOpacity = Key<Double>("callaTooltipOpacity", default: 0.92)
    static let callaShowStatusHUD = Key<Bool>("callaShowStatusHUD", default: true)
    static let callaLearnerID = Key<String>("callaLearnerID", default: "")
    static let callaHiddenCourseIDs = Key<[String]>("callaHiddenCourseIDs", default: [])
    static let callaCalendarEnabled = Key<Bool>("callaCalendarEnabled", default: true)
    static let callaCalendarBindings = Key<Data?>("callaCalendarBindings", default: nil)

    // MARK: Calla Call Copilot
    static let callaCopilotEnabled = Key<Bool>("callaCopilotEnabled", default: true)
    /// Which conversation the pointers are tuned for. Bound at call start; the
    /// gateway validates it against the same allowlist.
    static let callaCopilotPersona = Key<String>("callaCopilotPersona", default: "generic")
    /// Live transcription model. The archive model is deliberately not offered:
    /// its CoreML encoder forces whisper's full 30s context per utterance.
    static let callaCopilotLiveModel = Key<String>("callaCopilotLiveModel", default: "whisper-small-en")
    /// Peek the newest pointer in the notch as it arrives.
    static let callaCopilotAutoReveal = Key<Bool>("callaCopilotAutoReveal", default: true)
    /// Re-transcribe the saved audio with the large model after the call ends.
    static let callaCopilotArchiveRetranscribe = Key<Bool>("callaCopilotArchiveRetranscribe", default: false)

    // MARK: Usage Monitor
    static let usageMonitorTab = Key<Bool>("usageMonitorTab", default: false)
    static let usageMonitorRefreshInterval = Key<Double>("usageMonitorRefreshInterval", default: 300)
    static let showUsageBesideNotch = Key<Bool>("showUsageBesideNotch", default: false)
    // Last successful usage report per provider (UsageReportDTO JSON), shown
    // while a fresh probe fails or before the first probe completes.
    static let cachedClaudeUsage = Key<Data?>("cachedClaudeUsage", default: nil)
    static let cachedCodexUsage = Key<Data?>("cachedCodexUsage", default: nil)

    // MARK: Pomodoro
    static let pomodoroTab = Key<Bool>("pomodoroTab", default: false)
    static let pomodoroPresets = Key<[PomodoroPreset]>("pomodoroPresets", default: PomodoroPreset.seeded)
    static let pomodoroSelectedPresetID = Key<String>("pomodoroSelectedPresetID", default: PomodoroPreset.classic.id)
    static let pomodoroAutoStartBreaks = Key<Bool>("pomodoroAutoStartBreaks", default: true)
    static let pomodoroAutoStartWork = Key<Bool>("pomodoroAutoStartWork", default: false)
    static let pomodoroOpenNotchOnPhaseEnd = Key<Bool>("pomodoroOpenNotchOnPhaseEnd", default: true)
    static let pomodoroAutoResumeAfterWake = Key<Bool>("pomodoroAutoResumeAfterWake", default: false)
    static let pomodoroPlaySound = Key<Bool>("pomodoroPlaySound", default: true)
    // Name of a built-in macOS system sound (NSSound(named:)) — no bundled asset.
    static let pomodoroSoundName = Key<String>("pomodoroSoundName", default: "Glass")
    static let pomodoroPostNotification = Key<Bool>("pomodoroPostNotification", default: true)
    static let pomodoroShowInMenuBar = Key<Bool>("pomodoroShowInMenuBar", default: false)
    static let pomodoroCalendarIcon = Key<Bool>("pomodoroCalendarIcon", default: true)
    // Names of user-authored Shortcuts run at focus start/end. macOS exposes no
    // public API for Do Not Disturb, so this is the only sandbox-safe hook.
    static let pomodoroFocusShortcutStart = Key<String>("pomodoroFocusShortcutStart", default: "")
    static let pomodoroFocusShortcutEnd = Key<String>("pomodoroFocusShortcutEnd", default: "")
    // Live session snapshot (PomodoroPersistedState JSON) so a relaunch resumes.
    static let pomodoroPersistedState = Key<Data?>("pomodoroPersistedState", default: nil)
    // Completed phases (PomodoroRecord JSON), trimmed on write.
    static let pomodoroHistory = Key<Data?>("pomodoroHistory", default: nil)

    // MARK: Calendar
    static let calendarSelectionState = Key<CalendarSelectionState>("calendarSelectionState", default: .all)
    static let hideAllDayEvents = Key<Bool>("hideAllDayEvents", default: false)
    static let showFullEventTitles = Key<Bool>("showFullEventTitles", default: false)
    static let autoScrollToNextEvent = Key<Bool>("autoScrollToNextEvent", default: true)
    static let openMeetingsInApp = Key<Bool>("openMeetingsInApp", default: true)
    
    // MARK: Fullscreen Media Detection
    static let hideNotchOption = Key<HideNotchOption>("hideNotchOption", default: .nowPlayingOnly)
    
    // MARK: Media Controller
    static let mediaController = Key<MediaControllerType>("mediaController", default: defaultMediaController)
    
    // MARK: Advanced Settings
    static let useCustomAccentColor = Key<Bool>("useCustomAccentColor", default: false)
    static let customAccentColorData = Key<Data?>("customAccentColorData", default: nil)
    // Show or hide the title bar
    static let hideTitleBar = Key<Bool>("hideTitleBar", default: true)
    
    // Helper to determine the default media controller based on NowPlaying deprecation status
    static var defaultMediaController: MediaControllerType {
        if MusicManager.shared.isNowPlayingDeprecated {
            return .appleMusic
        } else {
            return .nowPlaying
        }
    }

    static let didClearLegacyURLCacheV1 = Key<Bool>("didClearLegacyURLCache_v1", default: false)
}
