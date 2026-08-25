@preconcurrency import AVFoundation
import Foundation
import os.log

private let micLog = Logger(subsystem: "theboringteam.boringnotch.callhost", category: "microphone")

/// The `me` leg: microphone capture, converted to whisper format.
///
/// Buffers are delivered on a private serial queue, already 16 kHz mono Float32,
/// so the consumer never has to think about the device's native format.
public final class MicrophoneRecorder: @unchecked Sendable {
    /// Called on `queue` with converted samples.
    public var onSamples: (([Float]) -> Void)?
    /// Called on `queue` with a 0...1 meter level.
    public var onLevel: ((Float) -> Void)?

    private let queue = DispatchQueue(label: "callhost.microphone", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var converter: StreamingWhisperConverter?
    private var configObserver: NSObjectProtocol?
    private var running = false
    /// Rebuilding on our own device-bind echo would loop, so ignore
    /// configuration changes for a moment after starting.
    private var graceUntil = Date.distantPast

    public init() {}

    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default: return false
        }
    }

    public static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public func start() throws {
        try queue.sync { try startLocked() }
    }

    public func stop() {
        queue.sync {
            running = false
            if let configObserver {
                NotificationCenter.default.removeObserver(configObserver)
                self.configObserver = nil
            }
            teardownLocked()
        }
    }

    // MARK: - Internal

    private func startLocked() throws {
        guard !running else { return }
        guard Self.isAuthorized else { throw AudioError.permissionDenied }

        try buildEngineLocked()
        running = true
        graceUntil = Date().addingTimeInterval(0.75)

        // A device change (headphones in, Bluetooth profile switch) invalidates
        // the engine graph mid-call. Without this the tap goes silent and the
        // `me` leg simply stops, with no error anywhere.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.handleConfigurationChangeLocked() }
        }
    }

    /// Whether the OS is cancelling speaker bleed for us.
    ///
    /// Read after `start()`; false either because it was turned off or because
    /// the current device could not do it.
    public private(set) var voiceProcessingActive = false

    /// Apple's echo cancellation. **Off by default, and it should stay off.**
    ///
    /// `setVoiceProcessingEnabled` looks like an input-side setting and is not.
    /// It swaps the engine onto the Voice-Processing I/O audio unit, which is
    /// *duplex*: it takes over the output device as well, ducks everything the
    /// Mac is playing, and reshapes it for a phone call. Turning it on made the
    /// meeting itself nearly inaudible — the one sound the user actually needed
    /// — and left the microphone tap delivering nothing, so the call recorded
    /// zero turns.
    ///
    /// Nothing is lost by leaving it off. `EchoReference` is what the measured
    /// suppression comes from: it caught 67 of 69 echo utterances on a
    /// speaker-mode call and left 102% of a headset call's turns intact, and it
    /// did all of that on recorded audio that never had voice processing applied.
    /// This layer contributed nothing to any number and cost the user the call.
    public var voiceProcessingEnabled = false

    private func buildEngineLocked() throws {
        // A fresh engine per session: reusing one leaves the input node silent
        // after the first stop/start cycle.
        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Hardware echo cancellation, asked for before the format is read —
        // enabling it changes the input node's format, so reading first would
        // build the converter against a format that is about to be replaced.
        //
        // This removes the speakers from the microphone signal at the source,
        // which is the only place it can be removed cleanly. `EchoReference`
        // catches what survives; the two are layered on purpose, because voice
        // processing is unavailable on some devices and imperfect on the rest.
        voiceProcessingActive = false
        if voiceProcessingEnabled {
            micLog.notice("enabling voice processing — this also takes over audio output")
            do {
                try input.setVoiceProcessingEnabled(true)
                voiceProcessingActive = true
            } catch {
                // Not fatal, and not rare: some aggregate and virtual devices
                // refuse. The correlation layer still applies.
                micLog.notice(
                    "voice processing unavailable on this device: \(error.localizedDescription, privacy: .public)")
            }
        }

        let nativeFormat = input.inputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw AudioError.noInputDevice
        }

        // One converter for the whole session — resampling is stateful.
        let sessionConverter = StreamingWhisperConverter(inputFormat: nativeFormat)
        converter = sessionConverter

        input.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let level = AudioMeter.level(from: buffer)
            let converted: AVAudioPCMBuffer
            do {
                converted = try sessionConverter?.convert(buffer) ?? AudioConvert.toWhisperFormat(buffer)
            } catch {
                micLog.error("conversion failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            let samples = AudioConvert.samples(from: converted)
            self.queue.async {
                self.onLevel?(level)
                if !samples.isEmpty { self.onSamples?(samples) }
            }
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
        micLog.notice("microphone started at \(nativeFormat.sampleRate, privacy: .public)Hz x\(nativeFormat.channelCount, privacy: .public), echo cancellation \(self.voiceProcessingActive ? "on" : "off", privacy: .public)")
    }

    private func handleConfigurationChangeLocked() {
        guard running, Date() >= graceUntil else { return }
        micLog.notice("audio configuration changed; rebuilding engine")
        teardownLocked()
        do {
            try buildEngineLocked()
            graceUntil = Date().addingTimeInterval(0.75)
        } catch {
            micLog.error("engine rebuild failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func teardownLocked() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        converter = nil
    }
}
