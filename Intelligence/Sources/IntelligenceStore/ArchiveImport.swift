import Foundation

/// Brings calls recorded before the store existed into it.
///
/// Every call the host has ever archived lives in
/// `calls/<call-id>/{meta.json, transcript.jsonl, suggestions.jsonl}`. Those files
/// are still written, and are still what the re-transcription pass reads — this
/// only copies them in so History can be served from one place and so a past call
/// is searchable alongside everything else.
///
/// Nothing is deleted. The import is additive and idempotent: it is keyed on the
/// call id, the turn upsert is keyed on `(call_id, seq)`, and a marker row stops
/// it walking the directory again once it has finished. Re-running it after a
/// crash costs a directory scan and changes nothing else.
///
/// The on-disk shapes are decoded structurally rather than by importing the
/// host's own types. This target deliberately does not depend on
/// `CallaCallHostKit` — the engine links it too, and the engine has no business
/// pulling in whisper.
enum ArchiveImport {
    /// Bumped if the importer ever needs to run again over already-imported calls.
    static let marker = "archive_import_v1"

    /// `meta.json`, written by `CallArchive` when a call ends cleanly.
    ///
    /// In practice most calls do not have one: the host is stopped with a signal,
    /// and a call that was killed, crashed, or is still running never gets here.
    /// On the machine this was first run against, none of forty-four archived
    /// calls had a `meta.json` and thirty-seven had a `call.json` — so treating
    /// `meta.json` as required imported nothing at all.
    struct Meta: Decodable {
        var callID: String
        var persona: String
        var startedAt: Date
        var endedAt: Date?
        var liveModel: String
        var turnCount: Int

        enum CodingKeys: String, CodingKey {
            case callID = "call_id"
            case persona
            case startedAt = "started_at"
            case endedAt = "ended_at"
            case liveModel = "live_model"
            case turnCount = "turn_count"
        }
    }

    /// `call.json` — the `ActiveCallStatus` shape, written once when the call
    /// starts and left behind whatever happens to the host afterwards.
    ///
    /// Its `turn_count` is always the value at start, which is zero. That is fine:
    /// the store recomputes the count from the rows actually inserted.
    struct StartRecord: Decodable {
        var callID: String
        var persona: String
        var startedAt: Date

        enum CodingKeys: String, CodingKey {
            case callID = "call_id"
            case persona
            case startedAt = "started_at"
        }
    }

    struct Turn: Decodable {
        var seq: Int
        var source: String
        var t0: Double
        var t1: Double
        var text: String
    }

    struct Suggestion: Decodable {
        var afterSeq: Int
        var headline: String
        var angles: [String]?
        var confirm: [String]?
        var summary: String?
        var openQuestions: [String]?
        var latencyMs: Int?

        enum CodingKeys: String, CodingKey {
            case headline, angles, confirm, summary
            case afterSeq = "after_seq"
            case openQuestions = "open_questions"
            case latencyMs = "latency_ms"
        }
    }

    /// The host writes ISO-8601 in every file it owns.
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// One call's directory, decoded.
    ///
    /// `meta.json` first, `call.json` second, and nothing at all is not a reason
    /// to give up: a directory with a readable transcript is a call that happened,
    /// and the file's own timestamps say when. Returns nil only when there is no
    /// transcript to import.
    static func read(directory: URL) -> (meta: Meta, turns: [Turn], suggestions: [Suggestion])? {
        let decoder = decoder
        let transcript = directory.appendingPathComponent("transcript.jsonl")
        let turns = lines(of: transcript).compactMap { try? decoder.decode(Turn.self, from: $0) }
        guard !turns.isEmpty else { return nil }

        let suggestions = lines(of: directory.appendingPathComponent("suggestions.jsonl"))
            .compactMap { try? decoder.decode(Suggestion.self, from: $0) }

        if let data = try? Data(contentsOf: directory.appendingPathComponent("meta.json")),
           var meta = try? decoder.decode(Meta.self, from: data) {
            meta.turnCount = turns.count
            return (meta, turns, suggestions)
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: transcript.path)
        let modified = attributes?[.modificationDate] as? Date
        let created = attributes?[.creationDate] as? Date

        if let data = try? Data(contentsOf: directory.appendingPathComponent("call.json")),
           let start = try? decoder.decode(StartRecord.self, from: data) {
            return (Meta(
                callID: start.callID,
                persona: start.persona,
                startedAt: start.startedAt,
                // The transcript stopped being written when the call stopped, so
                // its mtime is the best end time anyone has. Named as an estimate
                // rather than pretended to be exact.
                endedAt: modified,
                liveModel: "",
                turnCount: turns.count), turns, suggestions)
        }

        // Nothing but a transcript. The directory name is the call id — that is
        // how the host laid it out — and the file's timestamps are the rest.
        guard let created else { return nil }
        return (Meta(
            callID: directory.lastPathComponent,
            persona: "generic",
            startedAt: created,
            endedAt: modified,
            liveModel: "",
            turnCount: turns.count), turns, suggestions)
    }

    /// A malformed line is skipped rather than failing the file.
    ///
    /// These are append-only logs written by a process that can be SIGINTed
    /// mid-write, so a truncated last line is an expected state, not corruption.
    private static func lines(of url: URL) -> [Data] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { Data($0.utf8) }
    }
}

public extension CallaStore {
    /// Copies every archived call on disk into the store, once.
    ///
    /// - Parameter callsDirectory: the host's `calls/` directory.
    /// - Returns: how many calls were imported. Zero on a second run.
    ///
    /// Deliberately not called from a call's hot path. The engine runs it in the
    /// background at startup: it walks a directory and parses every transcript
    /// this Mac has ever recorded, which is fine once and wrong to do while
    /// someone is talking.
    @discardableResult
    func importArchives(from callsDirectory: URL) async -> Int {
        guard !hasImportedArchives() else { return 0 }

        let directories = (try? FileManager.default.contentsOfDirectory(
            at: callsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []

        var imported = 0
        for directory in directories {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let archive = ArchiveImport.read(directory: directory)
            else { continue }
            // A call already in the store is skipped whole. Its rows came either
            // from a live run or from an earlier partial import, and both are
            // better sources than a re-parse.
            if (try? call(id: archive.meta.callID)) ?? nil != nil { continue }

            do {
                try beginCall(CallRecord(
                    id: archive.meta.callID,
                    persona: archive.meta.persona,
                    startedAt: archive.meta.startedAt,
                    endedAt: archive.meta.endedAt,
                    liveModel: archive.meta.liveModel.isEmpty ? nil : archive.meta.liveModel,
                    turnCount: archive.meta.turnCount))
                for turn in archive.turns {
                    try record(
                        turn: StoredTurn(
                            seq: turn.seq, source: turn.source,
                            t0: turn.t0, t1: turn.t1, text: turn.text),
                        callID: archive.meta.callID)
                }
                for suggestion in archive.suggestions {
                    try record(
                        suggestion: StoredSuggestion(
                            afterSeq: suggestion.afterSeq,
                            headline: suggestion.headline,
                            angles: suggestion.angles ?? [],
                            confirm: suggestion.confirm ?? [],
                            summary: suggestion.summary,
                            openQuestions: suggestion.openQuestions ?? [],
                            latencyMs: suggestion.latencyMs ?? 0,
                            // No per-suggestion timestamp was ever written, so the
                            // call's own start is the honest answer. Ordering within
                            // a call comes from `after_seq`, not from this.
                            at: archive.meta.startedAt),
                        callID: archive.meta.callID)
                }
                if let endedAt = archive.meta.endedAt {
                    try endCall(id: archive.meta.callID, at: endedAt)
                }
                imported += 1
            } catch {
                // One unreadable call must not stop the other two hundred. The
                // marker is still written at the end, because a call that failed
                // to parse will fail again on the next launch.
                continue
            }
        }

        markArchivesImported()
        return imported
    }

    func hasImportedArchives() -> Bool {
        let value = try? query(
            "SELECT value FROM store_meta WHERE key = ?",
            [.text(ArchiveImport.marker)]) { $0.string(0) }
        return value?.isEmpty == false
    }

    private func markArchivesImported() {
        try? run(
            "INSERT INTO store_meta(key, value) VALUES(?, 'done') " +
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(ArchiveImport.marker)])
    }
}
