import AppKit
import Combine
import CoreAudio
import Defaults
import Foundation

/// Notices that a meeting has started, so the copilot does not depend on the
/// user remembering to press a button before one.
///
/// Two signals, both required. The microphone being *in use somewhere on the
/// system* is the honest one: it fires for Zoom, Teams, Meet in a browser, Slack
/// huddles and anything else, without asking for a permission of its own. On its
/// own it also fires for Siri, Voice Memos and a dictation shortcut, so it is
/// paired with "a conferencing-capable app is running" and a dwell time. Getting
/// this wrong in the eager direction means the notch opens over your work for no
/// reason, so the bar is deliberately on the high side.
@MainActor
final class MeetingDetector: ObservableObject {
    static let shared = MeetingDetector()

    /// Mic has been live long enough, with a plausible app running, to call it
    /// a meeting.
    @Published private(set) var inMeeting = false
    /// Raw signals, surfaced in settings so the detector can be understood
    /// rather than guessed at.
    @Published private(set) var microphoneInUse = false
    @Published private(set) var meetingAppRunning = false
    /// Something is coming out of the speakers at the same time. Together with
    /// a live microphone that is a two-way conversation, which is what makes
    /// this a usable fallback when the app is not one this build has heard of.
    @Published private(set) var speakerActive = false

    /// Apps that can plausibly host a call. Browsers are here because Meet has
    /// no bundle of its own; they are almost always running, which is fine —
    /// the microphone is doing the real work and this only rules out the
    /// obviously-not-a-call case.
    ///
    /// A fixed list is brittle by nature: the first machine this ran on used
    /// Zen and WhatsApp, and neither was on it. Hence `speakerActive` below —
    /// the list is a fast path, not the only way in.
    private static let meetingBundleIDs: Set<String> = [
        // Conferencing
        "us.zoom.xos",
        "com.microsoft.teams", "com.microsoft.teams2",
        "Cisco-Systems.Spark", "com.cisco.webexmeetingsapp", "com.webex.meetingmanager",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.apple.FaceTime",
        "us.zoom.ZoomClips",
        "com.ringcentral.glip",
        "com.gotomeeting.GoToMeeting",
        // Messaging that also carries voice and video calls
        "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram", "org.telegram.desktop",
        "org.whispersystems.signal-desktop",
        "com.skype.skype",
        "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan", // Meet PWA
        // Browsers — Meet, Whereby, Around and everything else web-based
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "com.brave.Browser", "com.brave.Browser.beta",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "app.zen-browser.zen",
        "company.thebrowser.Browser", "company.thebrowser.dia",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "com.operasoftware.OperaGX",
        "com.kagi.kagimacOS",
        "org.chromium.Chromium",
    ]

    /// How long the mic must stay live before this counts as a meeting.
    private let startDwell: Duration = .seconds(4)
    /// How long it must stay quiet before the meeting is over. Longer than the
    /// start dwell because a mute button is not the end of a call.
    private let endDwell: Duration = .seconds(8)

    private var deviceID: AudioDeviceID = kAudioObjectUnknown
    private var outputDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var outputListener: AudioObjectPropertyListenerBlock?
    /// Held because removal matches on block identity: passing a fresh closure
    /// to `AudioObjectRemovePropertyListenerBlock` removes nothing, and the old
    /// listener keeps firing against a device that is no longer the default.
    private var runningListener: AudioObjectPropertyListenerBlock?
    private var transitionTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []

    /// Set when the user ends a call by hand while the mic is still live, so
    /// the detector does not immediately start it again. Cleared the next time
    /// the mic goes quiet.
    private var suppressedUntilMicIdle = false

    private init() {}

    func start() {
        refreshMeetingApps()
        attachDefaultDeviceListener()
        attachDeviceListener()
        attachOutputListener()
        readMicrophoneState()
        readSpeakerState()

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshMeetingApps() }
            })
        }

        // Ending a call by hand mid-meeting has to stick, or the detector
        // undoes the decision within four seconds.
        CallaEngineClient.shared.$status
            .map(\.copilot.running)
            .removeDuplicates()
            .sink { [weak self] running in
                guard let self else { return }
                if !running, self.microphoneInUse { self.suppressedUntilMicIdle = true }
            }
            .store(in: &cancellables)
    }

    /// Called by the copilot when the user ends a call themselves.
    func suppressUntilMicIdle() {
        suppressedUntilMicIdle = true
    }

    // MARK: - Signals

    private func refreshMeetingApps() {
        let running = NSWorkspace.shared.runningApplications
            .compactMap(\.bundleIdentifier)
        meetingAppRunning = running.contains { Self.meetingBundleIDs.contains($0) }
        evaluate()
    }

    private func readMicrophoneState() {
        guard deviceID != kAudioObjectUnknown else {
            microphoneInUse = false
            evaluate()
            return
        }
        var address = Self.runningSomewhereAddress
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running)
        microphoneInUse = status == noErr && running != 0
        if !microphoneInUse { suppressedUntilMicIdle = false }
        evaluate()
    }

    private func readSpeakerState() {
        guard outputDeviceID != kAudioObjectUnknown else {
            speakerActive = false
            evaluate()
            return
        }
        var address = Self.runningSomewhereAddress
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(outputDeviceID, &address, 0, nil, &size, &running)
        speakerActive = status == noErr && running != 0
        evaluate()
    }

    /// Decides the meeting state, with a dwell in each direction.
    ///
    /// The dwell is what separates a call from a notification chime, so the
    /// task is restarted whenever the target state changes rather than letting
    /// a stale timer land.
    ///
    /// A live microphone alone is not a meeting — dictation and voice memos
    /// look identical. It becomes one when something else corroborates it:
    /// either a known conferencing app is running, or the speakers are live at
    /// the same time, which is what a two-way conversation looks like from
    /// outside. Music plus dictation can satisfy the second one; the dwell and
    /// the fact that starting a copilot is cheap and reversible make that an
    /// acceptable trade against missing the call entirely.
    private func evaluate() {
        let corroborated = meetingAppRunning || speakerActive
        let wanted = microphoneInUse && corroborated && !suppressedUntilMicIdle
        guard wanted != inMeeting else {
            transitionTask?.cancel()
            transitionTask = nil
            return
        }

        let dwell = wanted ? startDwell : endDwell
        transitionTask?.cancel()
        transitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: dwell)
            guard !Task.isCancelled, let self else { return }
            let stillWanted = self.microphoneInUse
                && (self.meetingAppRunning || self.speakerActive)
                && !self.suppressedUntilMicIdle
            guard stillWanted == wanted, self.inMeeting != wanted else { return }
            self.inMeeting = wanted
            self.applyToCopilot(started: wanted)
        }
    }

    private func applyToCopilot(started: Bool) {
        guard Defaults[.callaCopilotEnabled], Defaults[.callaCopilotAutoStartOnMeeting] else { return }
        let engine = CallaEngineClient.shared
        guard engine.status.copilot.available else { return }

        if started {
            guard !engine.status.copilot.running else { return }
            engine.startCall(persona: Defaults[.callaCopilotPersona],
                             model: Defaults[.callaCopilotLiveModel])
        } else {
            guard engine.status.copilot.running else { return }
            engine.endCall()
        }
    }

    // MARK: - CoreAudio plumbing

    private func attachDeviceListener() {
        detachDeviceListener()
        deviceID = Self.defaultInputDevice()
        guard deviceID != kAudioObjectUnknown else { return }

        var address = Self.runningSomewhereAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.readMicrophoneState() }
        }
        if AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener) == noErr {
            runningListener = listener
        }
    }

    private func detachDeviceListener() {
        guard let listener = runningListener, deviceID != kAudioObjectUnknown else { return }
        var address = Self.runningSomewhereAddress
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener)
        runningListener = nil
    }

    private static var runningSomewhereAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func attachOutputListener() {
        if let outputListener, outputDeviceID != kAudioObjectUnknown {
            var old = Self.runningSomewhereAddress
            AudioObjectRemovePropertyListenerBlock(outputDeviceID, &old, DispatchQueue.main, outputListener)
        }
        outputListener = nil
        outputDeviceID = Self.defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
        guard outputDeviceID != kAudioObjectUnknown else { return }

        var address = Self.runningSomewhereAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.readSpeakerState() }
        }
        if AudioObjectAddPropertyListenerBlock(outputDeviceID, &address, DispatchQueue.main, listener) == noErr {
            outputListener = listener
        }
    }

    /// Plugging in a headset changes the default device, and the old one stops
    /// reporting. Without this the detector goes deaf mid-day.
    private func attachDefaultDeviceListener() {
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
            ) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.attachDeviceListener()
                    self.attachOutputListener()
                    self.readMicrophoneState()
                    self.readSpeakerState()
                }
            }
        }
    }

    private static func defaultInputDevice() -> AudioDeviceID {
        defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    private static func defaultDevice(selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : kAudioObjectUnknown
    }
}
