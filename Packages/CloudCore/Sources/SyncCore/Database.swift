// Apache 2 license - developer@infinitecontext.com

import Foundation
import SQLite3

/// A small wrapper over SQLite. WAL mode lets the app and the extension share one database.
final class Database: @unchecked Sendable {
    enum DatabaseError: Error, Equatable {
        case failed(String)
        /// The file itself is unusable, which is different from being busy or out of space.
        case damaged
    }

    enum Value: Equatable {
        case text(String)
        case integer(Int64)
        case real(Double)
        case null
    }

    typealias Row = [String: Value]

    private let handle: OpaquePointer
    private let lock = NSRecursiveLock()

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(url.path, &opened, flags, nil)
        guard status == SQLITE_OK, let opened else {
            // SQLite can hand back a handle even when opening fails, and it must be closed.
            sqlite3_close_v2(opened)
            throw DatabaseError.failed("Couldn't open the database.")
        }
        handle = opened
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA journal_mode=WAL")
        // NORMAL can lose a recent commit in a power failure, and these rows decide what's
        // been saved.
        try execute("PRAGMA synchronous=FULL")
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    private var lastError: DatabaseError {
        let code = sqlite3_errcode(handle) & 0xFF
        if code == SQLITE_CORRUPT || code == SQLITE_NOTADB {
            return .damaged
        }
        return .failed(String(cString: sqlite3_errmsg(handle)))
    }

    /// Frees whatever this connection's cache isn't using.
    func releaseMemory() {
        lock.lock()
        defer { lock.unlock() }
        sqlite3_db_release_memory(handle)
    }

    @discardableResult
    func execute(_ sql: String, _ parameters: [Value] = []) throws -> [Row] {
        lock.lock()
        defer { lock.unlock() }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in parameters.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let text):
                sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case .integer(let number):
                sqlite3_bind_int64(statement, position, number)
            case .real(let number):
                sqlite3_bind_double(statement, position, number)
            case .null:
                sqlite3_bind_null(statement, position)
            }
        }

        var rows: [Row] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append(readRow(statement))
            case SQLITE_DONE:
                return rows
            default:
                throw lastError
            }
        }
    }

    private func readRow(_ statement: OpaquePointer?) -> Row {
        var row: Row = [:]
        for column in 0..<sqlite3_column_count(statement) {
            // SQLite returns null for these when it runs out of memory.
            guard let namePointer = sqlite3_column_name(statement, column) else { continue }
            let name = String(cString: namePointer)
            switch sqlite3_column_type(statement, column) {
            case SQLITE_INTEGER:
                row[name] = .integer(sqlite3_column_int64(statement, column))
            case SQLITE_FLOAT:
                row[name] = .real(sqlite3_column_double(statement, column))
            case SQLITE_TEXT:
                row[name] = sqlite3_column_text(statement, column).map { .text(String(cString: $0)) } ?? .null
            default:
                row[name] = .null
            }
        }
        return row
    }

    /// Runs a block in one transaction, so its changes apply together or not at all.
    func transaction<Result>(_ body: () throws -> Result) throws -> Result {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }
}

extension Database.Row {
    func text(_ key: String) -> String? {
        if case .text(let value) = self[key] { return value }
        return nil
    }

    func integer(_ key: String) -> Int64? {
        if case .integer(let value) = self[key] { return value }
        return nil
    }

    func real(_ key: String) -> Double? {
        switch self[key] {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }
}
