import Foundation

/// Versioned, bounded wire contract shared by Calla host, engine, and clients.
/// New fields must be optional or receive defaults until every shipped host has
/// crossed this version.
public enum CallaContract {
    public static let version = 2
}

public enum CallLifecycleState: String, Codable, Sendable, CaseIterable {
    /// The host process exists and is paying its fixed costs. Written before the
    /// model is loaded and before either microphone is open, so the notch can say
    /// "starting" the moment the process is alive rather than after everything is
    /// ready — the gap between those two used to look like a dead button.
    case starting
    case prewarming, ready, capturing, stopping, processingRecap, finished, failed
}

/// Which fixed cost the host is paying right now, for a UI that would otherwise
/// show an unmoving spinner.
///
/// Deliberately a closed enum rather than free text: it is drawn as a checklist,
/// and a stage the panel does not recognise would render as a blank row.
public enum CallStartupStage: String, Codable, Sendable, CaseIterable {
    case launching
    case permissions
    case model
    case capture
    /// Capture is live. The brain may still be warming; `CallStartupProgress`
    /// carries that separately because it never blocks recording.
    case listening
}

/// What the host has finished, for the live panel's startup checklist.
///
/// Every field is "has this landed", never "is this required" — a call runs with
/// a cold brain and no gateway, and the panel has to be able to say so without
/// implying something is broken.
public struct CallStartupProgress: Codable, Sendable, Equatable {
    public var stage: CallStartupStage
    public var modelLoaded: Bool
    public var brainWarm: Bool
    /// Nil when the gateway is not part of this call at all — standby off, or
    /// a purely local call that has not failed over.
    public var gatewayWarm: Bool?

    public init(
        stage: CallStartupStage = .launching,
        modelLoaded: Bool = false,
        brainWarm: Bool = false,
        gatewayWarm: Bool? = nil
    ) {
        self.stage = stage
        self.modelLoaded = modelLoaded
        self.brainWarm = brainWarm
        self.gatewayWarm = gatewayWarm
    }
}

public struct CallCaptureHealth: Codable, Sendable, Equatable {
    public var microphone: Bool
    public var systemAudio: Bool
    public var detail: String?

    public init(microphone: Bool, systemAudio: Bool, detail: String? = nil) {
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.detail = detail
    }
}

public struct CallLifecycleSnapshot: Codable, Sendable, Equatable {
    public var contractVersion: Int
    public var callID: String
    public var generation: Int
    public var state: CallLifecycleState
    public var updatedAt: Date
    public var actionableError: String?
    public var capture: CallCaptureHealth
    public var provider: String?
    /// 0...1 while `processingRecap`; nil otherwise.
    public var recapProgress: Double?
    /// What the host is still paying for. Optional because it is only meaningful
    /// on the way up — a capturing call has nothing left to report — and because
    /// a host older than this field must still decode.
    public var startup: CallStartupProgress?

    public init(
        callID: String,
        generation: Int,
        state: CallLifecycleState,
        updatedAt: Date = Date(),
        actionableError: String? = nil,
        capture: CallCaptureHealth = .init(microphone: false, systemAudio: false),
        provider: String? = nil,
        recapProgress: Double? = nil,
        startup: CallStartupProgress? = nil,
        contractVersion: Int = CallaContract.version
    ) {
        self.contractVersion = contractVersion
        self.callID = callID
        self.generation = generation
        self.state = state
        self.updatedAt = updatedAt
        self.actionableError = actionableError
        self.capture = capture
        self.provider = provider
        self.recapProgress = recapProgress.map { min(1, max(0, $0)) }
        self.startup = startup
    }

    public func accepts(_ event: CallHostEvent) -> Bool {
        event.callID == callID && event.generation == generation && event.contractVersion == contractVersion
    }
}

public enum CallHostCommandKind: String, Codable, Sendable {
    case start, release, stop, snapshot, answer
}

public struct CallHostCommand: Codable, Sendable, Equatable {
    public var contractVersion: Int
    public var callID: String
    public var generation: Int
    public var kind: CallHostCommandKind
    /// Bounded selected transcript/manual text for `answer`; nil otherwise.
    public var text: String?

    public init(callID: String, generation: Int, kind: CallHostCommandKind,
                text: String? = nil, contractVersion: Int = CallaContract.version) {
        self.contractVersion = contractVersion; self.callID = callID
        self.generation = generation; self.kind = kind; self.text = text
    }
}

public enum CallHostEventKind: String, Codable, Sendable {
    case ready, captureState, answer, recapProgress, finished, fatal
}

public struct CallHostEvent: Codable, Sendable, Equatable {
    public var contractVersion: Int
    public var callID: String
    public var generation: Int
    public var kind: CallHostEventKind
    public var snapshot: CallLifecycleSnapshot

    public init(callID: String, generation: Int, kind: CallHostEventKind,
                snapshot: CallLifecycleSnapshot, contractVersion: Int = CallaContract.version) {
        self.contractVersion = contractVersion; self.callID = callID
        self.generation = generation; self.kind = kind; self.snapshot = snapshot
    }
}

public enum CallQuestionKind: String, Codable, Sendable { case direct, imperative, manual }
public enum CallQuestionState: String, Codable, Sendable { case queued, answering, answered, superseded, dismissed }

public struct CallQuestion: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var fromSeq: Int
    public var toSeq: Int
    public var prompt: String
    public var kind: CallQuestionKind
    public var confidence: Double
    public var state: CallQuestionState
    public var answerID: String?
    public var supersessionReason: String?

    public init(id: UUID = UUID(), fromSeq: Int, toSeq: Int, prompt: String, kind: CallQuestionKind,
                confidence: Double, state: CallQuestionState = .queued, answerID: String? = nil,
                supersessionReason: String? = nil) {
        self.id = id; self.fromSeq = fromSeq; self.toSeq = toSeq; self.prompt = prompt
        self.kind = kind; self.confidence = min(1, max(0, confidence)); self.state = state
        self.answerID = answerID; self.supersessionReason = supersessionReason
    }
}

/// Ordered queue. Only explicitly marked continuation turns may supersede an
/// unanswered question; unrelated questions always remain in order.
public struct CallQuestionQueue: Sendable, Equatable {
    public private(set) var questions: [CallQuestion] = []

    public init() {}

    public mutating func enqueue(_ question: CallQuestion, continuing: Bool = false) {
        if continuing, let index = questions.lastIndex(where: { $0.state == .queued }) {
            questions[index].state = .superseded
            questions[index].supersessionReason = "continued by \(question.id.uuidString)"
        }
        questions.append(question)
    }

    public mutating func beginNext() -> CallQuestion? {
        guard let index = questions.firstIndex(where: { $0.state == .queued }) else { return nil }
        questions[index].state = .answering
        return questions[index]
    }

    public mutating func answer(_ id: UUID, answerID: String) {
        guard let index = questions.firstIndex(where: { $0.id == id && $0.state == .answering }) else { return }
        questions[index].state = .answered; questions[index].answerID = answerID
    }

    public mutating func dismiss(_ id: UUID) {
        guard let index = questions.firstIndex(where: { $0.id == id && [.queued, .answering].contains($0.state) }) else { return }
        questions[index].state = .dismissed
    }
}

public struct CallSummaryTrigger: Sendable, Equatable {
    public static let maximumInterval: TimeInterval = 60
    public static let quietInterval: TimeInterval = 20
    public var statementsSinceSummary = 0
    public var lastSummaryAt: Date
    public var lastStatementAt: Date?

    public init(now: Date = Date()) { lastSummaryAt = now }

    public mutating func recordStatement(at date: Date = Date()) { statementsSinceSummary += 1; lastStatementAt = date }
    public mutating func didSummarize(at date: Date = Date()) { statementsSinceSummary = 0; lastSummaryAt = date }

    public func isDue(now: Date = Date(), commitmentOrDecision: Bool, answerInFlight: Bool) -> Bool {
        guard !answerInFlight, statementsSinceSummary > 0 else { return false }
        if commitmentOrDecision || statementsSinceSummary >= 3 { return true }
        if now.timeIntervalSince(lastSummaryAt) >= Self.maximumInterval { return true }
        return lastStatementAt.map { now.timeIntervalSince($0) >= Self.quietInterval } ?? false
    }
}

public struct SourcedCallItem: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case decision, commitment, actionItem, openQuestion }
    public var id: String
    public var kind: Kind
    public var text: String
    public var fromSeq: Int
    public var toSeq: Int
    public var resolved: Bool

    public init(id: String, kind: Kind, text: String, fromSeq: Int, toSeq: Int, resolved: Bool = false) {
        self.id = id; self.kind = kind; self.text = text; self.fromSeq = fromSeq; self.toSeq = toSeq; self.resolved = resolved
    }
}

public struct CallRecapDraft: Codable, Sendable, Equatable, Identifiable {
    public enum ReviewState: String, Codable, Sendable { case pending, approved, rejected }
    public var id: String { callID }
    public var callID: String
    public var overview: String
    public var items: [SourcedCallItem]
    public var provider: String?
    public var model: String?
    public var failure: String?
    public var reviewState: ReviewState

    public init(callID: String, overview: String, items: [SourcedCallItem], provider: String? = nil,
                model: String? = nil, failure: String? = nil, reviewState: ReviewState = .pending) {
        self.callID = callID; self.overview = overview; self.items = items; self.provider = provider
        self.model = model; self.failure = failure; self.reviewState = reviewState
    }
}

/// When the gateway websocket is opened on a call the local brain is answering.
///
/// Was not a choice at all: the socket connected on every call and received every
/// turn, whether or not the gateway was allowed to answer, and `start()` awaited
/// its handshake before opening either microphone. That cost ~1s of startup for
/// something usually discarded, and shipped the transcript off the Mac even with
/// fallback switched off.
///
/// None of these modes ever block capture — the difference is only *when* the
/// connection is made, and therefore what the gateway knows if it has to take over.
public enum GatewayStandby: String, Codable, Sendable, CaseIterable {
    /// Never opened. Nothing about the call leaves this Mac. A local brain that
    /// fails simply reports the failure — there is nowhere to hand over to.
    case off
    /// Opened only if the local brain gives up, then backfilled with the recent
    /// transcript so the handover is not starting blind. Costs a handshake at the
    /// moment of failure, which is the trade for a call that stays local while it
    /// is going well.
    case onFailure
    /// Opened in the background as the call starts and fed every turn, so a
    /// handover is instant and complete. The default, and what the code did
    /// before this was a setting — minus the blocking.
    case warm

    /// Tolerates the hyphenated spelling as well as the camel-cased raw value.
    ///
    /// The raw value is what goes in JSON and in `UserDefaults`; `on-failure` is
    /// what reads correctly on a command line. Accepting both here means the two
    /// can never drift into a mode that silently resolves to the default.
    public static func named(_ raw: String?) -> GatewayStandby? {
        guard let raw else { return nil }
        switch raw {
        case "off": return .off
        case "on-failure", "onFailure": return .onFailure
        case "warm": return .warm
        default: return nil
        }
    }

    /// The spelling used on the host's command line.
    public var argument: String { self == .onFailure ? "on-failure" : rawValue }
}
