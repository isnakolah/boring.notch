import Foundation

/// One finished call, read back off disk.
///
/// Everything here is already retained by `CallArchive` for every call the app
/// has ever recorded, which is what makes an offline accuracy sweep possible at
/// all: 66 calls of paired audio and transcript were sitting unused.
public struct EvaluatedCall: Sendable {
    public var id: String
    public var directory: URL
    public var meta: CallArchive.Meta?
    /// The live transcript — what the copilot actually reasoned over.
    public var live: [CallTurn]
    /// `transcript-archive.jsonl`, when a large-model pass has been run. Used as
    /// the silver reference for WER. Not ground truth, but a materially better
    /// model over the same audio.
    public var archived: [CallTurn]
    /// `transcript-replay.jsonl`, when this call's audio has been re-run through
    /// the current live pipeline. Present only for calls that were replayed.
    public var replayed: [CallTurn]
    public var suggestions: [ArchivedSuggestion]

    public init(
        id: String,
        directory: URL,
        meta: CallArchive.Meta?,
        live: [CallTurn],
        archived: [CallTurn],
        replayed: [CallTurn] = [],
        suggestions: [ArchivedSuggestion]
    ) {
        self.id = id
        self.directory = directory
        self.meta = meta
        self.live = live
        self.archived = archived
        self.replayed = replayed
        self.suggestions = suggestions
    }

    public var hasReference: Bool { !archived.isEmpty }

    /// What to score. A replay is the pipeline *as it is now*; the stored
    /// transcript is whatever shipped on the day the call happened. Preferring
    /// the replay is what makes `eval` answer "is this better" rather than "what
    /// did it used to do".
    public var scored: [CallTurn] { replayed.isEmpty ? live : replayed }
}

/// A suggestion as `suggestions.jsonl` stores it. Deliberately its own type
/// rather than `CopilotFrame.Suggestion`: this reads historical files that
/// predate fields the live type now requires.
public struct ArchivedSuggestion: Sendable {
    public var afterSeq: Int
    public var headline: String
    public var angles: [String]
    public var confirm: [String]
    public var latencyMs: Int

    private enum Keys: String, CodingKey {
        case afterSeq = "after_seq"
        case headline, angles, confirm
        case latencyMs = "latency_ms"
    }
}

extension ArchivedSuggestion: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        afterSeq = try container.decodeIfPresent(Int.self, forKey: .afterSeq) ?? 0
        headline = try container.decodeIfPresent(String.self, forKey: .headline) ?? ""
        angles = try container.decodeIfPresent([String].self, forKey: .angles) ?? []
        confirm = try container.decodeIfPresent([String].self, forKey: .confirm) ?? []
        latencyMs = try container.decodeIfPresent(Int.self, forKey: .latencyMs) ?? 0
    }
}

public enum CallCorpus {
    /// Every call directory under `root`, oldest first, skipping ones with no
    /// transcript at all.
    ///
    /// A directory that exists but holds nothing is not an error: the app creates
    /// it at `beginCall` and a run that died before its first turn leaves one
    /// behind. Four such directories exist on this machine.
    public static func load(root: URL) throws -> [EvaluatedCall] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        var calls: [EvaluatedCall] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            guard let call = loadCall(directory: entry), !call.live.isEmpty else { continue }
            calls.append(call)
        }
        return calls
    }

    public static func loadCall(directory: URL) -> EvaluatedCall? {
        let live = turns(at: directory.appendingPathComponent("transcript.jsonl"))
        let archived = turns(at: directory.appendingPathComponent("transcript-archive.jsonl"))
        let replayed = turns(at: directory.appendingPathComponent("transcript-replay.jsonl"))
        let suggestions: [ArchivedSuggestion] = lines(
            at: directory.appendingPathComponent("suggestions.jsonl"))
        let meta = (try? Data(contentsOf: directory.appendingPathComponent("meta.json")))
            .flatMap { try? JSONDecoder.callHostReading.decode(CallArchive.Meta.self, from: $0) }
        return EvaluatedCall(
            id: directory.lastPathComponent,
            directory: directory,
            meta: meta,
            live: live,
            archived: archived,
            replayed: replayed,
            suggestions: suggestions)
    }

    static func turns(at url: URL) -> [CallTurn] {
        lines(at: url).sorted { $0.seq < $1.seq }
    }

    /// Decodes a JSONL file, skipping lines that will not parse.
    ///
    /// Skipping rather than throwing is deliberate: these files are appended to
    /// live and a call killed mid-write leaves a truncated final line. Losing one
    /// turn of a 900-turn call must not cost the whole call's numbers.
    static func lines<T: Decodable>(at url: URL) -> [T] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder.callHostReading
        var result: [T] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let value = try? decoder.decode(T.self, from: data) else { continue }
            result.append(value)
        }
        return result
    }
}

extension JSONDecoder {
    /// Matches what `CallArchive` and `JSONEncoder.callHost` write.
    static var callHostReading: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
