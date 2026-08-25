import Foundation

/// The sweep's aggregate answer.
///
/// Aggregates are weighted by the thing being measured — echo leak by `me` turn
/// count, WER by reference length — rather than by averaging per-call rates. A
/// six-turn call and a nine-hundred-turn call are not equal evidence, and a plain
/// mean of rates lets the short one dominate.
public struct EvalReport: Sendable, Codable {
    public var generatedAt: Date
    public var calls: [CallScore]

    public init(generatedAt: Date = Date(), calls: [CallScore]) {
        self.generatedAt = generatedAt
        self.calls = calls
    }

    public var callCount: Int { calls.count }
    public var callsWithReference: Int { calls.filter { $0.werThem != nil || $0.werMe != nil }.count }

    public var totalTurns: Int { calls.reduce(0) { $0 + $1.turns } }
    public var totalMeTurns: Int { calls.reduce(0) { $0 + $1.meTurns } }

    public var echoLeakRate: Double {
        let me = totalMeTurns
        guard me > 0 else { return 0 }
        return Double(calls.reduce(0) { $0 + $1.echoOverlappingTurns }) / Double(me)
    }

    public var echoExactDuplicates: Int { calls.reduce(0) { $0 + $1.echoExactDuplicates } }
    public var artifactTurns: Int { calls.reduce(0) { $0 + $1.artifactTurns } }

    public var shortTurnRate: Double {
        guard totalTurns > 0 else { return 0 }
        let short = calls.reduce(0.0) { $0 + $1.shortTurnRate * Double($1.turns) }
        return short / Double(totalTurns)
    }

    public var meanWordsPerTurn: Double {
        guard totalTurns > 0 else { return 0 }
        return calls.reduce(0.0) { $0 + $1.meanWordsPerTurn * Double($1.turns) } / Double(totalTurns)
    }

    public var medianWERThem: Double? { median(calls.compactMap(\.werThem)) }
    public var medianWERMe: Double? { median(calls.compactMap(\.werMe)) }
    public var medianEchoSurvivorsPerMinute: Double? {
        median(calls.filter { $0.meTurns > 0 }.map(\.echoSurvivorsPerMinute))
    }
    public var medianMeTurnsPerMinute: Double? {
        median(calls.filter { $0.turns > 5 }.map(\.meTurnsPerMinute))
    }
    /// Median over calls that actually had a stretch of the user talking alone.
    public var medianMicCoverage: Double? { median(calls.compactMap(\.micCoverage)) }

    public var totalSuggestions: Int { calls.reduce(0) { $0 + $1.suggestions } }
    public var ungroundedSuggestions: Int { calls.reduce(0) { $0 + $1.ungroundedSuggestions } }

    public var ungroundedRate: Double {
        let scored = calls.reduce(0) { $0 + $1.distinctHeadlines }
        guard scored > 0 else { return 0 }
        return Double(ungroundedSuggestions) / Double(calls.reduce(0) { $0 + $1.suggestions })
    }

    public var repeatRate: Double {
        let total = totalSuggestions
        guard total > 0 else { return 0 }
        let distinct = calls.reduce(0) { $0 + $1.distinctHeadlines }
        return 1 - Double(distinct) / Double(total)
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Thresholds a change must not cross.
    ///
    /// Set from the measured baseline with headroom, not from ambition: the point
    /// is to catch a regression, and a gate nobody can pass gets disabled. Move
    /// them down as the numbers come down.
    public struct Gate: Sendable {
        public var maxEchoSurvivorsPerMinute: Double
        public var minMicCoverage: Double
        public var maxShortTurnRate: Double
        public var maxArtifactTurns: Int
        public var maxUngroundedRate: Double

        /// Measured on the 54-call corpus before any of this work: echo leak
        /// 35.8% of microphone turns, 19.1% of turns three words or shorter, 65
        /// bracketed non-speech turns, 6.5% of suggestions asserting something
        /// nothing supported.
        public static let baseline = Gate(
            maxEchoSurvivorsPerMinute: 1.0,
            // The over-suppression guard. A detector that deletes the user's
            // half of the call scores perfectly on every other line here.
            // Measured at 0.92 on headset calls after the echo work.
            minMicCoverage: 0.80,
            maxShortTurnRate: 0.20,
            maxArtifactTurns: 5,
            // Scored over *stored* suggestions, which a replay does not
            // regenerate — so this tracks how strict the claim guard is, not
            // what the current pipeline would say. It rose from 6.5% to 7.4%
            // when echo suppression landed, and that rise is correct: removing
            // the microphone's copy of the other party removes the "evidence"
            // that was vouching for suggestions built on it. Set above both.
            maxUngroundedRate: 0.09)

        public init(
            maxEchoSurvivorsPerMinute: Double,
            minMicCoverage: Double,
            maxShortTurnRate: Double,
            maxArtifactTurns: Int,
            maxUngroundedRate: Double
        ) {
            self.maxEchoSurvivorsPerMinute = maxEchoSurvivorsPerMinute
            self.minMicCoverage = minMicCoverage
            self.maxShortTurnRate = maxShortTurnRate
            self.maxArtifactTurns = maxArtifactTurns
            self.maxUngroundedRate = maxUngroundedRate
        }
    }

    /// What crossed a threshold, in the words a failing build should print.
    public func failures(against gate: Gate = .baseline) -> [String] {
        var failures: [String] = []
        if let echo = medianEchoSurvivorsPerMinute, echo > gate.maxEchoSurvivorsPerMinute {
            failures.append(String(
                format: "echo survivors/min %.2f exceeds %.2f",
                echo, gate.maxEchoSurvivorsPerMinute))
        }
        if let coverage = medianMicCoverage, coverage < gate.minMicCoverage {
            failures.append(String(
                format: "mic coverage %.0f%% is below %.0f%% — the user's own speech is being suppressed",
                coverage * 100, gate.minMicCoverage * 100))
        }
        if shortTurnRate > gate.maxShortTurnRate {
            failures.append(String(
                format: "turns of three words or fewer %.1f%% exceeds %.1f%%",
                shortTurnRate * 100, gate.maxShortTurnRate * 100))
        }
        if artifactTurns > gate.maxArtifactTurns {
            failures.append("\(artifactTurns) bracketed non-speech turns exceeds \(gate.maxArtifactTurns)")
        }
        if ungroundedRate > gate.maxUngroundedRate {
            failures.append(String(
                format: "ungrounded suggestions %.1f%% exceeds %.1f%%",
                ungroundedRate * 100, gate.maxUngroundedRate * 100))
        }
        return failures
    }

    /// The table printed to stdout. One block of headline numbers, then the
    /// worst calls — a sweep that only prints an average hides the call that
    /// broke.
    public func render(worstCount: Int = 8) -> String {
        var out: [String] = []
        let replays = calls.filter(\.isReplay).count
        out.append("calls \(callCount)  (\(callsWithReference) with an archive reference"
            + (replays > 0 ? ", \(replays) scored from a pipeline replay" : "")
            + ")   turns \(totalTurns)")
        out.append("")
        out.append("ASR      median WER them  \(percent(medianWERThem))     median WER me  \(percent(medianWERMe))  (remote-silent windows only)")
        out.append("echo     survivors/min    \(rate(medianEchoSurvivorsPerMinute))     leak rate  \(percent(echoLeakRate))   exact duplicates  \(echoExactDuplicates)")
        out.append("retain   mic coverage     \(percent(medianMicCoverage))     of the user's own words, where the remote leg was silent")
        out.append("segment  turns <=3 words  \(percent(shortTurnRate))     mean words/turn   \(String(format: "%.1f", meanWordsPerTurn))")
        out.append("artifact bracketed turns  \(artifactTurns)")
        out.append("suggest  ungrounded       \(percent(ungroundedRate))     repeat rate       \(percent(repeatRate))  (\(totalSuggestions) rows)")
        out.append("")

        let worst = calls
            .filter { $0.meTurns >= 10 }
            .sorted { $0.echoSurvivorsPerMinute > $1.echoSurvivorsPerMinute }
            .prefix(worstCount)
        if !worst.isEmpty {
            out.append("worst echo leak:")
            out.append("  call                      me   echo/min  leak    short")
            for score in worst {
                out.append("  "
                    + pad(score.callID, 24)
                    + pad("\(score.meTurns)", 6)
                    + pad(rate(score.echoSurvivorsPerMinute), 10)
                    + pad(percent(score.echoLeakRate), 8)
                    + percent(score.shortTurnRate))
            }
            out.append("")
        }

        let fabrications = calls
            .filter { $0.ungroundedSuggestions > 0 }
            .sorted { $0.ungroundedSuggestions > $1.ungroundedSuggestions }
            .prefix(worstCount)
        if !fabrications.isEmpty {
            out.append("most ungrounded claims:")
            for score in fabrications {
                let tokens = score.unsupportedTokens.prefix(8).joined(separator: ", ")
                out.append("  \(score.callID)  \(score.ungroundedSuggestions)/\(score.suggestions)  [\(tokens)]")
            }
        }
        return out.joined(separator: "\n")
    }

    /// Left-aligned fixed-width column. `String(format: "%s")` takes a C string,
    /// not a Swift `String`, so it is the wrong tool here.
    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    private func rate(_ value: Double?) -> String {
        guard let value else { return "  n/a" }
        return String(format: "%5.2f", value)
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "  n/a" }
        return String(format: "%4.1f%%", value * 100)
    }
}
