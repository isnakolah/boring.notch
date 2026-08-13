/** Calla-only durable memory. It is intentionally separate from main-agent memory. */
import {DatabaseSync} from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import {MemoryRejection, sanitiseNote} from "./memory.mjs";

export const FACT_RETENTION_DAYS = 90;
export const MAX_FACTS_PER_SCOPE = 40;
export const MAX_RECALL_FACTS = 6;
export const MAX_RECALL_CHARS = 1_200;

function timestamp() { return Date.now(); }
function databasePath(config) { return path.join(config.stateDirectory, "calla-memory", "facts.sqlite"); }
function open(config) {
  const file = databasePath(config);
  fs.mkdirSync(path.dirname(file), {recursive: true, mode: 0o700});
  const db = new DatabaseSync(file);
  fs.chmodSync(file, 0o600);
  db.exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;");
  db.exec(`CREATE TABLE IF NOT EXISTS fact (
    id INTEGER PRIMARY KEY, scope TEXT NOT NULL, subject TEXT NOT NULL, text TEXT NOT NULL,
    pack_revision TEXT, verified INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
    UNIQUE(scope, subject, text)
  );
  CREATE VIRTUAL TABLE IF NOT EXISTS fact_fts USING fts5(text, content='fact', content_rowid='id');
  CREATE TRIGGER IF NOT EXISTS fact_ai AFTER INSERT ON fact BEGIN INSERT INTO fact_fts(rowid, text) VALUES (new.id, new.text); END;
  CREATE TRIGGER IF NOT EXISTS fact_ad AFTER DELETE ON fact BEGIN INSERT INTO fact_fts(fact_fts, rowid, text) VALUES ('delete', old.id, old.text); END;
  CREATE INDEX IF NOT EXISTS fact_scope_expiry ON fact(scope, subject, expires_at);`);
  return db;
}

function validSubject(scope, subject) {
  const valid = scope === "learner" ? /^[A-Za-z0-9-]{1,64}$/ : /^[A-Za-z0-9][A-Za-z0-9._-]{0,126}$/;
  if (!valid.test(subject || "")) throw new MemoryRejection(`${scope} subject is invalid`);
}

export class CallaMemoryGraph {
  constructor(config, {now = timestamp} = {}) { this.config = config; this.now = now; this.db = null; }
  get database() { if (!this.db) this.db = open(this.config); return this.db; }
  prune() { return this.database.prepare("DELETE FROM fact WHERE expires_at <= ?").run(this.now()).changes; }
  remember(scope, subject, notes, {packRevision = null, verified = false} = {}) {
    if (!Array.isArray(notes) || !notes.length) throw new MemoryRejection("notes must be a non-empty array");
    validSubject(scope, subject); this.prune();
    const clean = notes.map(sanitiseNote); const created = this.now(); const expires = created + FACT_RETENTION_DAYS * 86_400_000;
    const upsert = this.database.prepare(`INSERT INTO fact(scope, subject, text, pack_revision, verified, created_at, expires_at)
      VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(scope, subject, text) DO UPDATE SET pack_revision=excluded.pack_revision, verified=MAX(fact.verified, excluded.verified), created_at=excluded.created_at, expires_at=excluded.expires_at`);
    const trim = this.database.prepare("DELETE FROM fact WHERE id IN (SELECT id FROM fact WHERE scope=? AND subject=? ORDER BY created_at DESC LIMIT -1 OFFSET ?)");
    this.database.exec("BEGIN IMMEDIATE");
    try {
      for (const note of clean) upsert.run(scope, subject, note, packRevision, verified ? 1 : 0, created, expires);
      trim.run(scope, subject, MAX_FACTS_PER_SCOPE);
      this.database.exec("COMMIT");
    } catch (error) {
      this.database.exec("ROLLBACK");
      throw error;
    }
    return {stored: clean.length, total: this.count(scope, subject)};
  }
  count(scope, subject) { return Number(this.database.prepare("SELECT COUNT(*) AS count FROM fact WHERE scope=? AND subject=? AND expires_at>? ").get(scope, subject, this.now()).count); }
  recall({learnerID, bundleID, maxChars = MAX_RECALL_CHARS} = {}) {
    this.prune(); const rows = [];
    if (learnerID && /^[A-Za-z0-9-]{1,64}$/.test(learnerID)) rows.push(...this.database.prepare("SELECT text, scope, subject, verified FROM fact WHERE scope='learner' AND subject=? AND expires_at>? ORDER BY verified DESC, created_at DESC LIMIT ?").all(learnerID, this.now(), MAX_RECALL_FACTS));
    if (bundleID && /^[A-Za-z0-9][A-Za-z0-9._-]{0,126}$/.test(bundleID)) rows.push(...this.database.prepare("SELECT text, scope, subject, verified FROM fact WHERE scope='application' AND subject=? AND expires_at>? ORDER BY verified DESC, created_at DESC LIMIT ?").all(bundleID, this.now(), MAX_RECALL_FACTS));
    const unique = [...new Map(rows.map((row) => [row.text, row])).values()].slice(0, MAX_RECALL_FACTS);
    const lines = []; let size = 0;
    for (const row of unique) { const line = `- ${row.text}`; if (size + line.length + 1 > maxChars) break; lines.push(line); size += line.length + 1; }
    return lines;
  }
  search(query, {limit = MAX_RECALL_FACTS} = {}) {
    this.prune();
    const terms = String(query || "").match(/[\p{L}\p{N}_-]+/gu)?.slice(0, 12) ?? [];
    if (!terms.length) return [];
    const expression = terms.map((term) => `"${term.replace(/"/g, "")}"`).join(" OR ");
    return this.database.prepare(`SELECT fact.text, fact.scope, fact.subject, fact.verified
      FROM fact_fts JOIN fact ON fact_fts.rowid=fact.id
      WHERE fact_fts MATCH ? AND fact.expires_at > ?
      ORDER BY bm25(fact_fts), fact.verified DESC, fact.created_at DESC LIMIT ?`).all(expression, this.now(), Math.min(Math.max(limit, 1), MAX_RECALL_FACTS));
  }
  close() { this.db?.close(); this.db = null; }
}
