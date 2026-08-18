import Foundation

/// One thing the copilot has been told, as it crosses the XPC boundary.
///
/// Deliberately a flat mirror of the store's `KnowledgeNote` rather than a shared
/// type: this app is sandboxed and does not link the store at all — it cannot,
/// because the database lives outside its container — so the shape is
/// hand-mirrored the same way `CallaCopilotProfile` and `CallaCallSummary`
/// already are.
struct CallaKnowledgeNote: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var body: String
    /// `manual`, `document`, `event_field` or `call_summary`.
    var source: String
    /// `always`, `event`, `series` or `persona`.
    var scope: String
    /// The event id, series id or persona this note is attached to.
    var scopeKey: String?
    var createdAt: Date
    var updatedAt: Date
    /// The file this was read out of, for a document.
    var originName: String?
    /// How it was read: `pdf`, `rich`, `text`, `image`.
    var originKind: String?
    /// Size of the original file, not of the extracted text.
    var byteSize: Int
    var pageCount: Int

    enum CodingKeys: String, CodingKey {
        case id, title, body, source, scope
        case scopeKey = "scope_key"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case originName = "origin_name"
        case originKind = "origin_kind"
        case byteSize = "byte_size"
        case pageCount = "page_count"
    }

    init(
        id: String,
        title: String,
        body: String,
        source: String,
        scope: String,
        scopeKey: String? = nil,
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
        self.scopeKey = scopeKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.originName = originName
        self.originKind = originKind
        self.byteSize = byteSize
        self.pageCount = pageCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? "always"
        scopeKey = try container.decodeIfPresent(String.self, forKey: .scopeKey)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        originName = try container.decodeIfPresent(String.self, forKey: .originName)
        originKind = try container.decodeIfPresent(String.self, forKey: .originKind)
        byteSize = try container.decodeIfPresent(Int.self, forKey: .byteSize) ?? 0
        pageCount = try container.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0
    }

    /// Only what the user typed can be edited.
    ///
    /// A document is what was read out of a file, and a note derived from an
    /// invite or a finished call is rebuilt from its source — so an edit to either
    /// would be silently undone. A field that quietly reverts is worse than one
    /// that is visibly read-only.
    var isEditable: Bool { source == "manual" }
    var isDocument: Bool { source == "document" }

    /// SF Symbol for the row. A document should look like the thing it is at a
    /// glance — a scan and a typed note are not the same object.
    var symbol: String {
        switch source {
        case "document":
            switch originKind {
            case "pdf": "doc.richtext.fill"
            case "image": "doc.text.viewfinder"
            case "rich": "doc.plaintext.fill"
            default: "doc.text.fill"
            }
        case "call_summary": "clock.arrow.circlepath"
        case "event_field": "calendar"
        default: "text.quote"
        }
    }

    /// "PDF · 12 pages · 1.2 MB", or a word count for something typed.
    var subtitle: String {
        var parts: [String] = []
        if isDocument {
            switch originKind {
            case "pdf": parts.append("PDF")
            case "image": parts.append("Scanned")
            case "rich": parts.append("Document")
            default: parts.append("Text file")
            }
            if pageCount > 0 { parts.append("\(pageCount) page\(pageCount == 1 ? "" : "s")") }
            if byteSize > 0 {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file))
            }
        } else {
            let words = body.split(whereSeparator: \.isWhitespace).count
            parts.append("\(words) word\(words == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    /// Said in the second person, because that is who is reading it.
    var scopeLabel: String {
        switch scope {
        case "always": "Every call"
        case "event": "This meeting"
        case "series": "This meeting and every repeat"
        case "persona": "Every \(scopeKey ?? "") call"
        default: scope
        }
    }

    var sourceLabel: String {
        switch source {
        case "document": "Attached file"
        case "event_field": "From the invite"
        case "call_summary": "Written after a call"
        default: "Written by you"
        }
    }

    /// Whether the whole thing is put in front of the copilot at the start of a
    /// call, or only searched when a question calls for it.
    ///
    /// Surfaced in the UI because it is the difference people will actually feel:
    /// a typed note shapes every answer, an attached PDF answers the questions
    /// that are about it.
    var isAlwaysInView: Bool { !isDocument }

    static func new(scope: String = "always", scopeKey: String? = nil) -> CallaKnowledgeNote {
        CallaKnowledgeNote(
            id: "note-" + UUID().uuidString.prefix(16).lowercased(),
            title: "", body: "", source: "manual",
            scope: scope, scopeKey: scopeKey)
    }

    /// A note built from a file that has already been read.
    static func document(
        name: String,
        kind: String,
        text: String,
        byteSize: Int,
        pageCount: Int,
        scope: String,
        scopeKey: String?
    ) -> CallaKnowledgeNote {
        CallaKnowledgeNote(
            id: "note-" + UUID().uuidString.prefix(16).lowercased(),
            title: name, body: text, source: "document",
            scope: scope, scopeKey: scopeKey,
            originName: name, originKind: kind,
            byteSize: byteSize, pageCount: pageCount)
    }
}

/// What the app asks the engine to do with the knowledge base.
struct CallaKnowledgeCommand: Codable {
    /// `upsert`, `delete` or `list`.
    var action: String
    var id: String?
    var title: String?
    var body: String?
    var scope: String?
    var scopeKey: String?
    /// For `list`: restrict to one event and its series.
    var eventID: String?
    var seriesID: String?
    /// Set when the note is a file that was read on this side of the boundary.
    var source: String?
    var originName: String?
    var originKind: String?
    var byteSize: Int?
    var pageCount: Int?

    enum CodingKeys: String, CodingKey {
        case action, id, title, body, scope, source
        case scopeKey = "scope_key"
        case eventID = "event_id"
        case seriesID = "series_id"
        case originName = "origin_name"
        case originKind = "origin_kind"
        case byteSize = "byte_size"
        case pageCount = "page_count"
    }
}

/// A call as the store keeps it, linked to the calendar event it was held in.
struct CallaCallRecord: Codable, Equatable, Identifiable {
    var id: String
    var eventID: String?
    var seriesID: String?
    var eventTitle: String?
    var eventStart: Date?
    var persona: String
    var startedAt: Date?
    var endedAt: Date?
    var liveModel: String?
    var provider: String?
    var turnCount: Int

    enum CodingKeys: String, CodingKey {
        case id, persona, provider
        case eventID = "event_id"
        case seriesID = "series_id"
        case eventTitle = "event_title"
        case eventStart = "event_start"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case liveModel = "live_model"
        case turnCount = "turn_count"
    }

    var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }
}
