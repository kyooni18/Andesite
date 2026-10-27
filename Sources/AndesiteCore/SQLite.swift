import CSQLite
import Foundation

public struct SQLiteFailure: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite \(code): \(message)" }
}

public enum SQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

/// A single, explicitly owned connection. Callers must serialize access and must not
/// run blocking database operations on a network event loop.
public final class SQLiteConnection {
    private var handle: OpaquePointer?

    public init(path: String) throws {
        var db: OpaquePointer?
        let result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot allocate connection"
            if let db { sqlite3_close(db) }
            throw SQLiteFailure(code: result, message: message)
        }
        handle = db
        do {
            guard sqlite3_libversion_number() >= 3_035_000 else {
                throw SQLiteFailure(code: SQLITE_ERROR, message: "SQLite 3.35 or newer required")
            }
            sqlite3_busy_timeout(db, 5000)
            try execute("PRAGMA foreign_keys=ON")
            guard try scalarText("PRAGMA journal_mode=WAL")?.lowercased() == "wal" else {
                throw SQLiteFailure(code: SQLITE_ERROR, message: "WAL unavailable")
            }
            try execute("PRAGMA synchronous=FULL")
            // Exercise the actual FTS5 implementation, not a compile-option guess.
            try execute("CREATE VIRTUAL TABLE temp.andesite_fts_probe USING fts5(content)")
            try execute("DROP TABLE temp.andesite_fts_probe")
        } catch {
            sqlite3_close(db)
            handle = nil
            throw error
        }
    }

    deinit { if let handle { sqlite3_close(handle) } }

    private func failure(_ code: Int32) -> SQLiteFailure {
        SQLiteFailure(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "connection closed")
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw failure(result) }
        return statement
    }

    public func execute(_ sql: String, bindings: [String?] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw failure(result) }
    }

    public func scalarText(_ sql: String, bindings: [String?] = []) throws -> String? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw failure(result) }
        guard let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(statement, 0))), as: UTF8.self)
    }

    private func bind(_ values: [String?], to statement: OpaquePointer) throws {
        guard sqlite3_bind_parameter_count(statement) == Int32(values.count) else {
            throw SQLiteFailure(code: SQLITE_MISUSE, message: "incorrect binding count")
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            if let value {
                let bytes = Array(value.utf8)
                guard bytes.count <= Int(Int32.max) else {
                    throw SQLiteFailure(code: SQLITE_TOOBIG, message: "text binding too large")
                }
                result = value.withCString { sqlite3_bind_text(statement, index, $0, Int32(bytes.count), transient) }
            } else {
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw failure(result) }
        }
    }

    /// Execute a statement with typed values, retaining blob and integer types.
    public func executeValues(_ sql: String, bindings: [SQLiteValue]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindValues(bindings, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw failure(result) }
    }

    /// Materializes rows; callers must use a bounded query for untrusted data.
    public func queryValues(_ sql: String, bindings: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindValues(bindings, to: statement)
        var rows: [[SQLiteValue]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw failure(result) }
            var row: [SQLiteValue] = []
            for index in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_NULL: row.append(.null)
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, index)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement, index)))
                case SQLITE_TEXT:
                    guard let pointer = sqlite3_column_text(statement, index) else { throw failure(SQLITE_NOMEM) }
                    let bytes = UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, index)))
                    guard let value = String(bytes: bytes, encoding: .utf8) else {
                        throw SQLiteFailure(code: SQLITE_MISMATCH, message: "invalid UTF-8 in text column")
                    }
                    row.append(.text(value))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    if count == 0 { row.append(.blob(Data())) }
                    else {
                        guard let pointer = sqlite3_column_blob(statement, index) else { throw failure(SQLITE_NOMEM) }
                        row.append(.blob(Data(bytes: pointer, count: count)))
                    }
                default: throw SQLiteFailure(code: SQLITE_MISMATCH, message: "unknown SQLite type")
                }
            }
            rows.append(row)
        }
    }

    private func bindValues(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        guard sqlite3_bind_parameter_count(statement) == Int32(values.count) else {
            throw SQLiteFailure(code: SQLITE_MISUSE, message: "incorrect binding count")
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null: result = sqlite3_bind_null(statement, index)
            case .integer(let value): result = sqlite3_bind_int64(statement, index, value)
            case .real(let value): result = sqlite3_bind_double(statement, index, value)
            case .text(let value):
                let count = value.utf8.count
                guard count <= Int(Int32.max) else { throw SQLiteFailure(code: SQLITE_TOOBIG, message: "text binding too large") }
                result = value.withCString { sqlite3_bind_text(statement, index, $0, Int32(count), transient) }
            case .blob(let value):
                guard value.count <= Int(Int32.max) else { throw SQLiteFailure(code: SQLITE_TOOBIG, message: "blob binding too large") }
                if value.isEmpty { result = sqlite3_bind_zeroblob(statement, index, 0) }
                else { result = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), transient) } }
            }
            guard result == SQLITE_OK else { throw failure(result) }
        }
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
