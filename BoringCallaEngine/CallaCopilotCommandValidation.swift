import Foundation

/// Validation for owner-issued call-copilot commands.
///
/// Pure and dependency-free on purpose, like its course-command sibling: it
/// compiles into the SPM validation target so every rule here is unit-tested
/// without launching an XPC service. Everything a command carries ends up
/// either naming a process to spawn or riding into a model prompt, so each
/// field is checked against an allowlist rather than sanitised.
public enum CallaCopilotCommandValidation {
    /// Commands the notch may send. Anything else is refused outright.
    public static let allowedActions: Set<String> = [
        "start", "stop", "answer", "set_persona", "set_provider", "archive", "fetch_model", "login",
        // The two-minute pre-roll: warm everything, record nothing. `release`
        // promotes a prewarmed host to a recording one; `stop` cancels it.
        "prewarm", "release",
        // A rehearsal of the sign-in against a throwaway HOME, so the flow can be
        // watched without signing out.
        "test_login",
        // Clearing credentials, and putting them back. Both name a file this
        // service owns; neither takes a path from the caller.
        "sign_out", "restore_login",
    ]

    /// Which brain answers a call.
    ///
    /// `local` runs the Antigravity CLI on this Mac and needs no gateway;
    /// `gateway` is the remote OpenClaw host. Two values, both of which name a
    /// code path in this repository — never a host, a URL, or a binary, so there
    /// is nothing here to steer.
    public static let allowedProviders: Set<String> = ["local", "gateway"]

    /// Model tiers the local provider's fast path can ask for.
    ///
    /// Tiers rather than model names because `agy agentapi` — the only transport
    /// fast enough for a live call — accepts `flash_lite | flash | pro` and
    /// nothing finer. `IntelligenceCore.ModelTier` holds the same three cases and
    /// `ModelCatalog.agy` maps them onto tokens; these must stay in step.
    public static let allowedTiers: Set<String> = ["fast", "balanced", "deep"]

    /// Exact model ids allowed for the unhurried end-of-call pass, which runs
    /// through the print transport and therefore *can* name a model.
    ///
    /// Deliberately no `flash` entry: this pass exists to be better than the live
    /// tier, and deliberately no free-form value, because it becomes an argument
    /// to a spawned process.
    public static let allowedSummaryModels: Set<String> = [
        "gemini-3.1-pro-high", "claude-sonnet-4-6",
    ]

    /// Personas the gateway flow knows. Kept in lockstep with `PERSONAS` in
    /// `apps/call-copilot/integrations/openclaw/src/protocol.mjs`; a value the
    /// gateway would reject should never leave this machine.
    public static let allowedPersonas: Set<String> = ["generic", "interview", "sales", "support"]

    /// Live transcription models the host may be asked to run.
    ///
    /// The archive model is deliberately absent: it carries a CoreML encoder,
    /// which forces whisper's full 30s context per utterance and would make the
    /// live leg unusable.
    public static let allowedLiveModels: Set<String> = ["whisper-small-en", "whisper-base-en"]

    private static let callIDPattern = try? NSRegularExpression(pattern: "^call-[A-Za-z0-9-]{8,72}$")

    public static func action(_ value: String?) -> String? {
        guard let value = trimmed(value), allowedActions.contains(value) else { return nil }
        return value
    }

    public static func provider(_ value: String?) -> String? {
        guard let value = trimmed(value)?.lowercased(), allowedProviders.contains(value) else { return nil }
        return value
    }

    public static func tier(_ value: String?) -> String? {
        guard let value = trimmed(value)?.lowercased(), allowedTiers.contains(value) else { return nil }
        return value
    }

    /// When the gateway socket opens on a call the local brain is answering.
    ///
    /// Three values, all of which name a code path here — never a host or a URL.
    /// Rejecting an unknown one leaves the stored preference alone, which is the
    /// same rule every other field on this command follows.
    public static let allowedGatewayStandby: Set<String> = ["off", "on-failure", "warm"]

    /// Returns the validated spelling rather than the contract's enum: this file
    /// compiles into a dependency-free SPM target so every rule is unit-tested
    /// without an XPC service, and importing the contract would end that.
    public static func gatewayStandby(_ value: String?) -> String? {
        guard let value = trimmed(value)?.lowercased(),
              allowedGatewayStandby.contains(value) else { return nil }
        return value
    }

    public static func summaryModel(_ value: String?) -> String? {
        guard let value = trimmed(value), allowedSummaryModels.contains(value) else { return nil }
        return value
    }

    public static func persona(_ value: String?) -> String? {
        guard let value = trimmed(value)?.lowercased() else { return nil }
        if allowedPersonas.contains(value) { return value }
        // A user-defined persona is still an identifier, so it stays
        // allowlist-*shaped* even though it is not on a fixed list: an id can
        // end up naming a file or a session key, which a paragraph cannot.
        guard value.range(of: "^[a-z0-9-]{1,24}$", options: .regularExpression) != nil else { return nil }
        return value
    }

    /// The one place free text is accepted, and the rules that make that safe.
    ///
    /// The rest of this file allowlists, because the rest of a command names a
    /// process or a route. Prompt text cannot be allowlisted — the whole point
    /// is that the user writes it — so the guarantee moves: bounded length,
    /// no control characters, and the caller hands it to the host on **stdin**
    /// rather than as an argument, so it never becomes part of a command line.
    /// Over-length is refused rather than truncated: a silently shortened
    /// prompt is a different prompt than the one Settings shows.
    public static func profile(about: String?,
                               personaGuidance: String?,
                               baseGuidance: String?,
                               knowledge: String? = nil,
                               meeting: MeetingFields? = nil) -> ProfileFields? {
        guard case .accepted(let about) = promptText(about, limit: aboutLimit),
              case .accepted(let persona) = promptText(personaGuidance, limit: personaGuidanceLimit),
              case .accepted(let base) = promptText(baseGuidance, limit: baseGuidanceLimit),
              case .accepted(let knowledge) = promptText(knowledge, limit: knowledgeLimit)
        else { return nil }

        if about == nil, persona == nil, base == nil, knowledge == nil, meeting == nil { return nil }
        return ProfileFields(about: about, personaGuidance: persona, baseGuidance: base,
                             knowledge: knowledge, meeting: meeting)
    }

    public static let aboutLimit = 1200
    /// User-selected transcript text sent for an explicit live answer.
    public static let manualQuestionLimit = 1200
    public static let personaGuidanceLimit = 2000
    public static let baseGuidanceLimit = 8000
    /// Larger than the rest because it is assembled from several notes plus a
    /// previous call's account, and the engine composes it from the store rather
    /// than taking it from a text field the user typed.
    public static let knowledgeLimit = 8000
    /// A whole attached file's extracted text.
    ///
    /// Far larger than `knowledgeLimit`, and for a different reason: a document is
    /// never packed into a prompt whole. It is chunked and searched, so what this
    /// bounds is how much of a file the store will accept, not how much of it a
    /// model will read. Matches the reader's own ceiling on the app side.
    public static let documentLimit = 2_000_000
    public static let meetingTitleLimit = 200
    public static let meetingNotesLimit = 4000
    /// Long enough for a real invite, short enough that an attendee list cannot
    /// become the whole prompt.
    public static let meetingAttendeeLimit = 120
    public static let meetingAttendeeCount = 40

    /// Whether an event identifier is shaped like one.
    ///
    /// EventKit's `calendarItemIdentifier` and `calendarItemExternalIdentifier`
    /// are opaque, so this cannot be an allowlist. It is still checked rather than
    /// passed through: the id is stored, joined on, and shown in Settings, and a
    /// newline or a control character in it would corrupt every one of those.
    /// How a document was read. An allowlist, because it selects an icon and a
    /// label and there is no reason for it to be free text.
    public static let allowedDocumentKinds: Set<String> = ["pdf", "rich", "text", "image"]

    public static func documentKind(_ value: String?) -> String? {
        guard let value = trimmed(value)?.lowercased(),
              allowedDocumentKinds.contains(value) else { return nil }
        return value
    }

    public static func eventIdentifier(_ value: String?) -> String? {
        guard let value = trimmed(value), value.count <= 256 else { return nil }
        let forbidden = value.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control
        }
        return forbidden ? nil : value
    }

    /// The calendar event a call belongs to.
    ///
    /// Every text field here came out of someone else's calendar invite — an
    /// attacker-controlled string as far as this process is concerned — and all of
    /// it ends up in a model prompt. Same rules as the rest of the profile:
    /// bounded, no control characters, refused rather than truncated, and it
    /// travels on stdin so none of it can become a command-line argument.
    public static func meeting(eventID: String?,
                               seriesID: String?,
                               title: String?,
                               startsAt: Double?,
                               endsAt: Double?,
                               location: String?,
                               attendees: [String]?,
                               notes: String?) -> MeetingFields? {
        guard case .accepted(let title) = promptText(title, limit: meetingTitleLimit),
              case .accepted(let location) = promptText(location, limit: meetingTitleLimit),
              case .accepted(let notes) = promptText(notes, limit: meetingNotesLimit)
        else { return nil }

        var cleanedAttendees: [String] = []
        for attendee in (attendees ?? []).prefix(meetingAttendeeCount) {
            guard case .accepted(let value) = promptText(attendee, limit: meetingAttendeeLimit) else {
                return nil
            }
            if let value { cleanedAttendees.append(value) }
        }

        let event = eventIdentifier(eventID)
        let series = eventIdentifier(seriesID)
        // An identifier that was sent and rejected is a refusal, not an absence —
        // the same distinction `PromptResult` draws for prompt text. Letting it
        // through as nil would file the call's summary under nothing.
        if eventID != nil, event == nil { return nil }
        if seriesID != nil, series == nil { return nil }

        let fields = MeetingFields(
            eventID: event, seriesID: series, title: title,
            startsAt: startsAt, endsAt: endsAt, location: location,
            attendees: cleanedAttendees, notes: notes)
        return fields.isEmpty ? nil : fields
    }

    /// A validated prompt payload. Codable so the engine can hand it straight to
    /// the host without a second hand-mirrored struct.
    public struct ProfileFields: Codable, Equatable {
        public let about: String?
        public let personaGuidance: String?
        public let baseGuidance: String?
        public let knowledge: String?
        public let meeting: MeetingFields?

        enum CodingKeys: String, CodingKey {
            case about, knowledge, meeting
            case personaGuidance = "persona_guidance"
            case baseGuidance = "base_guidance"
        }

        public init(about: String?,
                    personaGuidance: String?,
                    baseGuidance: String?,
                    knowledge: String? = nil,
                    meeting: MeetingFields? = nil) {
            self.about = about
            self.personaGuidance = personaGuidance
            self.baseGuidance = baseGuidance
            self.knowledge = knowledge
            self.meeting = meeting
        }
    }

    /// The wire shape of a meeting, mirroring `IntelligenceStore.MeetingContext`.
    ///
    /// Hand-mirrored rather than shared because this file is deliberately pure and
    /// dependency-free — it compiles into the validation test target without a
    /// package graph, which is what lets every rule above be unit-tested without
    /// launching an XPC service. Dates are epoch seconds for the same reason the
    /// store encodes them that way: no decoder strategy to keep in step.
    public struct MeetingFields: Codable, Equatable {
        public let eventID: String?
        public let seriesID: String?
        public let title: String?
        public let startsAt: Double?
        public let endsAt: Double?
        public let location: String?
        public let attendees: [String]
        public let notes: String?

        enum CodingKeys: String, CodingKey {
            case title, location, attendees, notes
            case eventID = "event_id"
            case seriesID = "series_id"
            case startsAt = "starts_at"
            case endsAt = "ends_at"
        }

        public init(eventID: String?, seriesID: String?, title: String?,
                    startsAt: Double?, endsAt: Double?, location: String?,
                    attendees: [String], notes: String?) {
            self.eventID = eventID
            self.seriesID = seriesID
            self.title = title
            self.startsAt = startsAt
            self.endsAt = endsAt
            self.location = location
            self.attendees = attendees
            self.notes = notes
        }

        public var isEmpty: Bool {
            eventID == nil && seriesID == nil && title == nil
                && location == nil && notes == nil && attendees.isEmpty
        }
    }

    /// Absent and refused are different answers.
    ///
    /// Collapsing them into one optional would let a rejected paragraph read as
    /// an unset one, and the call would then run on the gateway's default
    /// wording while Settings showed something else.
    public enum PromptResult: Equatable {
        /// Accepted; `nil` payload means the field was simply not set.
        case accepted(String?)
        case refused
    }

    /// Also used directly by the engine for knowledge notes, which are the same
    /// kind of payload arriving through a different door.
    public static func promptText(_ value: String?, limit: Int) -> PromptResult {
        guard let value else { return .accepted(nil) }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .accepted(nil) }
        guard trimmed.count <= limit else { return .refused }
        // Newline and tab are ordinary in a prompt; everything else in the
        // control range is either a terminal escape or a null, and neither has
        // any business in text that will be rendered and re-serialised.
        let forbidden = trimmed.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control && scalar != "\n" && scalar != "\r" && scalar != "\t"
        }
        guard !forbidden else { return .refused }
        return .accepted(trimmed.replacingOccurrences(of: "\r\n", with: "\n"))
    }

    public static func liveModel(_ value: String?) -> String? {
        guard let value = trimmed(value), allowedLiveModels.contains(value) else { return nil }
        return value
    }

    public static func callID(_ value: String?) -> String? {
        guard let value = trimmed(value), let callIDPattern else { return nil }
        let range = NSRange(value.startIndex..., in: value)
        guard callIDPattern.firstMatch(in: value, range: range) != nil else { return nil }
        return value
    }

    /// The gateway route the host is allowed to reach.
    ///
    /// Restricted to `wss:` on the Boring-owned Tailscale host. The transcript
    /// of a live call is the most sensitive thing this feature touches, and a
    /// command carrying an arbitrary URL would be enough to send it anywhere.
    public static func gatewayURL(_ value: String?) -> URL? {
        guard let value = trimmed(value),
              let url = URL(string: value),
              url.scheme == "wss",
              url.host == "nomonhomelab.tailec0dca.ts.net",
              url.path == "/call-copilot/stream"
        else { return nil }
        return url
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
