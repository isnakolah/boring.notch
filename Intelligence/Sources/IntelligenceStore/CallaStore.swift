import Foundation

/// Everything the copilot remembers: what you told it, and what its calls
/// concluded.
///
/// One file, three processes. The call host writes turns and suggestions while a
/// call runs; the XPC engine reads on behalf of the app, which is sandboxed and
/// cannot open the file at all. That constraint is the reason this type exists as
/// a shared package target rather than as private code in either process.
///
/// The path is passed in rather than derived. `IntelligenceCore`'s rule — policy
/// in, never read — is worth keeping one target out: the host knows about
/// `CallHostPaths`, the tests want a temporary directory, and neither belongs
/// here.
public actor CallaStore {
    private let database: SQLiteDatabase
    private let embedder: Embedder

    /// Set once `prepare()` has run. Until then searches are lexical only, which
    /// is correct rather than degraded: the vectors may not exist yet.
    private var embeddingsReady = false

    public init(path: URL, embedder: Embedder = Embedder()) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        database = try SQLiteDatabase(path: path.path)
        self.embedder = embedder
        try Schema.migrate(database)
        // The transcript of a call is the most sensitive thing this app holds, and
        // the file is created by whichever process gets there first.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    /// Loads the embedding backend and brings the index up to date.
    ///
    /// Called from the pre-roll, two minutes before a meeting, because the first
    /// tier may need to fetch its weights and a question is not the moment to find
    /// that out. Everything here is optional work: a store that never has
    /// `prepare()` called still answers every query, lexically.
    public func prepare() async {
        await embedder.prepare()
        let revision = await embedder.revision
        guard revision != "none" else { return }

        // A backend change invalidates every vector in the file. Cosine between
        // two different embedding spaces is not a weak signal, it is noise — so
        // the old vectors are dropped rather than ranked alongside the new ones.
        let stored = try? database.scalarText(
            "SELECT value FROM store_meta WHERE key = 'embedding_revision'")
        if let stored, stored != revision {
            try? database.run("UPDATE knowledge_chunk SET embedding = NULL")
        }
        try? database.run(
            "INSERT INTO store_meta(key, value) VALUES('embedding_revision', ?) " +
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(revision)])

        embeddingsReady = true
        await backfillEmbeddings()
    }

    /// Embeds anything indexed while no backend was loaded. Bounded per call so a
    /// large import cannot stall the pre-roll; the next one picks up the rest.
    private func backfillEmbeddings(limit: Int = 500) async {
        let pending = (try? database.query(
            "SELECT id, text FROM knowledge_chunk WHERE embedding IS NULL LIMIT ?",
            [.int(limit)]) { ($0.int(0), $0.string(1)) }) ?? []
        for (id, text) in pending {
            guard let vector = await embedder.embed(text) else { continue }
            try? database.run(
                "UPDATE knowledge_chunk SET embedding = ? WHERE id = ?",
                [.blob(VectorBlob.encode(vector)), .int(id)])
        }
    }

    // MARK: - Database access for this module

    // `database` stays private so nothing outside the actor can reach the handle,
    // but `CallRecords.swift` is the same type's other half and needs to issue
    // statements. These two are the whole seam.

    func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        try database.run(sql, bindings)
    }

    func query<T>(_ sql: String, _ bindings: [SQLiteValue] = [], row: (SQLiteRow) -> T) throws -> [T] {
        try database.query(sql, bindings, row: row)
    }

    // MARK: - Knowledge

    /// Creates or replaces a note and rebuilds its chunks.
    ///
    /// Chunks are deleted and re-inserted rather than diffed. An edit changes
    /// paragraph boundaries often enough that a diff would rewrite most of them
    /// anyway, and the cascade keeps the FTS index honest through its triggers.
    @discardableResult
    public func upsert(_ note: KnowledgeNote) async throws -> KnowledgeNote {
        var stored = note
        stored.updatedAt = Date()

        try database.transaction {
            try database.run(
                """
                INSERT INTO knowledge_note(id, title, body, source, scope, scope_key,
                                           created_at, updated_at,
                                           origin_name, origin_kind, byte_size, page_count)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  title = excluded.title, body = excluded.body, source = excluded.source,
                  scope = excluded.scope, scope_key = excluded.scope_key,
                  updated_at = excluded.updated_at,
                  origin_name = excluded.origin_name, origin_kind = excluded.origin_kind,
                  byte_size = excluded.byte_size, page_count = excluded.page_count
                """,
                [.text(stored.id), .text(stored.title), .text(stored.body),
                 .text(stored.source.rawValue), .text(stored.scope.kind), .text(stored.scope.key),
                 .date(stored.createdAt), .date(stored.updatedAt),
                 .text(stored.originName), .text(stored.originKind),
                 .int(stored.byteSize), .int(stored.pageCount)])
            try database.run("DELETE FROM knowledge_chunk WHERE note_id = ?", [.text(stored.id)])
        }

        // Embedding is deliberately outside the transaction: it is the slow part,
        // and holding a write lock across an await would block the call host's
        // transcript writes for as long as the model takes.
        let pieces = TextChunker.chunks(of: chunkable(stored))
        for (ordinal, piece) in pieces.enumerated() {
            let vector = embeddingsReady ? await embedder.embed(piece) : nil
            try database.run(
                "INSERT INTO knowledge_chunk(note_id, ord, text, embedding) VALUES(?, ?, ?, ?)",
                [.text(stored.id), .int(ordinal), .text(piece),
                 .blob(vector.map(VectorBlob.encode))])
        }
        return stored
    }

    /// The title is prepended to every chunk before indexing.
    ///
    /// Without it, the second chunk of "Acme account" retrieves on its own words
    /// alone, and a question naming Acme misses the paragraph that never repeats
    /// the name — which is most of them, because people do not restate the subject
    /// of the note they are writing.
    private func chunkable(_ note: KnowledgeNote) -> String {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return body }
        guard !body.isEmpty else { return title }
        return "\(title)\n\n\(body)"
    }

    public func deleteNote(id: String) throws {
        try database.run("DELETE FROM knowledge_note WHERE id = ?", [.text(id)])
    }

    public func notes(in scope: KnowledgeScope? = nil) throws -> [KnowledgeNote] {
        let sql = """
        SELECT id, title, body, source, scope, scope_key, created_at, updated_at,
               origin_name, origin_kind, byte_size, page_count
        FROM knowledge_note
        """
        let ordering = " ORDER BY updated_at DESC"
        if let scope {
            let clause = scope.key == nil
                ? " WHERE scope = ? AND scope_key IS NULL"
                : " WHERE scope = ? AND scope_key = ?"
            var bindings: [SQLiteValue] = [.text(scope.kind)]
            if let key = scope.key { bindings.append(.text(key)) }
            return try database.query(sql + clause + ordering, bindings, row: Self.note)
        }
        return try database.query(sql + ordering, row: Self.note)
    }

    /// Every note that applies to a meeting, most general first.
    ///
    /// Order is load-bearing: this is concatenated into a system prompt, and the
    /// specific thing should be the last thing read.
    public func notes(for meeting: MeetingContext, persona: String?) throws -> [KnowledgeNote] {
        var seen = Set<String>()
        var result: [KnowledgeNote] = []
        for scope in meeting.scopes(persona: persona) {
            for note in try notes(in: scope) where !seen.contains(note.id) {
                seen.insert(note.id)
                result.append(note)
            }
        }
        return result
    }

    /// Everything this meeting should have in front of it at call start.
    ///
    /// Two different treatments, which is the whole point of the split:
    ///
    ///  * a typed note or a previous call's account goes in whole — short, certain,
    ///    and worth having before anyone speaks;
    ///  * an attached document contributes one line naming itself, and nothing
    ///    else. Its text reaches the model through retrieval, three passages at a
    ///    time, when a question actually calls for it.
    ///
    /// Without the manifest line a document may as well not exist: a copilot that
    /// has never been told there is a signed contract attached will not think to
    /// look in one, and retrieval only fires on questions it already relates to.
    ///
    /// Truncated rather than refused when it runs long. A knowledge base that grew
    /// past the ceiling should cost its oldest notes, not the call.
    public func promptBlock(
        for meeting: MeetingContext,
        persona: String?,
        limit: Int
    ) throws -> String? {
        let notes = try notes(for: meeting, persona: persona)
        guard !notes.isEmpty else { return nil }

        var blocks: [String] = []
        var attachments: [String] = []
        var used = 0

        for note in notes {
            guard note.source.isPacked else {
                if let line = note.manifestLine { attachments.append(line) }
                continue
            }
            let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let block = title.isEmpty ? body : (body.isEmpty ? title : "\(title)\n\(body)")
            guard !block.isEmpty else { continue }
            // +2 for the separator this block will be joined with.
            guard used + block.count + 2 <= limit else { continue }
            used += block.count + 2
            blocks.append(block)
        }

        if !attachments.isEmpty {
            blocks.append(
                "Attached and searchable — say you will check these rather than guessing:\n"
                    + attachments.map { "- \($0)" }.joined(separator: "\n"))
        }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }

    private static func note(_ row: SQLiteRow) -> KnowledgeNote {
        KnowledgeNote(
            id: row.string(0),
            title: row.string(1),
            body: row.string(2),
            source: KnowledgeSource(rawValue: row.string(3)) ?? .manual,
            scope: KnowledgeScope(kind: row.string(4), key: row.text(5)) ?? .always,
            createdAt: row.date(6) ?? Date(),
            updatedAt: row.date(7) ?? Date(),
            originName: row.text(8),
            originKind: row.text(9),
            byteSize: row.int(10),
            pageCount: row.int(11))
    }

    // MARK: - Retrieval

    /// Hybrid search: BM25 and cosine, fused by rank.
    ///
    /// Reciprocal rank fusion rather than a weighted score sum, because BM25 and
    /// cosine are on scales that have no relationship to each other — any weight
    /// chosen for one corpus is wrong for the next. RRF only reads the ordering,
    /// which is the part both methods actually agree about.
    ///
    /// Both legs are cheap at this size. FTS5 is an index lookup; the vector leg
    /// is a full scan, which is the right call for a personal corpus of thousands
    /// of chunks and would not be for millions. There is no ANN index here on
    /// purpose — it would be a second thing to keep correct for a few microseconds
    /// that nobody can perceive against a 2.5s answer.
    public func search(
        query: String,
        scopes: [KnowledgeScope],
        limit: Int = 3
    ) async -> [KnowledgeHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0, !scopes.isEmpty else { return [] }

        let candidates = (try? candidateChunks(scopes: scopes)) ?? []
        guard !candidates.isEmpty else { return [] }
        let allowed = Set(candidates.map(\.id))

        var ranks: [Int: [Int]] = [:]
        for (position, id) in (try? lexicalOrder(trimmed, allowed: allowed)) ?? [] {
            ranks[id, default: []].append(position)
        }
        for (position, id) in await vectorOrder(trimmed, candidates: candidates) {
            ranks[id, default: []].append(position)
        }
        guard !ranks.isEmpty else { return [] }

        // The constant damps the top rank's dominance so a chunk both methods
        // place second beats one that only one method placed first. 60 is the
        // value from the original RRF paper and behaves well without tuning.
        let damping = 60.0
        var scored: [(id: Int, score: Double)] = []
        scored.reserveCapacity(ranks.count)
        for (id, positions) in ranks {
            var total = 0.0
            for position in positions {
                total += 1.0 / (damping + Double(position + 1))
            }
            scored.append((id, total))
        }
        // Ties break on chunk id so the order is stable between identical
        // searches — a pointer that reshuffles its own citations reads as churn.
        scored.sort { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }

        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        var hits: [KnowledgeHit] = []
        for entry in scored.prefix(limit) {
            guard let chunk = byID[entry.id] else { continue }
            hits.append(KnowledgeHit(
                noteID: chunk.noteID, title: chunk.title, text: chunk.text,
                source: chunk.source, score: entry.score))
        }
        return hits
    }

    private struct Candidate {
        let id: Int
        let noteID: String
        let title: String
        let text: String
        let source: KnowledgeSource
        let embedding: Data?
    }

    private func candidateChunks(scopes: [KnowledgeScope]) throws -> [Candidate] {
        // One predicate per scope, OR-ed. Built rather than parameterised as a
        // list because SQLite has no array binding, and the pieces are enum-derived
        // literals — `scope.kind` is never user text.
        var clauses: [String] = []
        var bindings: [SQLiteValue] = []
        for scope in scopes {
            if let key = scope.key {
                clauses.append("(n.scope = ? AND n.scope_key = ?)")
                bindings.append(.text(scope.kind))
                bindings.append(.text(key))
            } else {
                clauses.append("(n.scope = ? AND n.scope_key IS NULL)")
                bindings.append(.text(scope.kind))
            }
        }
        let sql = """
        SELECT c.id, c.note_id, n.title, c.text, n.source, c.embedding,
               n.origin_name
        FROM knowledge_chunk c
        JOIN knowledge_note n ON n.id = c.note_id
        WHERE \(clauses.joined(separator: " OR "))
        """
        return try database.query(sql, bindings) { row in
            Candidate(
                // The filename beats the note title for a document: "contract.pdf"
                // is what the user will look for when they check where an answer
                // came from, and the title is a derived label.
                id: row.int(0), noteID: row.string(1),
                title: row.text(6) ?? row.string(2), text: row.string(3),
                source: KnowledgeSource(rawValue: row.string(4)) ?? .manual,
                embedding: row.blob(5))
        }
    }

    /// Chunk ids in BM25 order, filtered to the candidate set.
    private func lexicalOrder(_ query: String, allowed: Set<Int>) throws -> [(Int, Int)] {
        guard let match = Self.ftsQuery(query) else { return [] }
        let rows = try database.query(
            "SELECT rowid FROM knowledge_fts WHERE knowledge_fts MATCH ? ORDER BY bm25(knowledge_fts) LIMIT 50",
            [.text(match)]) { $0.int(0) }
        return rows.filter(allowed.contains).enumerated().map { ($0.offset, $0.element) }
    }

    /// Chunk ids in cosine order. Empty when no backend is loaded, which is what
    /// makes the whole search degrade to BM25 rather than fail.
    private func vectorOrder(_ query: String, candidates: [Candidate]) async -> [(Int, Int)] {
        guard embeddingsReady, let target = await embedder.embed(query) else { return [] }
        let scored = candidates.compactMap { candidate -> (Int, Double)? in
            guard let blob = candidate.embedding else { return nil }
            let similarity = VectorBlob.similarity(target, VectorBlob.decode(blob))
            // Below this, a "match" is the embedding space's floor rather than a
            // relationship — letting those in gives RRF a rank to fuse and floats
            // unrelated notes into a live prompt.
            guard similarity > 0.2 else { return nil }
            return (candidate.id, similarity)
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(50)
            .enumerated()
            .map { ($0.offset, $0.element.0) }
    }

    /// Escapes a user question into an FTS5 MATCH expression.
    ///
    /// Every token is quoted and the whole thing is OR-ed. Quoting is not optional:
    /// FTS5's query language reads bare `-`, `*`, `:`, `^`, `(` and `NEAR` as
    /// syntax, and a transcribed question contains those often enough that an
    /// unquoted MATCH would throw mid-call rather than return nothing.
    static func ftsQuery(_ text: String) -> String? {
        let tokens = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) }
        guard !tokens.isEmpty else { return nil }
        return tokens.prefix(24).map { "\"\($0)\"" }.joined(separator: " OR ")
    }

    /// Only the words that would match nearly every chunk. Kept short on purpose —
    /// an aggressive stop list throws away the question's actual subject as often
    /// as it helps, and BM25 already discounts common terms.
    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "can", "her", "was",
        "one", "our", "out", "day", "get", "has", "him", "his", "how", "its", "new",
        "now", "old", "see", "two", "who", "did", "yes", "that", "this", "with",
        "have", "from", "they", "what", "when", "your", "just", "like", "were",
        "them", "then", "than", "into", "some", "about", "would", "there", "their",
        "which", "could", "should",
    ]
}
