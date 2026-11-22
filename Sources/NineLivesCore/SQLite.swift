import Foundation
import SQLite3

struct SQLiteError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Minimal SQLite wrapper. Not thread safe: callers serialize access.
final class SQLiteDB {
    private(set) var handle: OpaquePointer?

    init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close(handle)
            throw SQLiteError(message: msg)
        }
    }

    deinit { sqlite3_close(handle) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(err)
            throw SQLiteError(message: msg)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(handle)))
        }
        return Statement(stmt!)
    }

    final class Statement {
        let stmt: OpaquePointer
        init(_ s: OpaquePointer) { stmt = s }
        deinit { sqlite3_finalize(stmt) }

        private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        func bind(_ index: Int32, _ value: String) { sqlite3_bind_text(stmt, index, value, -1, Self.transient) }
        func bind(_ index: Int32, _ value: Int64) { sqlite3_bind_int64(stmt, index, value) }
        func bind(_ index: Int32, _ value: Double?) {
            if let value { sqlite3_bind_double(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
        }

        /// Returns true while a row is available.
        @discardableResult func step() -> Bool { sqlite3_step(stmt) == SQLITE_ROW }
        func reset() { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }

        func text(_ col: Int32) -> String { sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? "" }
        func int(_ col: Int32) -> Int64 { sqlite3_column_int64(stmt, col) }
        func double(_ col: Int32) -> Double? {
            sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, col)
        }
    }
}
