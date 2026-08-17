import AVFoundation
import Foundation
import os.log

private let archiveLog = Logger(subsystem: "theboringteam.boringnotch.callhost", category: "archive")

/// On-disk record of one call.
///
/// Layout under `<root>/<call-id>/`:
///   `mic.wav`            the `me` leg, 16 kHz mono float
///   `system.wav`         the `them` leg, same format
///   `transcript.jsonl`   one `CallTurn` per line, in seq order
///   `suggestions.jsonl`  one gateway suggestion per line
///   `meta.json`          call id, persona, start/end, model, counts
///
/// The two legs stay in separate files for the same reason they stay separate
/// in memory: mixing them down would throw away the `me`/`them` labelling that
/// the whole feature rests on, and would make a later re-transcribe unable to
/// recover it.
public final class CallArchive: @unchecked Sendable {
    public struct Meta: Codable, Sendable {
        public var callID: String
        public var persona: String
        public var startedAt: Date
        public var endedAt: Date?
        public var liveModel: String
        public var turnCount: Int
        public var droppedSelfTurns: Int

        enum CodingKeys: String, CodingKey {
            case callID = "call_id"
            case persona
            case startedAt = "started_at"
            case endedAt = "ended_at"
            case liveModel = "live_model"
            case turnCount = "turn_count"
            case droppedSelfTurns = "dropped_self_turns"
        }
    }

    public let directory: URL

    private let queue = DispatchQueue(label: "callhost.archive", qos: .utility)
    private var writers: [TurnSource: AVAudioFile] = [:]
    private let encoder: JSONEncoder

    public init(root: URL, callID: String) throws {
        directory = root.appendingPathComponent(callID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
    }

    public func url(for source: TurnSource) -> URL {
        directory.appendingPathComponent(source == .me ? "mic.wav" : "system.wav")
    }

    /// Appends captured samples to a leg's WAV.
    ///
    /// Never throws upward: losing the archive must not take down a live call.
    public func append(samples: [Float], source: TurnSource) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let file = try self.writer(for: source)
                let format = WhisperAudioFormat.pcmFloat32
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(samples.count)) else { return }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                if let channel = buffer.floatChannelData?[0] {
                    samples.withUnsafeBufferPointer { source in
                        if let base = source.baseAddress {
                            channel.update(from: base, count: samples.count)
                        }
                    }
                }
                try file.write(from: buffer)
            } catch {
                archiveLog.error("wav append failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func record(turn: CallTurn) {
        appendLine(turn, to: "transcript.jsonl")
    }

    public func record(suggestionLine: String) {
        queue.async { [weak self] in
            self?.write(line: suggestionLine, to: "suggestions.jsonl")
        }
    }

    public func write(meta: Meta) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let data = try self.encoder.encode(meta)
                try data.write(to: self.directory.appendingPathComponent("meta.json"), options: .atomic)
            } catch {
                archiveLog.error("meta write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Flushes and closes the WAV files. Call once at end of call.
    public func close() {
        queue.sync {
            // AVAudioFile finalizes its header on deinit, so dropping the
            // references here is what makes the WAVs playable.
            writers.removeAll()
        }
    }

    // MARK: - Internal

    private func writer(for source: TurnSource) throws -> AVAudioFile {
        if let existing = writers[source] { return existing }
        let format = WhisperAudioFormat.pcmFloat32
        let file = try AVAudioFile(
            forWriting: url(for: source),
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false)
        writers[source] = file
        return file
    }

    private func appendLine<T: Encodable>(_ value: T, to name: String) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let data = try self.encoder.encode(value)
                guard let line = String(data: data, encoding: .utf8) else { return }
                self.write(line: line, to: name)
            } catch {
                archiveLog.error("encode failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Must be called on `queue`.
    private func write(line: String, to name: String) {
        let url = directory.appendingPathComponent(name)
        guard let data = (line + "\n").data(using: .utf8) else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        } catch {
            archiveLog.error("append to \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
