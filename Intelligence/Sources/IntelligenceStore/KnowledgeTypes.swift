import Foundation

/// Why a note exists, which decides whether a human may edit it.
///
/// `eventField` and `callSummary` notes are derived — regenerated from the
/// calendar or from a finished call — so the UI shows them read-only. Editing one
/// would be undone the next time its source is re-read, and a setting that
/// silently reverts is worse than one that is visibly not editable.
public enum KnowledgeSource: String, Codable, Sendable, CaseIterable {
    /// Typed by the user.
    case manual
    /// A file the user attached — a PDF, a deck, a page of notes.
    case document
    /// Derived from an event's own title, notes, location and attendees.
    case eventField = "event_field"
    /// The account a finished call left behind.
    case callSummary = "call_summary"

    /// Whether this note's whole body belongs in the prompt at call start.
    ///
    /// Typed notes and a previous call's account are short and certain, so they
    /// go in whole. A document does not: it can be forty pages, and packing it
    /// would spend the entire block on one attachment and starve everything else.
    /// Documents reach the model through retrieval instead — searched per
    /// question, three passages at a time — with only a one-line mention up front
    /// so the copilot knows the file exists and can be asked about it.
    public var isPacked: Bool { self != .document }
}

/// What a note is attached to, and therefore when it is retrieved.
public enum KnowledgeScope: Equatable, Sendable {
    /// Every call, whatever it is about.
    case always
    /// One occurrence — `EventModel.id`, which is `calendarItemIdentifier`.
    case event(String)
    /// Every occurrence of a recurring meeting — `calendarItemExternalIdentifier`.
    ///
    /// The distinction is the whole reason a series id had to be plumbed through:
    /// `EventModel.id` differs per occurrence, so a note attached to it would be
    /// lost by next week's instance of the same standup.
    case series(String)
    /// Every call run with one persona.
    case persona(String)

    var kind: String {
        switch self {
        case .always: "always"
        case .event: "event"
        case .series: "series"
        case .persona: "persona"
        }
    }

    var key: String? {
        switch self {
        case .always: nil
        case let .event(id), let .series(id), let .persona(id): id
        }
    }

    init?(kind: String, key: String?) {
        switch kind {
        case "always": self = .always
        case "event": guard let key else { return nil }; self = .event(key)
        case "series": guard let key else { return nil }; self = .series(key)
        case "persona": guard let key else { return nil }; self = .persona(key)
        default: return nil
        }
    }
}

/// One thing the user (or a finished call) wants the copilot to know.
public struct KnowledgeNote: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var body: String
    public var source: KnowledgeSource
    public var scope: KnowledgeScope
    public var createdAt: Date
    public var updatedAt: Date

    /// The file this came from, for a document. `contract.pdf`.
    public var originName: String?
    /// How it was read: `pdf`, `text`, `rich`, `image`. Shown in the UI, and the
    /// reason an image-only PDF can be labelled as having been read by OCR.
    public var originKind: String?
    /// Size of the original file, not of the extracted text.
    public var byteSize: Int
    /// Pages for a PDF, zero for everything else.
    public var pageCount: Int

    public var isEditable: Bool { source == .manual }
    public var isDocument: Bool { source == .document }

    public init(
        id: String = "note-" + UUID().uuidString.prefix(16).lowercased(),
        title: String,
        body: String,
        source: KnowledgeSource = .manual,
        scope: KnowledgeScope = .always,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        originName: String? = nil,
        originKind: String? = nil,
        byteSize: Int = 0,
        pageCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.source = source
        self.scope = scope
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.originName = originName
        self.originKind = originKind
        self.byteSize = byteSize
        self.pageCount = pageCount
    }

    /// The one line a document contributes to the prompt at call start.
    ///
    /// Not the document itself — see `KnowledgeSource.isPacked`. Naming the file
    /// is what makes it askable: a copilot told "the signed MSA is attached" will
    /// answer "let me check the MSA" and the next question retrieves the passage,
    /// whereas one told nothing behaves as though the file does not exist.
    public var manifestLine: String? {
        guard isDocument else { return nil }
        let name = originName ?? title
        var detail: [String] = []
        if pageCount > 0 { detail.append("\(pageCount) page\(pageCount == 1 ? "" : "s")") }
        detail.append("searchable")
        return "\(name) (\(detail.joined(separator: ", ")))"
    }

    // Codable by hand: `KnowledgeScope` is an enum with payloads, and the derived
    // encoding for one of those is a nested object that neither the XPC hop nor a
    // human reading the JSON would thank us for.
    enum CodingKeys: String, CodingKey {
        case id, title, body, source
        case scope, scopeKey = "scope_key"
        case createdAt = "created_at", updatedAt = "updated_at"
        case originName = "origin_name", originKind = "origin_kind"
        case byteSize = "byte_size", pageCount = "page_count"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        source = try container.decodeIfPresent(KnowledgeSource.self, forKey: .source) ?? .manual
        let kind = try container.decodeIfPresent(String.self, forKey: .scope) ?? "always"
        let key = try container.decodeIfPresent(String.self, forKey: .scopeKey)
        scope = KnowledgeScope(kind: kind, key: key) ?? .always
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        originName = try container.decodeIfPresent(String.self, forKey: .originName)
        originKind = try container.decodeIfPresent(String.self, forKey: .originKind)
        byteSize = try container.decodeIfPresent(Int.self, forKey: .byteSize) ?? 0
        pageCount = try container.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encode(source, forKey: .source)
        try container.encode(scope.kind, forKey: .scope)
        try container.encodeIfPresent(scope.key, forKey: .scopeKey)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(originName, forKey: .originName)
        try container.encodeIfPresent(originKind, forKey: .originKind)
        try container.encode(byteSize, forKey: .byteSize)
        try container.encode(pageCount, forKey: .pageCount)
    }
}

/// A retrieved fragment, with enough provenance to be rendered as a citation.
public struct KnowledgeHit: Sendable, Equatable {
    public let noteID: String
    public let title: String
    public let text: String
    public let source: KnowledgeSource
    /// Fused rank score. Comparable within one search, meaningless across two.
    public let score: Double

    public init(noteID: String, title: String, text: String, source: KnowledgeSource, score: Double) {
        self.noteID = noteID
        self.title = title
        self.text = text
        self.source = source
        self.score = score
    }
}

/// The meeting a call belongs to. Carried from the app, through the engine, to
/// the host — and stored on the call row so history can link back to the event.
public struct MeetingContext: Codable, Sendable, Equatable {
    /// `EventModel.id` — this occurrence.
    public var eventID: String?
    /// `calendarItemExternalIdentifier` — the recurring series.
    public var seriesID: String?
    public var title: String?
    public var startsAt: Date?
    public var endsAt: Date?
    public var location: String?
    public var attendees: [String]
    /// The event's own notes field.
    public var notes: String?

    enum CodingKeys: String, CodingKey {
        case title, location, attendees, notes
        case eventID = "event_id"
        case seriesID = "series_id"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
    }

    public init(
        eventID: String? = nil,
        seriesID: String? = nil,
        title: String? = nil,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        location: String? = nil,
        attendees: [String] = [],
        notes: String? = nil
    ) {
        self.eventID = eventID
        self.seriesID = seriesID
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.location = location
        self.attendees = attendees
        self.notes = notes
    }

    // Dates are encoded as epoch seconds by hand rather than left to the
    // encoder's strategy. This type crosses three processes — the sandboxed app,
    // the XPC engine, and the call host — and the host's profile decoder is a
    // plain `JSONDecoder()` while everything else it writes uses `.iso8601`. A
    // wire format that depends on two hand-mirrored decoders agreeing about a
    // strategy is a bug waiting for the first person who adds a third caller.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventID = try container.decodeIfPresent(String.self, forKey: .eventID)
        seriesID = try container.decodeIfPresent(String.self, forKey: .seriesID)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        startsAt = try container.decodeIfPresent(Double.self, forKey: .startsAt)
            .map(Date.init(timeIntervalSince1970:))
        endsAt = try container.decodeIfPresent(Double.self, forKey: .endsAt)
            .map(Date.init(timeIntervalSince1970:))
        location = try container.decodeIfPresent(String.self, forKey: .location)
        attendees = try container.decodeIfPresent([String].self, forKey: .attendees) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(eventID, forKey: .eventID)
        try container.encodeIfPresent(seriesID, forKey: .seriesID)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(startsAt?.timeIntervalSince1970, forKey: .startsAt)
        try container.encodeIfPresent(endsAt?.timeIntervalSince1970, forKey: .endsAt)
        try container.encodeIfPresent(location, forKey: .location)
        if !attendees.isEmpty { try container.encode(attendees, forKey: .attendees) }
        try container.encodeIfPresent(notes, forKey: .notes)
    }

    public var isEmpty: Bool {
        eventID == nil && seriesID == nil
            && (title?.isEmpty ?? true)
            && attendees.isEmpty
            && (notes?.isEmpty ?? true)
            && (location?.isEmpty ?? true)
    }

    /// The scopes a call in this meeting should retrieve from, most specific
    /// first. `always` is included at every call, which is what makes it "always".
    public func scopes(persona: String?) -> [KnowledgeScope] {
        var scopes: [KnowledgeScope] = [.always]
        if let persona, !persona.isEmpty { scopes.append(.persona(persona)) }
        if let seriesID, !seriesID.isEmpty { scopes.append(.series(seriesID)) }
        if let eventID, !eventID.isEmpty { scopes.append(.event(eventID)) }
        return scopes
    }

    /// The event's own fields as a note body. Free context: the calendar already
    /// holds it, and a title plus an attendee list is often the only thing that
    /// tells the copilot what kind of call it is about to sit in.
    public func derivedNoteBody() -> String? {
        var lines: [String] = []
        if let title, !title.isEmpty { lines.append("Meeting: \(title)") }
        if let startsAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            lines.append("When: \(formatter.string(from: startsAt))")
        }
        if let location, !location.isEmpty { lines.append("Where: \(location)") }
        if !attendees.isEmpty { lines.append("Attendees: \(attendees.joined(separator: ", "))") }
        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Invite notes:\n\(notes)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
