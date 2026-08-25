import Foundation

/// What one call scored.
///
/// Every field is a number a change to the pipeline should move in a known
/// direction, so a regression is visible without listening to anything.
public struct CallScore: Sendable, Codable {
    public var callID: String
    /// True when these numbers describe a re-run through the current pipeline
    /// rather than the transcript the call originally produced.
    public var isReplay: Bool
    public var turns: Int
    public var durationSeconds: Double

    // ASR quality, against the large-model archive pass as a silver reference.
    public var werMe: Double?
    public var werThem: Double?
    public var cerOverall: Double?

    // Echo: the microphone hearing the speakers and being transcribed as the user.
    public var meTurns: Int
    public var echoOverlappingTurns: Int
    public var echoExactDuplicates: Int
    /// Surviving echo turns as a share of the microphone turns that remain.
    ///
    /// Useful for spotting a call that is *mostly* bleed; useless for measuring
    /// suppression, because suppression shrinks the denominator too. Judge
    /// suppression by `echoSurvivorsPerMinute` and `meTurnsPerMinute` together.
    public var echoLeakRate: Double
    /// Echo turns that reached the transcript, per minute of call. Falls when
    /// suppression improves, regardless of what happens to the turn count.
    public var echoSurvivorsPerMinute: Double
    /// Microphone turns per minute. Diagnostic only — see `micCoverage` for the
    /// over-suppression guard, and why this cannot be one.
    public var meTurnsPerMinute: Double
    /// Microphone words kept, against the archive reference, counted only in
    /// windows where the remote leg was silent.
    ///
    /// This is the honest over-suppression guard. Raw microphone turns per minute
    /// is not: on a call taken through the speakers almost every microphone turn
    /// *is* echo, so the correct outcome is near-zero and a floor on it fails a
    /// working detector. Measured on this corpus, mic turns/min fell from 1.67 to
    /// 0.52 — which looked alarming and was almost entirely correct suppression,
    /// while headset calls kept 92% of their turns.
    ///
    /// Restricting to remote-silent windows removes the ambiguity: nothing was
    /// coming out of the speakers, so anything the microphone heard was the user,
    /// and anything missing was lost. Nil when the call has no such windows.
    public var micCoverage: Double?

    // Segmentation health.
    public var turnsPerMinute: Double
    public var meanWordsPerTurn: Double
    public var shortTurnRate: Double

    // Whisper writing things nobody said.
    public var artifactTurns: Int

    // Suggestion quality.
    public var suggestions: Int
    public var distinctHeadlines: Int
    public var repeatRate: Double
    public var ungroundedSuggestions: Int
    public var ungroundedRate: Double
    public var unsupportedTokens: [String]
}

public enum CallEvaluator {
    /// Two turns are "the same moment" within this many seconds. The legs
    /// endpoint independently, so an echo pair never shares an exact timestamp.
    static let overlapWindow: Double = 2.0
    /// A turn at or below this many words is a fragment, not a statement.
    static let shortTurnWords = 3

    public static func score(_ call: EvaluatedCall, evidence: ClaimGuard.Evidence) -> CallScore {
        // Whatever this call's transcript is *today*: a replay when one exists,
        // otherwise the one that shipped.
        let live = call.scored
        let me = live.filter { $0.source == .me }
        let them = live.filter { $0.source == .them }
        let duration = (live.map(\.t1).max() ?? 0) - (live.map(\.t0).min() ?? 0)

        // MARK: Echo
        //
        // Counted on the *live* transcript because that is what the copilot saw.
        // An echo turn is a `me` turn sitting on top of a `them` turn: the same
        // sound reaching the microphone a few hundred milliseconds after it left
        // the speakers.
        var overlapping = 0
        var exactDuplicates = 0
        for turn in me {
            let twins = them.filter { abs($0.t0 - turn.t0) <= overlapWindow }
            if !twins.isEmpty { overlapping += 1 }
            let key = TextMetrics.normalize(turn.text).joined(separator: " ")
            if !key.isEmpty,
               twins.contains(where: { TextMetrics.normalize($0.text).joined(separator: " ") == key }) {
                exactDuplicates += 1
            }
        }

        // MARK: Segmentation
        let wordCounts = live.map { TextMetrics.normalize($0.text).count }
        let shortTurns = wordCounts.filter { $0 <= shortTurnWords }.count
        let minutes = max(duration / 60, 1.0 / 60)

        // MARK: Artifacts
        //
        // `[BLANK_AUDIO]`, `(coughing)`, `(upbeat music)` — whisper's non-speech
        // annotations, which reach the transcript as if someone had said them.
        let artifacts = live.filter { isArtifact($0.text) }.count

        // MARK: Grounding
        //
        // The evidence grows as the call proceeds: a claim is grounded if it was
        // supported by the knowledge base, the profile, or anything the user had
        // already said *by that point*. Scoring against the whole call would let
        // a suggestion be justified by a sentence spoken ten minutes later.
        var running = evidence
        var seqCursor = 0
        var ungrounded = 0
        var unsupported: [String] = []
        for suggestion in call.suggestions.sorted(by: { $0.afterSeq < $1.afterSeq }) {
            while seqCursor < live.count, live[seqCursor].seq <= suggestion.afterSeq {
                if live[seqCursor].source == .me {
                    running.add(live[seqCursor].text)
                } else {
                    running.addHeardNames(live[seqCursor].text)
                }
                seqCursor += 1
            }
            guard !suggestion.headline.isEmpty else { continue }
            let verdict = ClaimGuard.check(
                headline: suggestion.headline, angles: suggestion.angles, against: running)
            guard !verdict.isGrounded else { continue }
            ungrounded += 1
            for token in verdict.unsupported where !unsupported.contains(token) {
                unsupported.append(token)
            }
        }

        let headlines = call.suggestions.map(\.headline).filter { !$0.isEmpty }
        let distinct = Set(headlines).count
        let scored = headlines.count

        return CallScore(
            callID: call.id,
            isReplay: !call.replayed.isEmpty,
            turns: live.count,
            durationSeconds: duration,
            // Scored only where the remote leg was silent, so the reference
            // describes the user rather than the user plus the speakers.
            werMe: wer(
                live: me,
                archived: call.archived.filter { $0.source == .me },
                excludingWindowsFrom: call.archived.filter { $0.source == .them }),
            werThem: wer(live: them, archived: call.archived.filter { $0.source == .them }),
            // Character error rate is the same quadratic trap over a whole call,
            // and word error rate already answers the question. Kept nil rather
            // than removed so the field stays in the JSON schema for a future
            // windowed implementation.
            cerOverall: nil,
            meTurns: me.count,
            echoOverlappingTurns: overlapping,
            echoExactDuplicates: exactDuplicates,
            echoLeakRate: me.isEmpty ? 0 : Double(overlapping) / Double(me.count),
            echoSurvivorsPerMinute: Double(overlapping) / minutes,
            meTurnsPerMinute: Double(me.count) / minutes,
            micCoverage: coverage(
                live: me,
                archived: call.archived.filter { $0.source == .me },
                excludingWindowsFrom: call.archived.filter { $0.source == .them }),
            turnsPerMinute: Double(live.count) / minutes,
            meanWordsPerTurn: wordCounts.isEmpty
                ? 0 : Double(wordCounts.reduce(0, +)) / Double(wordCounts.count),
            shortTurnRate: live.isEmpty ? 0 : Double(shortTurns) / Double(live.count),
            artifactTurns: artifacts,
            suggestions: call.suggestions.count,
            distinctHeadlines: distinct,
            repeatRate: scored == 0 ? 0 : 1 - Double(distinct) / Double(scored),
            ungroundedSuggestions: ungrounded,
            ungroundedRate: scored == 0 ? 0 : Double(ungrounded) / Double(scored),
            unsupportedTokens: Array(unsupported.prefix(20)))
    }

    /// A turn that is entirely a bracketed annotation. Checked on the raw text
    /// rather than the normalised form, because normalising strips the brackets
    /// that are the whole signal.
    public static func isArtifact(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, let last = trimmed.last else { return false }
        let pairs: [(Character, Character)] = [("[", "]"), ("(", ")"), ("*", "*"), ("♪", "♪")]
        return pairs.contains { first == $0.0 && last == $0.1 && trimmed.count > 1 }
    }

    /// Word error rate computed in time-aligned windows rather than over the
    /// whole leg at once.
    ///
    /// Two reasons, and both matter. Levenshtein is O(n·m): the longest call here
    /// is ~30,000 words per leg, which is nine hundred million cell updates for
    /// one number — the sweep did not finish. And a single early insertion in an
    /// hour-long transcript drags the whole alignment out of step, so the score
    /// stops describing the transcription and starts describing the drift.
    ///
    /// Both transcripts carry real timestamps against the same call clock, so
    /// bucketing by time is a free and honest alignment. Errors and reference
    /// lengths are summed across buckets, which is the standard corpus-level WER
    /// — not an average of per-bucket rates, which would let a two-word bucket
    /// weigh as much as a two-hundred-word one.
    static let werWindowSeconds: Double = 30

    /// `excludingWindowsFrom`: windows in which these turns occur are skipped.
    ///
    /// Used to score the microphone leg only where the other party was silent.
    /// The archive reference is a large model over `mic.wav`, which contains the
    /// speaker bleed as well as the user — so a pipeline that correctly removes
    /// the bleed scores as if it had failed to transcribe it. Measured on one
    /// speaker-mode call: suppressing 67 of 69 echo utterances moved the naive
    /// microphone WER from 24% to 98%. The pipeline got better and the number got
    /// worse, which means the number was wrong.
    ///
    /// Restricting to windows where the remote leg said nothing gives a stretch
    /// of microphone audio that can only be the user, where the reference is
    /// trustworthy again.
    static func wer(
        live: [CallTurn],
        archived: [CallTurn],
        excludingWindowsFrom excluded: [CallTurn] = []
    ) -> Double? {
        guard !archived.isEmpty else { return nil }
        var hypothesis = bucket(live)
        var reference = bucket(archived)
        if !excluded.isEmpty {
            for index in bucket(excluded).keys {
                hypothesis[index] = nil
                reference[index] = nil
            }
        }
        guard !reference.isEmpty else { return nil }

        var errors = 0
        var referenceWords = 0
        for (index, referenceWordsInBucket) in reference {
            referenceWords += referenceWordsInBucket.count
            errors += TextMetrics.editDistance(hypothesis[index] ?? [], referenceWordsInBucket)
        }
        // Buckets the reference has nothing in but the hypothesis does are pure
        // insertions — usually a hallucination on silence, which is exactly the
        // kind of error a WER that ignored them would hide.
        for (index, hypothesisWords) in hypothesis where reference[index] == nil {
            errors += hypothesisWords.count
        }
        guard referenceWords > 0 else { return nil }
        return Double(errors) / Double(referenceWords)
    }

    /// How much of the reference's speech survived, by word count.
    ///
    /// Deliberately *not* an error rate: a substituted word is a transcription
    /// problem and shows up in WER, while a missing word is a suppression
    /// problem and is what this is watching for. Capped at 1 so a pass that
    /// produces more words than the reference reads as "kept everything" rather
    /// than as a score above full marks.
    static func coverage(
        live: [CallTurn],
        archived: [CallTurn],
        excludingWindowsFrom excluded: [CallTurn]
    ) -> Double? {
        guard !archived.isEmpty else { return nil }
        var hypothesis = bucket(live)
        var reference = bucket(archived)
        for index in bucket(excluded).keys {
            hypothesis[index] = nil
            reference[index] = nil
        }
        let referenceWords = reference.values.reduce(0) { $0 + $1.count }
        guard referenceWords > 0 else { return nil }
        let keptWords = hypothesis.values.reduce(0) { $0 + $1.count }
        return min(1, Double(keptWords) / Double(referenceWords))
    }

    /// Normalised words per time window, keyed by window index.
    ///
    /// A turn's words are spread across the windows its `[t0, t1]` actually
    /// covers, not dumped into the window it started in. That distinction is the
    /// difference between measuring transcription and measuring segmentation:
    /// merging whisper's sub-segments into whole clauses leaves the *words*
    /// unchanged (measured: 1,674 → 1,717 on one call) while halving the turn
    /// count, and a start-window-only bucketing scored that as a 12-point WER
    /// regression — every long turn piling into one window as insertions and
    /// leaving the next window's reference unmatched as deletions.
    ///
    /// Words are distributed evenly across the span, which assumes an even
    /// speaking rate within a turn. Over a 30-second window that is close enough;
    /// what it has to get right is which side of a boundary a clause falls on.
    private static func bucket(_ turns: [CallTurn]) -> [Int: [String]] {
        var buckets: [Int: [String]] = [:]
        for turn in turns.sorted(by: { $0.t0 < $1.t0 }) {
            let words = TextMetrics.normalize(turn.text)
            guard !words.isEmpty else { continue }

            let start = turn.t0
            let end = max(turn.t1, turn.t0)
            let first = Int(start / werWindowSeconds)
            let last = Int(end / werWindowSeconds)
            guard last > first else {
                buckets[first, default: []].append(contentsOf: words)
                continue
            }

            // Walk the words along the turn's own timeline.
            let span = end - start
            for (offset, word) in words.enumerated() {
                let position = start + span * (Double(offset) + 0.5) / Double(words.count)
                buckets[Int(position / werWindowSeconds), default: []].append(word)
            }
        }
        return buckets
    }

    private static func joined(_ turns: [CallTurn]) -> String {
        turns.sorted { $0.t0 < $1.t0 }.map(\.text).joined(separator: " ")
    }
}
