import Foundation
import IntelligenceCore
import IntelligenceProviders
import os.log

private let advisorLog = Logger(
    subsystem: "theboringteam.boringnotch.callhost",
    category: "intelligence"
)

/// Decides what the copilot asks about, who answers, and what happens when the
/// local brain fails.
///
/// Two very different providers sit behind this. The local one (`agy`) is
/// request/response: it is asked about a complete statement and answers in
/// ~2.5-3.5s. The Gateway is a push pipe with its own server-side batching, so it
/// is not modelled as an `IntelligenceProvider` — turns keep flowing to its socket
/// exactly as before and its suggestions arrive unprompted. This class owns the
/// one decision that connects them: whose suggestion the call should publish.
public actor CopilotAdvisor {
    public enum Provider: String, Sendable {
        case local
        case gateway
    }

    public struct Configuration: Sendable {
        public var callID: String
        public var persona: String
        public var profile: CallProfile?
        /// Preferred brain. `gateway` means the local provider is never asked.
        public var preferred: Provider
        /// Let the Gateway's pushed suggestions through when local answers fail.
        public var fallbackToGateway: Bool
        public var liveTier: ModelTier
        /// Exact model for the end-of-call pass, where a slower, better model is
        /// worth an extra few seconds.
        public var summaryModel: String?
        public var runtimeRoot: URL

        public init(
            callID: String,
            persona: String,
            profile: CallProfile?,
            preferred: Provider,
            fallbackToGateway: Bool,
            liveTier: ModelTier,
            summaryModel: String?,
            runtimeRoot: URL
        ) {
            self.callID = callID
            self.persona = persona
            self.profile = profile
            self.preferred = preferred
            self.fallbackToGateway = fallbackToGateway
            self.liveTier = liveTier
            self.summaryModel = summaryModel
            self.runtimeRoot = runtimeRoot
        }
    }

    private let config: Configuration
    private let provider: AgyProvider
    private var segmenter: StatementSegmenter
    private let blocks: PromptBlocks
    private let startedAt: Date

    /// Set once the local provider has failed in a way that will not fix itself,
    /// so the Gateway's pushes stop being suppressed.
    private var localGaveUp = false
    private var inFlight = false
    /// Statements that completed while a request was in flight. They go out as one
    /// prompt: a live call outruns any model, and three fragments in one request
    /// beat three requests.
    private var queued: [Statement] = []

    private var onSuggestion: (@Sendable (CopilotFrame.Suggestion, Provider) -> Void)?
    private var onProviderChange: (@Sendable (Provider, String?) -> Void)?

    public private(set) var statementsEmitted = 0
    public private(set) var turnsSeen = 0
    public private(set) var activeProvider: Provider
    public private(set) var providerDetail: String?
    /// Why the local brain last failed, whether or not that changed who answers.
    /// Without this a run with fallback disabled fails completely silently, which
    /// is the one situation where the reason matters most.
    public private(set) var lastFailure: String?

    /// Append-only diagnostics, next to the other host logs.
    ///
    /// `os_log` yields nothing from this executable — it is ad-hoc signed and the
    /// system drops it — so without this a call that produced no suggestions leaves
    /// nothing to explain why. Same idea as the tutor/node host logs.
    private var diagnosticsURL: URL {
        config.runtimeRoot
            .deletingLastPathComponent()
            .appendingPathComponent("logs/intelligence.log")
    }

    private func trace(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) [\(config.callID)] \(message)\n"
        let url = diagnosticsURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    public init(config: Configuration) {
        self.config = config
        segmenter = StatementSegmenter(rules: .call)
        blocks = CopilotLocalPrompt.blocks(persona: config.persona, profile: config.profile)
        startedAt = Date()
        activeProvider = config.preferred
        provider = AgyProvider(configuration: .init(runtimeRoot: config.runtimeRoot))
    }

    public func setHandlers(
        onSuggestion: @escaping @Sendable (CopilotFrame.Suggestion, Provider) -> Void,
        onProviderChange: @escaping @Sendable (Provider, String?) -> Void
    ) {
        self.onSuggestion = onSuggestion
        self.onProviderChange = onProviderChange
    }

    /// Pays every fixed cost before anyone says anything worth advising on.
    ///
    /// Without this the first suggestion of a call takes ~10s: booting the language
    /// server is only ~3s of it, and the rest is the Google handshake plus the
    /// bootstrap prompt, which are charged on the first submit. With it, the
    /// opening suggestion is a plain append at ~2.5s.
    public func prepare() async {
        trace("prepare: preferred=\(config.preferred.rawValue) tier=\(config.liveTier.rawValue) fallback=\(config.fallbackToGateway)")
        guard config.preferred == .local else {
            trace("prepare: local brain not selected, nothing to warm up")
            return
        }
        let availability = await provider.availability()
        guard availability.isReady else {
            trace("prepare: agy unavailable (\(availability))")
            note(failure: .providerMissing("agy is not installed"))
            return
        }
        await provider.prewarm()
        let opened = await provider.openSession(
            task: CopilotTasks.suggest,
            sessionKey: config.callID,
            system: blocks
        )
        trace("prepare: session opened=\(opened)")
    }

    // MARK: - Transcript in

    /// Feed every transcript turn. Only complete statements become requests — see
    /// `StatementSegmenter`. Turns still reach the archive and the Gateway
    /// elsewhere; this only decides what the local brain is asked about.
    public func ingest(turn: CallTurn) {
        turnsSeen += 1
        guard config.preferred == .local, !localGaveUp else { return }

        let elapsed = Date().timeIntervalSince(startedAt)
        // Logged at ingest, because "transcription works but nothing comes back"
        // needs to distinguish a turn never arriving from a statement never
        // completing from a request that failed.
        trace("turn seq=\(turn.seq) src=\(turn.source.rawValue) words=\(turn.text.split(separator: " ").count)")
        let statements = segmenter.ingest(
            TranscriptTurn(
                seq: turn.seq,
                speaker: turn.source == .me ? .local : .remote,
                start: turn.t0,
                end: turn.t1,
                text: turn.text
            ),
            now: max(elapsed, turn.t1)
        )
        dispatch(statements)
    }

    /// Call on a timer (~250ms) so a trailed-off sentence and a floor-delayed
    /// buffer still get out.
    public func tick() {
        guard config.preferred == .local, !localGaveUp else { return }
        dispatch(segmenter.tick(now: Date().timeIntervalSince(startedAt)))
    }

    private func dispatch(_ statements: [Statement]) {
        guard !statements.isEmpty else { return }
        trace("statements ready: \(statements.map { "seq \($0.fromSeq)-\($0.toSeq) (\($0.text.split(separator: " ").count)w)" }.joined(separator: ", "))")
        statementsEmitted += statements.count
        queued.append(contentsOf: statements)
        guard !inFlight else { return }
        inFlight = true
        Task { await self.drainQueue() }
    }

    private func drainQueue() async {
        while !queued.isEmpty {
            let batch = queued
            queued.removeAll()
            await ask(batch)
        }
        inFlight = false
    }

    /// Live settings the app can change mid-call.
    ///
    /// A small JSON file rather than a new IPC channel, matching how every other
    /// piece of state crosses this boundary here. Read per batch, so a toggle takes
    /// effect on the next statement rather than the next call.
    private var answersOnly: Bool {
        let url = config.runtimeRoot.appendingPathComponent("control.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["answers_only"] as? Bool ?? false
    }

    /// Sent when the copilot should speak only on being asked.
    private static let answersOnlyGuidance = [
        "Answer only what has been asked.",
        "If the latest input contains no question and no request, return an empty",
        "`headline` and add nothing — silence is the correct output, not a remark",
        "about what was said.",
    ].joined(separator: " ")

    /// The fewest words worth a request on their own.
    ///
    /// The transcriber emits whatever the VAD closed — "environment, right?", "yeah
    /// so", a name — and asking about a fragment costs a full ~15k-token request to
    /// be told nothing. Below this the text is carried forward instead of dropped,
    /// so the next real request still has it as context.
    private static let minWordsWorthAsking = 6

    /// Statements too thin to ask about on their own, waiting for one that is not.
    private var pendingContext: [Statement] = []

    private func ask(_ statements: [Statement]) async {
        guard let afterSeq = statements.last?.toSeq else { return }

        let batch = pendingContext + statements
        let words = batch.reduce(0) { $0 + $1.text.split(separator: " ").count }
        let asked = batch.contains { $0.speaker == .remote && $0.invitesAnAnswer }

        // "Answers only": speak when asked, stay quiet otherwise.
        if answersOnly, !asked {
            pendingContext = batch
            trace("held (answers-only, nothing asked): through seq \(afterSeq), \(words)w pending")
            return
        }
        // Otherwise a question always earns a request, and so does enough material.
        if !asked, words < Self.minWordsWorthAsking {
            pendingContext = batch
            trace("held (too thin): through seq \(afterSeq), \(words)w pending")
            return
        }
        pendingContext = []

        // "Answers only" means answer when asked and stay quiet otherwise. Checked
        // here rather than left to the model: an unwanted request costs ~15k tokens
        // and puts a suggestion on screen competing with the one that matters.
        if answersOnly, !statements.contains(where: { $0.speaker == .remote && $0.invitesAnAnswer }) {
            trace("skipped (answers-only, nothing was asked): through seq \(afterSeq)")
            return
        }
        var system = blocks
        if answersOnly { system.taskGuidance = Self.answersOnlyGuidance }

        let request = IntelligenceRequest(
            task: CopilotTasks.suggest,
            sessionKey: config.callID,
            system: system,
            input: PromptComposer.render(batch),
            tier: config.liveTier
        )

        do {
            let response = try await provider.respond(to: request)
            guard let payload = response.payload else {
                throw IntelligenceFailure.unparseable("no contract payload")
            }
            let suggestion = try CopilotSuggestionDecoder.decode(
                payload,
                callID: config.callID,
                afterSeq: afterSeq,
                latency: response.attribution.latency
            )
            advisorLog.notice("""
            local suggestion after seq \(afterSeq, privacy: .public) in \
            \(response.attribution.latency * 1000, format: .fixed(precision: 0), privacy: .public)ms \
            (model \(response.attribution.model, privacy: .public), \
            rollovers \(response.attribution.rollovers, privacy: .public))
            """)
            if activeProvider != .local {
                activeProvider = .local
                providerDetail = response.attribution.model
                onProviderChange?(.local, providerDetail)
            }
            trace("suggestion after seq \(afterSeq) in \(Int(response.attribution.latency * 1000))ms via \(response.attribution.model)")
            onSuggestion?(suggestion, .local)
        } catch let failure as IntelligenceFailure {
            note(failure: failure)
        } catch {
            note(failure: .transport(String(describing: error)))
        }
    }

    /// A local failure is only interesting if it changes who answers. Everything
    /// else is logged and the next statement tries again — a dropped suggestion
    /// costs one suggestion, never the transcript.
    private func note(failure: IntelligenceFailure) {
        advisorLog.error("local intelligence failed: \(String(describing: failure), privacy: .public)")
        trace("FAILURE \(String(describing: failure))")
        lastFailure = String(describing: failure)
        guard failure.disablesProvider || !failure.isRetryableInPlace else { return }
        // Reported whether or not there is somewhere to fall back to. Without a
        // gateway this used to return here silently, which is how a call could
        // transcribe perfectly and never answer, with nothing said about why.
        providerDetail = Self.describe(failure)
        if config.fallbackToGateway {
            localGaveUp = true
            activeProvider = .gateway
            trace("giving up on the local brain for this call: \(providerDetail ?? "")")
            onProviderChange?(.gateway, providerDetail)
        } else {
            trace("local brain failed and fallback is off: \(providerDetail ?? "")")
            onProviderChange?(.local, providerDetail)
        }
    }

    /// Whether a suggestion pushed by the Gateway should be published.
    ///
    /// While the local brain is answering, the Gateway is still receiving turns
    /// (so it can take over instantly) but its suggestions are suppressed — two
    /// brains writing to one panel would flicker between them.
    public func acceptsGatewaySuggestion() -> Bool {
        config.preferred == .gateway || localGaveUp
    }

    // MARK: - End of call

    /// One deeper pass when the call is over, on the exact model the user picked.
    ///
    /// Runs through the slow print transport by design: it costs ~8.5s of process
    /// start-up, which is irrelevant once the call has ended, and buys an exact
    /// model id instead of the fast path's coarse tier.
    public func summarise() async -> CopilotFrame.Suggestion? {
        guard config.preferred == .local, !localGaveUp else { return nil }
        let leftovers = pendingContext + segmenter.drain(now: Date().timeIntervalSince(startedAt))
        let tail = leftovers.isEmpty ? "" : "\n\nStill unanswered:\n" + PromptComposer.render(leftovers)

        let request = IntelligenceRequest(
            task: CopilotTasks.summary,
            sessionKey: config.callID,
            system: blocks,
            input: """
            The call has ended. Summarise it for the user's own notes: what was \
            agreed, what was promised by whom, and what is still open.\(tail)
            """,
            tier: .deep,
            exactModel: config.summaryModel
        )
        do {
            let response = try await provider.respond(to: request)
            guard let payload = response.payload else { return nil }
            return try CopilotSuggestionDecoder.decode(
                payload,
                callID: config.callID,
                afterSeq: turnsSeen,
                latency: response.attribution.latency
            )
        } catch {
            advisorLog.error("summary pass failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public func shutdown() async {
        await provider.closeSession(config.callID)
        await provider.shutdown()
    }

    /// Turns-in versus statements-out. A ratio near 1 means the batching rules are
    /// not firing and the whole point of the segmenter is lost.
    public func segmentationRatio() -> Double {
        guard statementsEmitted > 0 else { return 0 }
        return Double(turnsSeen) / Double(statementsEmitted)
    }

    static func describe(_ failure: IntelligenceFailure) -> String {
        switch failure {
        case .providerMissing: "agy not installed"
        case .unauthenticated: "agy not signed in"
        case .quotaExceeded: "agy quota exhausted"
        case .timedOut: "local answer too slow"
        case .unparseable: "local answer unusable"
        case .sessionDied: "local session lost"
        case .unsupportedTask: "task unsupported locally"
        case .missingSessionKey: "internal: no session key"
        case .transport: "local transport error"
        }
    }
}
