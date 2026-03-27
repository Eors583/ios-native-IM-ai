import Foundation
import SQLite3

// SQLite3 在 Swift 下不会自动暴露 SQLITE_TRANSIENT，需要手动定义销毁器。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteError: Error, LocalizedError {
    case openDatabase(String)
    case prepare(String)
    case step(String)
    case bind(String)

    var errorDescription: String? {
        switch self {
        case .openDatabase(let s), .prepare(let s), .step(let s), .bind(let s):
            return s
        }
    }
}

final class SQLiteDB {
    private var db: OpaquePointer?

    init(path: String) throws {
        if sqlite3_open(path, &db) != SQLITE_OK {
            throw SQLiteError.openDatabase(String(cString: sqlite3_errmsg(db)))
        }
        try exec("PRAGMA foreign_keys = ON;")
    }

    deinit {
        sqlite3_close(db)
    }

    func exec(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "sqlite exec failed"
            sqlite3_free(errMsg)
            throw SQLiteError.step(msg)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    func finalize(_ stmt: OpaquePointer?) {
        sqlite3_finalize(stmt)
    }

    func step(_ stmt: OpaquePointer?) throws -> Int32 {
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_ROW && rc != SQLITE_DONE {
            throw SQLiteError.step(String(cString: sqlite3_errmsg(db)))
        }
        return rc
    }

    func reset(_ stmt: OpaquePointer?) {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    // MARK: bind helpers
    func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) throws {
        if sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT) != SQLITE_OK {
            throw SQLiteError.bind("bind text failed")
        }
    }

    func bindInt64(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Int64) throws {
        if sqlite3_bind_int64(stmt, idx, value) != SQLITE_OK {
            throw SQLiteError.bind("bind int64 failed")
        }
    }

    func bindInt(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Int32) throws {
        if sqlite3_bind_int(stmt, idx, value) != SQLITE_OK {
            throw SQLiteError.bind("bind int failed")
        }
    }

    // MARK: column helpers
    func colText(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: c)
    }

    func colInt64(_ stmt: OpaquePointer?, _ idx: Int32) -> Int64 {
        sqlite3_column_int64(stmt, idx)
    }

    func colInt(_ stmt: OpaquePointer?, _ idx: Int32) -> Int32 {
        sqlite3_column_int(stmt, idx)
    }
}

