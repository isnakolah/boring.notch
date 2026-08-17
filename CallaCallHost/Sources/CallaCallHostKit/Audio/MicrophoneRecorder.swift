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

    private func buildEngineLocked() throws {
        // A fresh engine per session: reusing one leaves the input node silent
        // after the first stop/start cycle.
        let engine = AVAudioEngine()
        let input = engine.inputNode
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
        micLog.notice("microphone started at \(nativeFormat.sampleRate, privacy: .public)Hz x\(nativeFormat.channelCount, privacy: .public)")
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
