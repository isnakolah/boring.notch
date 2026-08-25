import Foundation

/// The database's shape, and how it gets there from whatever it is now.
///
/// Versioned through SQLite's own `user_version` rather than a table of our own:
/// it is a single integer in the file header, it costs no query, and it cannot
/// itself be missing on a fresh file. Each migration is applied in one
/// transaction, so a failure halfway leaves the previous version intact.
enum Schema {
    /// Bump this and append to `migrations` — never edit a migration that has
    /// shipped, because someone's file has already run it.
    static let current = 4

    static func migrate(_ database: SQLiteDatabase) throws {
        let version = try database.scalarInt("PRAGMA user_version") ?? 0
        guard version < current else { return }
        for step in (version + 1) ... current {
            guard let sql = migrations[step] else { continue }
            try database.transaction {
                try database.execute(sql)
                // Not a bindable parameter — PRAGMA takes a literal.
                try database.execute("PRAGMA user_version = \(step)")
            }
        }
    }

    private static let migrations: [Int: String] = [1: v1, 2: v2, 3: v3, 4: v4]

    /// Attached documents.
    ///
    /// A note used to be a paragraph someone typed, and every note that applied
    /// to a meeting was concatenated into the prompt at call start. A forty-page
    /// contract cannot go there — it would blow the block on its own and crowd out
    /// the two sentences that actually matter. So documents are stored the same
    /// way and *used* differently: searched per question, never packed whole. The
    /// columns here are what lets the two be told apart, and what lets the UI say
    /// "contract.pdf, 12 pages" instead of showing a wall of extracted text.
    private static let v2 = """
    ALTER TABLE knowledge_note ADD COLUMN origin_name TEXT;
    ALTER TABLE knowledge_note ADD COLUMN origin_kind TEXT;
    ALTER TABLE knowledge_note ADD COLUMN byte_size INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE knowledge_note ADD COLUMN page_count INTEGER NOT NULL DEFAULT 0;
    """

    /// Review state is deliberately separate from live suggestions and legacy
    /// call_summary. Nothing written here is retrieval knowledge until approval.
    private static let v3 = """
    CREATE TABLE IF NOT EXISTS call_recap_draft (
      call_id       TEXT PRIMARY KEY REFERENCES call(id) ON DELETE CASCADE,
      overview      TEXT NOT NULL,
      items_json    TEXT NOT NULL,
      provider      TEXT,
      model         TEXT,
      failure       TEXT,
      review_state  TEXT NOT NULL DEFAULT 'pending',
      reviewed_at   REAL,
      note_id       TEXT REFERENCES knowledge_note(id) ON DELETE SET NULL
    );
    CREATE INDEX IF NOT EXISTS call_recap_review ON call_recap_draft(review_state);
    """

    /// A call gets transcribed more than once.
    ///
    /// The live pass trades accuracy for latency — a small model, truncated
    /// encoder context, one VAD-bounded fragment at a time. The archive pass runs
    /// afterwards with `large-v3-turbo` over the whole recording and is markedly
    /// better; on this machine the live microphone leg scores 68.8% word error
    /// against it. That better transcript existed already and had nowhere to go:
    /// `call_turn` was keyed on `(call_id, seq)`, so importing it would have
    /// overwritten the record of what the copilot actually saw during the call.
    ///
    /// Both are worth keeping. Revision 0 is what was on screen and what every
    /// suggestion was reasoning over; revision 1 is what was really said, and is
    /// what History and any note filed from a recap should rest on.
    ///
    /// `confidence` and `no_speech` come from whisper's own token probabilities.
    /// A turn the model was unsure of should not become established fact in a
    /// summary, and until now nothing downstream could tell.
    ///
    /// Written as a rebuild rather than `ALTER TABLE ADD COLUMN` plus a rebuild:
    /// the primary key has to change, which SQLite cannot do in place, and the
    /// new table already declares every column — so the ALTERs would only have
    /// added the same three names twice.
    private static let v4 = """
    CREATE TABLE call_turn_v4 (
      call_id    TEXT NOT NULL REFERENCES call(id) ON DELETE CASCADE,
      seq        INTEGER NOT NULL,
      revision   INTEGER NOT NULL DEFAULT 0,
      source     TEXT NOT NULL,
      t0         REAL NOT NULL,
      t1         REAL NOT NULL,
      text       TEXT NOT NULL,
      confidence REAL,
      no_speech  REAL,
      PRIMARY KEY (call_id, revision, seq)
    );
    INSERT INTO call_turn_v4(call_id, seq, revision, source, t0, t1, text, confidence, no_speech)
      SELECT call_id, seq, 0, source, t0, t1, text, NULL, NULL FROM call_turn;
    DROP TABLE call_turn;
    ALTER TABLE call_turn_v4 RENAME TO call_turn;
    CREATE INDEX IF NOT EXISTS call_turn_call ON call_turn(call_id, revision, seq);
    """

    private static let v1 = """
    CREATE TABLE knowledge_note (
      id         TEXT PRIMARY KEY,
      title      TEXT NOT NULL,
      body       TEXT NOT NULL,
      source     TEXT NOT NULL,
      scope      TEXT NOT NULL,
      scope_key  TEXT,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL
    );
    CREATE INDEX knowledge_note_scope ON knowledge_note(scope, scope_key);
    CREATE INDEX knowledge_note_source ON knowledge_note(source);

    CREATE TABLE knowledge_chunk (
      id        INTEGER PRIMARY KEY,
      note_id   TEXT NOT NULL REFERENCES knowledge_note(id) ON DELETE CASCADE,
      ord       INTEGER NOT NULL,
      text      TEXT NOT NULL,
      embedding BLOB
    );
    CREATE INDEX knowledge_chunk_note ON knowledge_chunk(note_id);

    -- External-content FTS: the text lives once, in knowledge_chunk, and the
    -- index refers to it by rowid. Halves the storage and makes it impossible
    -- for the two to disagree about what a chunk says.
    CREATE VIRTUAL TABLE knowledge_fts USING fts5(
      text,
      content='knowledge_chunk',
      content_rowid='id',
      tokenize='porter unicode61'
    );

    -- The standard trio. An external-content table is not maintained
    -- automatically; without these, search silently returns stale rows.
    CREATE TRIGGER knowledge_chunk_ai AFTER INSERT ON knowledge_chunk BEGIN
      INSERT INTO knowledge_fts(rowid, text) VALUES (new.id, new.text);
    END;
    CREATE TRIGGER knowledge_chunk_ad AFTER DELETE ON knowledge_chunk BEGIN
      INSERT INTO knowledge_fts(knowledge_fts, rowid, text) VALUES('delete', old.id, old.text);
    END;
    CREATE TRIGGER knowledge_chunk_au AFTER UPDATE ON knowledge_chunk BEGIN
      INSERT INTO knowledge_fts(knowledge_fts, rowid, text) VALUES('delete', old.id, old.text);
      INSERT INTO knowledge_fts(rowid, text) VALUES (new.id, new.text);
    END;

    CREATE TABLE call (
      id          TEXT PRIMARY KEY,
      event_id    TEXT,
      series_id   TEXT,
      event_title TEXT,
      event_start REAL,
      persona     TEXT NOT NULL,
      started_at  REAL,
      ended_at    REAL,
      live_model  TEXT,
      provider    TEXT,
      turn_count  INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX call_event  ON call(event_id);
    CREATE INDEX call_series ON call(series_id, started_at DESC);
    CREATE INDEX call_started ON call(started_at DESC);

    CREATE TABLE call_turn (
      call_id TEXT NOT NULL REFERENCES call(id) ON DELETE CASCADE,
      seq     INTEGER NOT NULL,
      source  TEXT NOT NULL,
      t0      REAL NOT NULL,
      t1      REAL NOT NULL,
      text    TEXT NOT NULL,
      PRIMARY KEY (call_id, seq)
    );

    CREATE TABLE call_suggestion (
      id             INTEGER PRIMARY KEY,
      call_id        TEXT NOT NULL REFERENCES call(id) ON DELETE CASCADE,
      after_seq      INTEGER NOT NULL,
      headline       TEXT NOT NULL,
      angles         TEXT,
      confirm        TEXT,
      summary        TEXT,
      open_questions TEXT,
      latency_ms     INTEGER NOT NULL DEFAULT 0,
      at             REAL NOT NULL
    );
    CREATE INDEX call_suggestion_call ON call_suggestion(call_id, after_seq);

    CREATE TABLE call_summary (
      call_id        TEXT PRIMARY KEY REFERENCES call(id) ON DELETE CASCADE,
      standing       TEXT,
      points         TEXT,
      open_questions TEXT,
      note_id        TEXT REFERENCES knowledge_note(id) ON DELETE SET NULL
    );

    -- Small key/value corner for things that are neither knowledge nor a call:
    -- the JSONL import marker, and the embedder revision the vectors were built
    -- with (a revision change makes every stored vector incomparable).
    CREATE TABLE store_meta (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
    """
}
