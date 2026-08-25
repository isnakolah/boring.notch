import Foundation
import SQLite3

/// The system SQLite, wrapped in just enough Swift to be usable.
///
/// A hand-rolled wrapper rather than a dependency because the whole surface this
/// package needs is "prepare, bind, step" and the system library already has
/// everything else: macOS ships SQLite 3.51 with FTS5 compiled in, so there is no
/// extension to load. That last part matters more than it looks — the call host
/// is ad-hoc signed, and a loadable extension is exactly the kind of thing that
/// works here and fails silently on someone else's Mac.
///
/// Not thread-safe on its own. `CallaStore` is an actor and owns the only handle.
final class SQLiteDatabase {
    /// Transient means an in-memory copy is taken; our bound strings are locals
    /// that die before `step` runs, so the alternative would be a use-after-free.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var handle: OpaquePointer?

    enum Failure: Error, CustomStringConvertible {
        case open(String)
        case prepare(String, sql: String)
        case step(String)

        var description: String {
            switch self {
            case let .open(message): "sqlite open failed: \(message)"
            case let .prepare(message, sql): "sqlite prepare failed: \(message) — \(sql)"
            case let .step(message): "sqlite step failed: \(message)"
            }
        }
    }

    /// Opens (creating if needed) and puts the connection into the shape a
    /// multi-process store needs.
    ///
    /// Three processes touch this file — the host writes turns during a call, the
    /// engine reads on behalf of the sandboxed app, and tests do both. WAL is what
    /// lets a reader and a writer coexist without the reader seeing a locked
    /// database; `busy_timeout` covers the writer-versus-writer case, which is
    /// rare but real when a call ends while Settings is listing calls.
    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(handle)
            handle = nil
            throw Failure.open(message)
        }
        // journal_mode is a query, not a statement — it answers with the mode it
        // ended up in, so it goes through `scalar` rather than `execute`.
        _ = try? scalarText("PRAGMA journal_mode = WAL")
        try execute("PRAGMA busy_timeout = 5000")
        try execute("PRAGMA foreign_keys = ON")
        // NORMAL rather than FULL: with WAL this is durable across process death,
        // which is the failure that actually happens here (the host is stopped
        // with SIGINT). Only an OS crash can lose the last commits, and the cost
        // of FULL is an fsync on every transcript turn.
        try execute("PRAGMA synchronous = NORMAL")
    }

    deinit { sqlite3_close_v2(handle) }

    // MARK: - Statements

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastMessage
            sqlite3_free(error)
            throw Failure.step(message)
        }
    }

    /// Runs a statement that returns nothing.
    func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw Failure.step(lastMessage) }
    }

    /// Runs a query and maps every row.
    func query<T>(_ sql: String, _ bindings: [SQLiteValue] = [], row: (SQLiteRow) -> T) throws -> [T] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var results: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW {
                results.append(row(SQLiteRow(statement: statement)))
            } else if status == SQLITE_DONE {
                break
            } else {
                throw Failure.step(lastMessage)
            }
        }
        return results
    }

    func scalarInt(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int? {
        try query(sql, bindings) { $0.int(0) }.first
    }

    func scalarText(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> String? {
        try query(sql, bindings) { $0.text(0) }.first ?? nil
    }

    /// Everything or nothing. Used for the writes that would leave the index
    /// disagreeing with the notes if they half-landed.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    // MARK: - Internals

    private var lastMessage: String { String(cString: sqlite3_errmsg(handle)) }

    private func prepare(_ sql: String, _ bindings: [SQLiteValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure.prepare(lastMessage, sql: sql)
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null:
                sqlite3_bind_null(statement, index)
            case let .int(number):
                sqlite3_bind_int64(statement, index, number)
            case let .double(number):
                sqlite3_bind_double(statement, index, number)
            case let .text(string):
                sqlite3_bind_text(statement, index, string, -1, Self.transient)
            case let .blob(data):
                if data.isEmpty {
                    sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    _ = data.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), Self.transient)
                    }
                }
            }
        }
        return statement
    }
}

/// A bound parameter. An enum rather than `Any` so a forgotten case is a compile
/// error instead of a silently-null column.
enum SQLiteValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    static func int(_ value: Int) -> SQLiteValue { .int(Int64(value)) }
    static func text(_ value: String?) -> SQLiteValue { value.map { .text($0) } ?? .null }
    static func double(_ value: Double?) -> SQLiteValue { value.map { .double($0) } ?? .null }
    static func date(_ value: Date?) -> SQLiteValue { value.map { .double($0.timeIntervalSince1970) } ?? .null }
    static func blob(_ value: Data?) -> SQLiteValue { value.map { .blob($0) } ?? .null }
}

/// One row of a result, read by column index.
struct SQLiteRow {
    let statement: OpaquePointer?

    func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }
    func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }

    func text(_ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    /// Non-optional variant for NOT NULL columns, so callers are not forced to
    /// unwrap something the schema already guarantees.
    func string(_ index: Int32) -> String { text(index) ?? "" }

    /// A nullable REAL column. `double(_:)` returns 0 for NULL, which for a
    /// confidence score is a real and very wrong value — it reads as "the model
    /// was certain this was nothing" rather than "this pass did not measure".
    func doubleIfPresent(_ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    func date(_ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    func blob(_ index: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0 else { return nil }
        return Data(bytes: pointer, count: count)
    }
}
