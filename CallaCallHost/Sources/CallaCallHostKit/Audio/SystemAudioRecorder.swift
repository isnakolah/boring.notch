@preconcurrency import AVFoundation
import Foundation
import ScreenCaptureKit
import os.log

private let systemLog = Logger(subsystem: "theboringteam.boringnotch.callhost", category: "systemAudio")

/// The `them` leg: everything coming out of the speakers.
///
/// ScreenCaptureKit is the supported route to system audio on macOS 13+. It is a
/// screen-capture API, so it wants a video stream — we configure the smallest
/// legal one and ignore its frames. `excludesCurrentProcessAudio` keeps our own
/// output out of the mix.
///
/// This is why the capture host is a separate unsandboxed bundle: the Screen
/// Recording TCC grant attaches to the executable that actually captures, and it
/// cannot attach to an ad-hoc signature at all.
public final class SystemAudioRecorder: NSObject, @unchecked Sendable {
    /// Called on the sample queue with converted samples.
    public var onSamples: (([Float]) -> Void)?

    /// Private and **serial**. `.global()` is concurrent and reorders 10-20ms
    /// chunks under load, which garbles the mix audibly and the transcript
    /// invisibly.
    private let sampleQueue = DispatchQueue(label: "callhost.systemaudio", qos: .userInitiated)
    private var stream: SCStream?
    private var converter: StreamingWhisperConverter?
    private var running = false

    public override init() { super.init() }

    /// Probes the permission without raising a TCC prompt.
    public static func hasPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return !isPermissionError(error)
        }
    }

    /// `SCStreamErrorDomain` code -3801 is "user declined".
    public static func isPermissionError(_ error: Swift.Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && nsError.code == -3801
    }

    public func start() async throws {
        guard !running else { return }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw AudioError.noInputDevice }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        // ScreenCaptureKit requires a video stream even when only audio is
        // wanted; 2x2 at 1fps is the cheapest legal placeholder.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 5
        config.showsCursor = false
        config.capturesAudio = true
        config.sampleRate = Int(WhisperAudioFormat.sampleRate)
        config.channelCount = Int(WhisperAudioFormat.channelCount)
        config.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .utility))
        sampleQueue.sync { converter = nil }
        try await stream.startCapture()

        self.stream = stream
        running = true
        systemLog.notice("system audio capture started")
    }

    public func stop() async {
        guard let stream else { return }
        running = false
        self.stream = nil
        do {
            try await stream.stopCapture()
        } catch {
            systemLog.error("stopCapture failed: \(error.localizedDescription, privacy: .public)")
        }
        sampleQueue.sync { converter = nil }
    }
}

extension SystemAudioRecorder: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferIsValid(sampleBuffer) else { return }
        guard let buffer = sampleBuffer.toPCMBuffer() else { return }

        // Rebuild only when the format actually changes; the converter's filter
        // history has to survive across buffers.
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = StreamingWhisperConverter(inputFormat: buffer.format)
        }
        let converted: AVAudioPCMBuffer
        do {
            converted = try converter?.convert(buffer) ?? AudioConvert.toWhisperFormat(buffer)
        } catch {
            systemLog.error("conversion failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let samples = AudioConvert.samples(from: converted)
        if !samples.isEmpty { onSamples?(samples) }
    }
}

extension SystemAudioRecorder: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Swift.Error) {
        systemLog.error("stream stopped: \(error.localizedDescription, privacy: .public)")
        running = false
        self.stream = nil
    }
}

extension CMSampleBuffer {
    /// Copies a CoreMedia audio sample buffer into an `AVAudioPCMBuffer`.
    ///
    /// The copy is the point. `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer`
    /// does not move any audio: it points the buffer list's `mData` at memory
    /// owned by the block buffer it hands back. Filling an `AVAudioPCMBuffer`'s
    /// own list that way leaves the buffer aliasing that memory, and the block
    /// buffer is released as soon as it goes out of scope — so every sample is
    /// then read from freed memory, which comes back as silence. That is
    /// exactly what happened: `system.wav` was the right length, and every
    /// sample in it was zero, so the other side of every call transcribed to
    /// nothing and the copilot was never asked anything.
    ///
    /// The list is also sized from the format rather than from
    /// `MemoryLayout<AudioBufferList>.size`, which only ever covers one buffer
    /// and so cannot describe non-interleaved stereo.
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: streamDescription)
        else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frameCount > 0,
              let destination = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        destination.frameLength = frameCount

        // Ask how big the list needs to be for this buffer's channel layout.
        var listSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil) == noErr, listSize > 0
        else { return nil }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)

        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: listSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer) == noErr, blockBuffer != nil
        else { return nil }

        // Copied while the block buffer is still alive, into storage the
        // AVAudioPCMBuffer owns outright.
        return withExtendedLifetime(blockBuffer) { () -> AVAudioPCMBuffer? in
            let source = UnsafeMutableAudioBufferListPointer(list)
            let target = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
            guard source.count > 0, target.count > 0 else { return nil }
            for index in 0..<min(source.count, target.count) {
                guard let from = source[index].mData, let to = target[index].mData else { return nil }
                let byteCount = Int(min(source[index].mDataByteSize, target[index].mDataByteSize))
                memcpy(to, from, byteCount)
                target[index].mDataByteSize = UInt32(byteCount)
            }
            return destination
        }
    }
}
