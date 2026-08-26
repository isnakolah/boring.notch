import Foundation
import CallaContracts
import IntelligenceCore
import IntelligenceProviders
import IntelligenceStore
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
        /// The knowledge base and call history. Absent in probes and tests.
        public var store: CallaStore?

        public init(
            callID: String,
            persona: String,
            profile: CallProfile?,
            preferred: Provider,
            fallbackToGateway: Bool,
            liveTier: ModelTier,
            summaryModel: String?,
            runtimeRoot: URL,
            store: CallaStore? = nil
        ) {
            self.callID = callID
            self.persona = persona
            self.profile = profile
            self.preferred = preferred
            self.fallbackToGateway = fallbackToGateway
            self.liveTier = liveTier
            self.summaryModel = summaryModel
            self.runtimeRoot = runtimeRoot
            self.store = store
        }
    }

    private let config: Configuration
    private let provider: AgyProvider
    private var segmenter: StatementSegmenter
    private let blocks: PromptBlocks
    /// What the account and fold lanes are told about the call.
    ///
    /// They are separate `agy` conversations from the question lane, with their own
    /// system prompt — which used to be the contract and nothing else. A lane that
    /// does not know the user owns billing writes "they discussed a service" where
    /// it could have written the name, and the fold then bakes the vaguer wording
    /// into standing fact. Same background, minus the persona and the answer
    /// contract, which are the question lane's business alone.
    private let about: String
    private let background: String
    private let startedAt: Date

    private func ledgerBlocks(_ base: String) -> PromptBlocks {
        PromptBlocks(base: base, about: about, knowledge: background)
    }

    /// Set once the local provider has failed in a way that will not fix itself,
    /// so the Gateway's pushes stop being suppressed.
    private var localGaveUp = false

    /// One question at a time on the question lane.
    ///
    /// Not just pacing: `AgyProvider` reads its session state before the await and
    /// writes it back after, so two concurrent requests on the same conversation key
    /// can bootstrap twice or lose the conversation id between them.
    private var askInFlight = false
    /// The question that arrived while one was being answered. Only the newest is
    /// kept — by the time the model answers, an older question has been overtaken
    /// by the one the other side actually just asked.
    private var queuedQuestion: [Statement]?

    private var onSuggestion: (@Sendable (CopilotFrame.Suggestion, Provider) -> Void)?
    private var onProviderChange: (@Sendable (Provider, String?) -> Void)?
    /// Fired when the copilot starts or stops working, so the panel can say so.
    private var onActivity: (@Sendable () -> Void)?

    /// The audio position of the last turn and when it was seen, so silence is
    /// measured on the same scale the turns use.
    private var lastTurnEnd: Double = 0
    private var lastTurnObservedAt = Date()

    /// Where the audio has got to, extrapolated from the last turn.
    private func audioNow() -> Double {
        lastTurnEnd + Date().timeIntervalSince(lastTurnObservedAt)
    }

    public private(set) var statementsEmitted = 0
    public private(set) var turnsSeen = 0
    public private(set) var activeProvider: Provider
    public private(set) var providerDetail: String?
    /// Why the local brain last failed, whether or not that changed who answers.
    /// Without this a run with fallback disabled fails completely silently, which
    /// is the one situation where the reason matters most.
    public private(set) var lastFailure: String?
    /// Separate lane state. Question and Summary requests may overlap, while each
    /// lane remains serial against its own warm conversation.
    public private(set) var questionWorking = false
    public private(set) var summaryWorking = false
    /// Legacy single-value projection for older readers.
    public var workingOn: String? {
        questionWorking ? "answer" : (summaryWorking ? "summary" : nil)
    }
    public var isThinking: Bool { questionWorking || summaryWorking }
    /// The newest pointer answered a question rather than remarking on a statement.
    public private(set) var lastAnswerWasToAQuestion = false

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
        about = config.profile?.about ?? ""
        background = CopilotLocalPrompt.background(profile: config.profile)
        startedAt = Date()
        activeProvider = config.preferred
        provider = AgyProvider(configuration: .init(runtimeRoot: config.runtimeRoot))
        store = config.store
        // Everything the user has told us about themselves before the call
        // started. A suggestion may draw on any of it without being called
        // invented; anything outside it has to be earned during the call.
        claimEvidence = ClaimGuard.Evidence(sources: [
            about,
            background,
            config.profile?.knowledge ?? "",
        ])
    }

    /// Where knowledge is retrieved from, and where this call is recorded.
    ///
    /// Optional because every path that uses the advisor without a store — the
    /// `probe-local` subcommand, the unit tests — must keep working. A nil store
    /// means no retrieval and no persistence; it never means a failed call.
    private let store: CallaStore?

    public func setHandlers(
        onActivity: (@Sendable () -> Void)? = nil,
        onSuggestion: @escaping @Sendable (CopilotFrame.Suggestion, Provider) -> Void,
        onProviderChange: @escaping @Sendable (Provider, String?) -> Void
    ) {
        self.onActivity = onActivity
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
        // Both lanes warm, and warmed together.
        //
        // They are separate `agy` conversations — the question lane holds the call
        // and answers from it, the chunk lane holds the account and grows it — so
        // each pays its own bootstrap. Paying them concurrently while the call is
        // still greetings is the difference between two warm lanes and one warm lane
        // plus a ~10s stall the first time the account is compiled.
        async let question = provider.openSession(
            task: CopilotTasks.suggest,
            sessionKey: config.callID,
            system: blocks
        )
        async let chunks = provider.openSession(
            task: CopilotTasks.brief,
            sessionKey: briefSessionKey,
            system: ledgerBlocks(CopilotBriefPrompt.text)
        )
        let (openedQuestion, openedChunks) = await (question, chunks)
        trace("prepare: question lane opened=\(openedQuestion) chunk lane opened=\(openedChunks)")
    }

    /// The chunk lane's conversation. Suffixed rather than separate so a stray
    /// `closeSession` on the call id cannot take the wrong one down.
    private var briefSessionKey: String { "\(config.callID)#brief" }

    // MARK: - Transcript in

    /// Feed every transcript turn. Only complete statements become requests — see
    /// `StatementSegmenter`. Turns still reach the archive and the Gateway
    /// elsewhere; this only decides what the local brain is asked about.
    public func ingest(turn: CallTurn) {
        turnsSeen += 1
        // Before the local-provider guard: the transcript is evidence whether or
        // not this call is using the local brain.
        if turn.source == .me {
            // Not evidence if we are not sure it was said. A misheard word
            // vouching for an invented one is the exact failure this guards.
            if !turn.isLowConfidence { claimEvidence.add(turn.text) }
        } else {
            // Name material only — never numbers, never credentials.
            claimEvidence.addHeardNames(turn.text)
        }
        guard config.preferred == .local, !localGaveUp else { return }

        // One clock, and it is the audio's.
        //
        // The segmenter reasons about gaps between turns, and those are in audio
        // time. Feeding it wall-clock from the tick and audio time from the turns
        // mixed two scales that drift apart — transcription runs behind live audio —
        // so a gap could come out negative and the pacing rules never fired.
        lastTurnEnd = turn.t1
        lastTurnObservedAt = Date()
        // Logged at ingest, because "transcription works but nothing comes back"
        // needs to distinguish a turn never arriving from a statement never
        // completing from a request that failed.
        trace("turn seq=\(turn.seq) src=\(turn.source.rawValue) words=\(turn.text.split(separator: " ").count)")
        // A turn the decoder was unsure of is marked rather than dropped. It
        // still reaches the transcript and still counts as someone speaking —
        // dropping it would make the segmenter think the room went quiet — but
        // the model is told not to build a fact on it. Whisper renders a shaky
        // number or name as confidently as a clear one, and the ledger's
        // `standing` paragraph is permanent for the rest of the call.
        let text = turn.isLowConfidence ? "\(turn.text) [unclear]" : turn.text
        let statements = segmenter.ingest(
            TranscriptTurn(
                seq: turn.seq,
                speaker: turn.source == .me ? .local : .remote,
                start: turn.t0,
                end: turn.t1,
                text: text
            ),
            now: audioNow()
        )
        dispatch(statements)
    }

    /// User-triggered questions may quote either speaker. They bypass remote-only
    /// automatic detection but still serialize through question lane.
    public func askManual(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 1_200, config.preferred == .local, !localGaveUp else { return }
        let seq = max((ledger.lastSeq ?? 0) + 1, turnsSeen + 1)
        enqueueQuestion([Statement(fromSeq: seq, toSeq: seq, speaker: .local,
                                   text: text, span: 0, truncated: false)])
    }

    /// Call on a timer (~250ms) so a trailed-off sentence and a floor-delayed
    /// buffer still get out.
    public func tick() {
        guard config.preferred == .local, !localGaveUp else { return }
        dispatch(segmenter.tick(now: audioNow()))
        // Also checked here: a call can go quiet for minutes, and a chunk's
        // ninety-second deadline should still close while it does.
        closeChunkIfDue()
    }

    private func dispatch(_ statements: [Statement]) {
        guard !statements.isEmpty else { return }

        // Everything said enters the ledger, whether or not it is answered.
        //
        // Previously this was appended where a suggestion was published, which made
        // the account a summary of the *answers* rather than of the call.
        statementsEmitted += statements.count
        ledger.append(statements)
        for statement in statements {
            summaryTrigger.recordStatement()
            let text = statement.text.lowercased()
            if text.contains("we decided") || text.contains("we agreed") ||
                text.contains("i commit") || text.contains("we will") {
                pendingCommitmentOrDecision = true
            }
        }
        // Only a question spends a pointer request.
        //
        // Both jobs run the whole time — questions get answered, the account keeps
        // growing — and the panel's toggle only chooses which one is on screen. That
        // is also what makes the answer fast: commentary on ordinary statements used
        // to occupy the provider, so a question could arrive behind a request nobody
        // asked for. Now the queue is almost always empty when one lands.
        let questions = statements.filter { $0.speaker == .remote && $0.invitesAnAnswer }
        guard !questions.isEmpty else {
            trace("no question in \(statements.count) statement(s); ledger only")
            closeChunkIfDue()
            return
        }
        trace("PRIORITY question through seq \(questions.last?.toSeq ?? -1)")
        enqueueQuestion(questions)
    }

    /// One question in flight, the newest one queued behind it.
    ///
    /// Answering two at once is worse than it sounds: they share the question lane's
    /// conversation, whose session state in `AgyProvider` is read before the await
    /// and written after it, so the second can bootstrap a conversation the first
    /// then overwrites. And the older answer is discarded on arrival anyway.
    private func enqueueQuestion(_ statements: [Statement]) {
        guard !askInFlight else {
            if let dropped = queuedQuestion?.last?.toSeq {
                trace("dropped queued question through seq \(dropped); a newer one arrived")
            }
            queuedQuestion = statements
            return
        }
        askInFlight = true
        Task { await self.runQuestion(statements) }
    }

    private func runQuestion(_ statements: [Statement]) async {
        var batch = statements
        while true {
            await ask(batch)
            guard let next = queuedQuestion else { break }
            queuedQuestion = nil
            batch = next
        }
        askInFlight = false
        // A chunk that came due while the question held the lane goes now.
        closeChunkIfDue()
    }


    // MARK: - The ledger
    //
    // The account of the call, grown a chunk at a time on its own warm lane by a
    // stronger model, replacing the one-line summary every pointer used to carry.
    // Two reasons: asking a fast model to re-summarise on every pointer paid for the
    // same paragraph over and over and made the urgent thing slower; and a compiled
    // account plus the last few turns verbatim is a better piece of context to send
    // with the next question than an ever-growing pile of turns.

    /// The account as it stands. Exposed so `probe-local` can show whether it is
    /// actually accumulating, which is not visible from the suggestions alone.
    public var brief: String { ledger.panelSummary() }
    /// The whole ledger, for diagnostics.
    public var ledgerState: CallLedger { ledger }

    /// Statements said but not yet folded into the account.
    ///
    /// Exposed because "is the summary keeping up" is otherwise invisible: a
    /// panel showing an account has no way to say whether that account is
    /// current or a minute stale, and the two look identical.
    public var pendingStatements: Int { ledger.tail.count }
    /// How much account there is. Pairs with `pendingStatements` to say both
    /// what has been captured and what has not.
    public var accountPoints: Int { ledger.pointCount }

    /// Closes whatever is still in the tail, and waits for it.
    ///
    /// The end of a call used to run the deep closing pass and stop. That pass
    /// reads the tail, so its *overview* covered everything — but the recap's
    /// points come from `durableSummary()`, which reads only the chunks. So
    /// anything said after the last chunk closed reached the paragraph and never
    /// reached the list, and a call that ended mid-topic lost its last minute of
    /// decisions and commitments from the itemised recap entirely.
    ///
    /// Called before `summarise()`, so both halves of the recap see the same
    /// call.
    public func closeOpenChunk() async {
        guard config.preferred == .local, !localGaveUp else { return }
        // Anything still inside the segmenter is a real turn too — a call that
        // ends while somebody is finishing a sentence should keep the sentence.
        let trailing = segmenter.drain(now: audioNow())
        if !trailing.isEmpty {
            statementsEmitted += trailing.count
            ledger.append(trailing)
        }
        guard !chunkInFlight, !ledger.tail.isEmpty else { return }
        chunkInFlight = true
        await closeChunk(ledger.takeTail())
    }

    /// The account in the shape the store keeps it, for the end of the call.
    ///
    /// This is what survives the process. Everything else the advisor holds is
    /// working memory that dies with the host; these three fields are the reason
    /// the next occurrence of a recurring meeting is not starting from nothing.
    public func durableSummary() -> CallSummary {
        CallSummary(
            callID: config.callID,
            standing: ledger.standing,
            points: ledger.chunks.flatMap(\.points),
            openQuestions: ledger.openQuestions)
    }

    /// Chunks that recorded nothing, and how many of those are consecutive.
    ///
    /// Exposed because "the summary is not picking anything up" was previously
    /// unanswerable from outside: an empty panel is what a quiet call and a
    /// broken account both look like.
    public private(set) var emptyChunks = 0
    public private(set) var consecutiveEmptyChunks = 0
    /// Chunks that recorded something. With `emptyChunks`, the hit rate.
    public private(set) var closedChunks = 0

    private var ledger = CallLedger()
    private var chunkInFlight = false
    private var execInFlight = false
    private var summaryTrigger = CallSummaryTrigger()
    private var pendingCommitmentOrDecision = false
    /// How many times the chunk lane's conversation has been rolled over. When this
    /// moves, the lane has forgotten the account and the next chunk has to restate
    /// it — the one case where the warm conversation is not enough on its own.
    private var chunkRollovers = 0
    /// The last frame published, so a finished chunk can refresh the panel without
    /// wiping the pointer on it.
    private var lastSuggestion: CopilotFrame.Suggestion?
    /// The seq of the last real answer. Kept apart from `lastSuggestion` because
    /// the account publishes frames of its own.
    private var lastAnswerSeq = -1

    /// What a suggestion is allowed to assert, grown as the call proceeds.
    ///
    /// Seeded from the user's own profile text and whatever knowledge was packed
    /// for this call, then extended with every `me` turn — the user's own words
    /// are the strongest evidence there is for what the user can claim. Never
    /// extended with `them` turns: "Do you have a CS degree?" must not license
    /// "I have a CS degree", and treating a question as evidence is precisely
    /// how a leading question becomes a fabricated answer.
    private var claimEvidence = ClaimGuard.Evidence()
    /// Suggestions whose speakable line asserted something nothing supports.
    public private(set) var ungroundedSuggestions = 0
    /// Requests the fast transport could not serve. A call spending 8.5s per
    /// pointer instead of 2.5s used to look exactly like a healthy one.
    public private(set) var fellBackRequests = 0

    /// Closes deterministic three-statement, decision/commitment, quiet, or
    /// sixty-second summaries. This runs alongside Question on its own warm lane.
    ///
    private func closeChunkIfDue() {
        guard !chunkInFlight, !ledger.tail.isEmpty else { return }
        guard summaryTrigger.isDue(
            now: Date(), commitmentOrDecision: pendingCommitmentOrDecision,
            answerInFlight: false) else { return }

        chunkInFlight = true
        let material = ledger.takeTail()
        Task { await self.closeChunk(material) }
    }

    private func closeChunk(_ material: [Statement]) async {
        // Reported separately from answering: this is the slower job, and a panel
        // that claims to be finding an answer for four seconds reads as stuck.
        summaryWorking = true
        onActivity?()
        defer {
            chunkInFlight = false
            summaryWorking = false
            onActivity?()
        }

        // The new turns, and the lines already on the record.
        //
        // The lane's conversation is the memory of everything before them, which is
        // what lets the account grow by appending instead of being rewritten. But
        // remembering the turns is not the same as remembering the exact lines it
        // wrote about them: without these it re-says the same fact in new words
        // every chunk, and the panel fills with near-duplicates.
        var input = PromptComposer.render(material)
        let recorded = chunkRolloverPending
            // A rolled-over conversation remembers nothing, so it gets the lot.
            ? ledger.accountLines
            : ledger.lastPoints(6)
        if !recorded.isEmpty {
            input = "Already on the record — do not repeat these, in any wording:\n"
                + recorded.joined(separator: "\n")
                + "\n\nNew turns:\n" + input
        } else if ledger.pointCount == 0 {
            // The lane is told an empty answer is a normal answer, and it is —
            // once there is an account to leave alone. While there is none, the
            // same instruction produces calls whose account never starts at all:
            // more than half the chunks on this machine have recorded nothing,
            // and whole calls have gone by with an empty panel while the model
            // answered in two seconds every time. Nothing is on the record yet,
            // so there is nothing to be redundant with, and that is worth
            // saying rather than leaving to be inferred.
            input = """
            Nothing has been recorded for this call yet, so no line can repeat \
            anything. If these turns established anything concrete at all — a name, \
            a number, a system, a plan, a constraint, what someone is doing — record \
            it. Reserve the empty answer for turns that truly established nothing.

            New turns:
            """ + "\n" + input
        }

        let request = IntelligenceRequest(
            task: CopilotTasks.brief,
            sessionKey: briefSessionKey,
            system: ledgerBlocks(CopilotBriefPrompt.text),
            input: input
        )
        do {
            let response = try await provider.respond(to: request)
            chunkRolloverPending = response.attribution.rollovers > chunkRollovers
            chunkRollovers = response.attribution.rollovers
            guard let payload = response.payload,
                  let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
            else { return }
            let points = Self.points(from: object["points"])
                // Tolerated in case a model answers with the older single-string shape.
                ?? (object["summary"] as? String).map { [$0] }
                ?? []
            closedChunks += 1
            ledger.applyChunk(
                points: points,
                openQuestions: Self.points(from: object["open_questions"]),
                throughSeq: material.last?.toSeq ?? -1
            )
            summaryTrigger.didSummarize()
            pendingCommitmentOrDecision = false
            if points.isEmpty {
                emptyChunks += 1
                consecutiveEmptyChunks += 1
                // A chunk that records nothing is a normal answer once — the
                // lane is told to prefer an empty answer over a filler line —
                // and a symptom once it keeps happening. It used to be neither,
                // because the only trace said "0 points" in the same words for
                // both, and a call whose account never started looked exactly
                // like a quiet one. The keys are logged so the other cause, a
                // reply in a shape this does not parse, is distinguishable from
                // a reply that genuinely held nothing.
                trace("""
                chunk closed in \(Int(response.attribution.latency * 1000))ms from \
                \(material.count) statements -> NO POINTS \
                (\(consecutiveEmptyChunks) in a row, \(ledger.pointCount) in the account); \
                reply keys: \(object.keys.sorted().joined(separator: ","))
                """)
            } else {
                consecutiveEmptyChunks = 0
                trace("""
                chunk closed in \(Int(response.attribution.latency * 1000))ms from \
                \(material.count) statements -> \(points.count) points \
                (\(ledger.pointCount) in the account)
                """)
            }
            publishLedgerToPanel()
            foldIfDue()
        } catch {
            // A chunk that fails costs context, not the call. Its statements go back
            // to the tail, so the next chunk carries them.
            trace("chunk failed: \(String(describing: error))")
            ledger.restore(material)
        }
    }

    /// A list of lines out of whatever the model actually sent.
    ///
    /// `as? [String]` alone is a silent failure: a model that answers with a
    /// single newline-separated string, or with objects instead of strings,
    /// produced exactly the same "0 points" as one that deliberately recorded
    /// nothing — same log line, no error, no way to tell them apart. Each shape
    /// here has been seen from some model at some point.
    static func points(from value: Any?) -> [String]? {
        switch value {
        case let list as [String]:
            return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        case let text as String:
            return text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        case let objects as [[String: Any]]:
            // `[{"point": "..."}]` and `[{"text": "..."}]` both turn up.
            return objects.compactMap { object in
                for key in ["point", "text", "line", "summary"] {
                    if let value = object[key] as? String,
                       !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return value.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                return nil
            }
        default:
            return nil
        }
    }

    /// Set when the chunk lane rolled its conversation; cleared once the account has
    /// been restated into the fresh one.
    private var chunkRolloverPending = false

    /// Folds the oldest points into standing fact, in a fresh conversation each
    /// time. Runs behind the chunk lane and never while a question is in flight.
    private func foldIfDue() {
        guard !execInFlight, !askInFlight, ledger.needsFold else { return }
        let folding = ledger.foldable()
        guard !folding.isEmpty else { return }
        execInFlight = true
        Task { await self.fold(folding) }
    }

    private func fold(_ chunks: [CallLedger.Chunk]) async {
        summaryWorking = true
        onActivity?()
        defer {
            execInFlight = false
            summaryWorking = false
            onActivity?()
        }
        let previous = ledger.standing.isEmpty ? "(nothing yet)" : ledger.standing
        let request = IntelligenceRequest(
            task: CopilotTasks.exec,
            sessionKey: nil,
            system: ledgerBlocks(CopilotExecPrompt.text),
            input: """
            Summary so far:
            \(previous)

            Points to fold into it:
            \(chunks.flatMap(\.points).joined(separator: "\n"))
            """
        )
        do {
            let response = try await provider.respond(to: request)
            guard let payload = response.payload,
                  let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let standing = object["standing"] as? String
            else { return }
            ledger.applyFold(standing: standing, over: chunks.count)
            trace("folded \(chunks.count) chunk(s) in \(Int(response.attribution.latency * 1000))ms")
            publishLedgerToPanel()
        } catch {
            // Nothing is dropped on failure: the points stay where they are and the
            // next chunk makes the fold due again.
            trace("fold failed: \(String(describing: error))")
        }
    }

    /// Pushes the account to the panel without disturbing the pointer on screen.
    ///
    /// The frame the whole app speaks is a *suggestion*, so before this the account
    /// could only travel as a refresh of one — and on a call where nobody has asked
    /// anything yet there is no suggestion to refresh. The account compiled
    /// perfectly and reached nothing: a call could run for minutes with points
    /// accumulating in memory and an empty panel on screen. An answerless frame is
    /// the fix; the app already treats an empty headline as "no pointer, show the
    /// account", which is exactly the state being described.
    private func publishLedgerToPanel() {
        let summary = ledger.panelSummary()
        guard !summary.isEmpty || !ledger.openQuestions.isEmpty else { return }

        // The cursor is the account's, not the last answer's.
        //
        // This reused `lastSuggestion` wholesale, so every account frame carried
        // the `afterSeq` of whatever question was answered last. On a call that
        // ran seven minutes past its final question, the panel and the archive
        // both kept reporting `after_seq: 68` at turn 190 — anything keyed on
        // that cursor cannot tell a fresh frame from a repeat.
        let cursor = max(ledger.lastSeq ?? turnsSeen, lastSuggestion?.afterSeq ?? 0)
        var frame = lastSuggestion ?? CopilotFrame.Suggestion(
            callID: config.callID,
            afterSeq: cursor,
            headline: "",
            angles: [],
            confirm: [],
            latencyMs: 0
        )
        frame.afterSeq = cursor
        frame.summary = summary
        frame.openQuestions = ledger.openQuestions

        // An account that has not changed is not news. Republishing it wrote the
        // same record to suggestions.jsonl every few seconds — twenty-five
        // byte-identical lines in one call — and woke every reader for nothing.
        if let previous = lastSuggestion,
           previous.summary == frame.summary,
           previous.openQuestions == frame.openQuestions,
           previous.headline == frame.headline {
            lastSuggestion = frame
            return
        }

        lastSuggestion = frame
        onSuggestion?(frame, activeProvider)
    }

    /// Knowledge for the question about to be asked.
    ///
    /// Only the *question* is used as the query, not the whole batch: a statement
    /// that merely preceded the question drags its own subject into the search and
    /// the top hit ends up being about the small talk. Three chunks is the ceiling
    /// because they are prepended to a live prompt — more context here costs
    /// latency on the one request nobody can wait for.
    ///
    /// The search is a few milliseconds (an FTS index lookup plus a scan of a few
    /// thousand vectors), so this is on the critical path without being on the
    /// budget. It never throws: a store that cannot answer returns nothing and the
    /// call proceeds exactly as it did before there was one.
    /// What the knowledge base has to say about this moment.
    ///
    /// Scoped on the meeting when there is one and on the persona otherwise —
    /// **not** gated on it. This used to open `guard let meeting = …else { return
    /// [] }`, which meant an ad-hoc call retrieved nothing at all, including
    /// notes filed under `.always`. Across 43 recorded calls the word "recalled"
    /// never once appears in `intelligence.log`: retrieval had never run.
    ///
    /// It is not an academic gap. Documents reach the model *only* through this
    /// path — `CallaStore.promptBlock` deliberately packs typed notes whole and
    /// gives a document nothing but a manifest line — so with retrieval off, no
    /// attached document had ever reached the model. That is why a call where the
    /// interviewer said "I don't see that in the CV" produced an invented
    /// Computer Science degree with the user's actual CV sitting in the store.
    private func recall(for statements: [Statement]) async -> [String] {
        guard let store else { return [] }
        let question = statements
            .filter { $0.speaker == .remote && $0.invitesAnAnswer }
            .map(\.text)
            .joined(separator: " ")
        let query = question.isEmpty ? statements.map(\.text).joined(separator: " ") : question
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let hits = await store.search(query: query, scopes: retrievalScopes(), limit: 3)
        guard !hits.isEmpty else {
            trace("recalled nothing for \(query.prefix(60))")
            return []
        }
        trace("recalled \(hits.count) chunk(s): \(hits.map(\.title).joined(separator: ", "))")
        return hits.map { "\($0.title): \($0.text)" }
    }

    /// General to specific, matching `MeetingContext.scopes(persona:)`. The
    /// meeting scopes are appended when a meeting is known; the first two always
    /// apply.
    private func retrievalScopes() -> [KnowledgeScope] {
        if let meeting = config.profile?.meeting {
            return meeting.scopes(persona: config.persona)
        }
        var scopes: [KnowledgeScope] = [.always]
        if !config.persona.isEmpty { scopes.append(.persona(config.persona)) }
        return scopes
    }

    private func ask(_ statements: [Statement]) async {
        guard let afterSeq = statements.last?.toSeq else { return }

        let batch = statements
        let asked = batch.contains { $0.speaker == .remote && $0.invitesAnAnswer }

        questionWorking = true
        onActivity?()
        defer {
            questionWorking = false
            onActivity?()
        }

        let system = blocks
        let recalled = await recall(for: batch)

        let request = IntelligenceRequest(
            task: CopilotTasks.suggest,
            sessionKey: config.callID,
            system: system,
            // What the notes say, then the account as established fact, then the
            // last few statements verbatim, then the question. Sent in full every
            // time rather than left to the conversation to remember, so a context
            // rollover — or a host restart — is invisible instead of amnesia.
            input: ledger.questionContext(batch, recalled: recalled),
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
            trace("suggestion after seq \(afterSeq) in \(Int(response.attribution.latency * 1000))ms via \(response.attribution.model)"
                + (response.attribution.fellBack ? " [SLOW TRANSPORT]" : ""))
            if response.attribution.fellBack { fellBackRequests += 1 }
            // The pointer carries the compiled account rather than writing its own,
            // so the panel's summary is the considered one and the fast model never
            // spends output on it.
            // A priority request runs alongside whatever was already going, so
            // answers can finish out of order. The newer question's answer wins;
            // publishing the older one after it would put a stale pointer on screen.
            // Measured against the last *answer*, not the last frame: the account
            // publishes frames too, and theirs can be ahead of a question still in
            // flight — which would drop the answer as stale on a call where every
            // answer was in fact the newest thing to happen.
            if lastAnswerSeq > afterSeq {
                trace("dropped a late answer for seq \(afterSeq); seq \(lastAnswerSeq) is newer")
                return
            }
            var published = suggestion
            // The prompts have said "never invent employers, dates, numbers or
            // systems the user has not mentioned" from the beginning, and a real
            // call produced "I hold a degree in Computer Science" anyway. A
            // sentence the user is about to say out loud to an interviewer needs
            // something more mechanical than an instruction behind it.
            let verdict = ClaimGuard.check(
                headline: published.headline,
                angles: published.angles,
                against: claimEvidence.adding(recalled))
            if !verdict.isGrounded {
                ungroundedSuggestions += 1
                advisorLog.notice(
                    "withheld an unsupported claim after seq \(afterSeq, privacy: .public): \(verdict.unsupported.joined(separator: ", "), privacy: .public)")
                trace("UNGROUNDED after seq \(afterSeq): \(verdict.unsupported.joined(separator: ", "))")
                // The angles survive. They are fragments of direction — "name the
                // bottleneck", "give the result first" — and are worth keeping
                // even when the sentence built on them was not earned. What is
                // dropped is the part that reads as ready to speak.
                published.headline = ""
                published.confirm = []
            }
            published.summary = ledger.panelSummary()
            published.openQuestions = ledger.openQuestions
            lastSuggestion = published
            lastAnswerSeq = afterSeq
            lastAnswerWasToAQuestion = asked
            onSuggestion?(published, .local)
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

        // The closing pass gets its own system prompt rather than the live
        // pointer's: it is writing notes to be read weeks later, not a sentence
        // to be said in two seconds, and the length and shape rules for those are
        // opposites. It was inheriting the pointer's block, which is part of why
        // its output never looked like notes.
        let request = IntelligenceRequest(
            task: CopilotTasks.summary,
            sessionKey: config.callID,
            system: ledgerBlocks(CopilotSummaryPrompt.text),
            input: """
            Here is the account kept during the call:

            \(ledger.closingBrief(with: segmenter.drain(now: audioNow())))
            """,
            tier: .deep,
            exactModel: config.summaryModel
        )
        do {
            let response = try await provider.respond(to: request)
            guard let payload = response.payload else { return nil }
            let closing = try CopilotClosingSummary.decode(payload)
            // Kept so the recap can be built from the deep model's own words
            // rather than from the fast lane's running account.
            if !closing.overview.isEmpty { self.closingSummary = closing }
            advisorLog.notice(
                "closing summary in \(response.attribution.latency, format: .fixed(precision: 1), privacy: .public)s via \(response.attribution.model, privacy: .public)")
            // Still published as a frame so the panel shows the closing account,
            // which is what it has always done.
            return CopilotFrame.Suggestion(
                callID: config.callID,
                afterSeq: turnsSeen,
                headline: "",
                angles: [],
                confirm: [],
                summary: closing.overview,
                openQuestions: closing.openQuestions,
                latencyMs: Int((response.attribution.latency * 1000).rounded()))
        } catch {
            advisorLog.error("summary pass failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The end-of-call pass's result, once it has one.
    public private(set) var closingSummary: CopilotClosingSummary?

    public func shutdown() async {
        await provider.closeSession(briefSessionKey)
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
