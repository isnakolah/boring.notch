@preconcurrency import AVFoundation
import Accelerate
import Foundation

/// `AVAudioConverter` types its input block `@Sendable`, but calls it
/// synchronously on the calling thread before `convert` returns. A reference box
/// carries the "already fed this buffer" flag without a captured `var`, so the
/// invariant is expressed in the type rather than argued for in a comment.
private final class ConverterFeed: @unchecked Sendable {
    var fed = false
}

public extension WhisperAudioFormat {
    static var pcmFloat32: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false)!
    }
}

public enum AudioConvert {
    /// One-shot conversion to 16 kHz mono Float32.
    ///
    /// For a live tap use `StreamingWhisperConverter` instead — this flushes the
    /// resampler, which is exactly wrong across buffer boundaries.
    public static func toWhisperFormat(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let target = WhisperAudioFormat.pcmFloat32
        if buffer.format.sampleRate == target.sampleRate,
           buffer.format.channelCount == target.channelCount,
           buffer.format.commonFormat == .pcmFormatFloat32 {
            return buffer
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: target) else {
            throw AudioError.converterUnavailable
        }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw AudioError.bufferAllocationFailed
        }

        var error: NSError?
        let feed = ConverterFeed()
        let status = converter.convert(to: output, error: &error) { [buffer] _, statusPointer in
            if feed.fed {
                statusPointer.pointee = .endOfStream
                return nil
            }
            statusPointer.pointee = .haveData
            feed.fed = true
            return buffer
        }
        if let error { throw error }
        if status == .error { throw AudioError.conversionFailed }
        return output
    }

    public static func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    /// Reads any audio file the system can decode and returns whisper-shaped
    /// samples. Used by the offline transcribe path and the archive re-run.
    public static func loadAsWhisperSamples(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
        else { return [] }
        try file.read(into: input)
        return samples(from: try toWhisperFormat(input))
    }
}

public enum AudioError: Swift.Error, LocalizedError {
    case converterUnavailable
    case bufferAllocationFailed
    case conversionFailed
    case noInputDevice
    case permissionDenied

    public var errorDescription: String? {
        switch self {
        case .converterUnavailable: return "Could not build an audio converter for this device format"
        case .bufferAllocationFailed: return "Could not allocate an audio buffer"
        case .conversionFailed: return "Audio conversion failed"
        case .noInputDevice: return "No usable audio input device"
        case .permissionDenied: return "Audio capture permission was denied"
        }
    }
}

/// Stateful streaming resampler for a capture session.
///
/// Sample-rate conversion carries filter history across buffers. Building a
/// fresh `AVAudioConverter` per tap buffer — which is what the one-shot helper
/// does — zero-pads that history and independently rounds the fractional frame
/// ratio (48k to 16k is 1365 1/3 frames per 4096), leaving a waveform
/// discontinuity at every buffer boundary of every recording made on a
/// non-16kHz device. One instance per session keeps the filter warm; the only
/// cost is a sub-millisecond unflushed tail at stream end.
///
/// Not thread-safe: feed it from one serial context — the AVAudioEngine tap or
/// the ScreenCaptureKit sample queue.
public final class StreamingWhisperConverter {
    /// nil when the input is already whisper-shaped (pass-through).
    private let converter: AVAudioConverter?
    public let inputFormat: AVAudioFormat

    public init?(inputFormat: AVAudioFormat) {
        self.inputFormat = inputFormat
        let target = WhisperAudioFormat.pcmFloat32
        if inputFormat.sampleRate == target.sampleRate,
           inputFormat.channelCount == target.channelCount,
           inputFormat.commonFormat == .pcmFormatFloat32 {
            converter = nil
        } else if let built = AVAudioConverter(from: inputFormat, to: target) {
            converter = built
        } else {
            return nil
        }
    }

    /// Converts one buffer, retaining resampler state for the next call.
    ///
    /// Pass-through inputs return the *same* buffer instance; a caller that
    /// mutates the result in place must copy first.
    public func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let converter else { return buffer }
        let target = WhisperAudioFormat.pcmFloat32
        let ratio = target.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw AudioError.bufferAllocationFailed
        }

        var error: NSError?
        let feed = ConverterFeed()
        let status = converter.convert(to: output, error: &error) { [buffer] _, statusPointer in
            if feed.fed {
                // `.noDataNow`, not `.endOfStream`: the filter history must stay
                // alive for the next buffer. Flushing here is the per-chunk
                // restart this class exists to avoid.
                statusPointer.pointee = .noDataNow
                return nil
            }
            statusPointer.pointee = .haveData
            feed.fed = true
            return buffer
        }
        if let error { throw error }
        if status == .error { throw AudioError.conversionFailed }
        return output
    }
}

public enum AudioSignal {
    /// True when a buffer carries no signal at all.
    ///
    /// The strictest possible test, and deliberately not a "too quiet to be
    /// speech" gate — a quiet real utterance is still worth transcribing. This
    /// answers only "did capture produce anything?", which is safe even for a
    /// 300ms clip: a live microphone in a silent room still delivers dither,
    /// never a run of exact zeros.
    public static func isSilent(_ samples: [Float]) -> Bool {
        !samples.contains { $0 != 0 }
    }

    public static func peak(_ samples: [Float]) -> Float {
        var peak: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
        }
        return peak
    }
}

/// 0...1 RMS level for a meter.
public enum AudioMeter {
    public static func level(from buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(data[0], 1, &rms, vDSP_Length(buffer.frameLength))
        let power = 20 * log10(max(rms, 0.000_001))
        return min(1, max(0, (power + 60) / 60))
    }
}
