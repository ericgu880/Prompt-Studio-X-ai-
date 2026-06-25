import Foundation
import SQLite3

public enum SQLiteValue: Sendable {
    case text(String)
    case int(Int64)
    case double(Double)
    case null
}

public enum SQLiteError: Error, LocalizedError {
    case openFailed(String, resultCode: Int32, extendedCode: Int32)
    case prepareFailed(String, resultCode: Int32, extendedCode: Int32)
    case stepFailed(String, resultCode: Int32, extendedCode: Int32)
    case bindFailed(String, resultCode: Int32, extendedCode: Int32)
    case transactionRollbackFailed(original: String, rollback: String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message, _, _),
             .prepareFailed(let message, _, _),
             .stepFailed(let message, _, _),
             .bindFailed(let message, _, _):
            message
        case .transactionRollbackFailed(let original, let rollback):
            "SQLite transaction failed: \(original); rollback failed: \(rollback)"
        }
    }

    public var resultCode: Int32? {
        switch self {
        case .openFailed(_, let code, _),
             .prepareFailed(_, let code, _),
             .stepFailed(_, let code, _),
             .bindFailed(_, let code, _):
            code
        case .transactionRollbackFailed:
            nil
        }
    }

    public var extendedCode: Int32? {
        switch self {
        case .openFailed(_, _, let code),
             .prepareFailed(_, _, let code),
             .stepFailed(_, _, let code),
             .bindFailed(_, _, let code):
            code
        case .transactionRollbackFailed:
            nil
        }
    }
}

public enum SQLiteOpenMode {
    case createIfNeeded
    case existingReadWrite
}

public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String, mode: SQLiteOpenMode = .createIfNeeded) throws {
        let flags: Int32
        switch mode {
        case .createIfNeeded:
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        case .existingReadWrite:
            flags = SQLITE_OPEN_READWRITE
        }
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            throw SQLiteError.openFailed(
                Self.message(from: handle),
                resultCode: sqlite3_errcode(handle),
                extendedCode: sqlite3_extended_errcode(handle)
            )
        }
        sqlite3_extended_result_codes(handle, 1)
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA journal_mode = WAL;")
    }

    deinit {
        sqlite3_close(handle)
    }

    public func execute(_ sql: String) throws {
        if sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK {
            throw SQLiteError.stepFailed(
                Self.message(from: handle),
                resultCode: sqlite3_errcode(handle),
                extendedCode: sqlite3_extended_errcode(handle)
            )
        }
    }

    public func run(_ sql: String, values: [SQLiteValue] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(
                Self.message(from: handle),
                resultCode: sqlite3_errcode(handle),
                extendedCode: sqlite3_extended_errcode(handle)
            )
        }
        defer { sqlite3_finalize(statement) }

        try bind(values, to: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError.stepFailed(
                Self.message(from: handle),
                resultCode: sqlite3_errcode(handle),
                extendedCode: sqlite3_extended_errcode(handle)
            )
        }
    }

    public func query(_ sql: String, values: [SQLiteValue] = []) throws -> [[String: String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(
                Self.message(from: handle),
                resultCode: sqlite3_errcode(handle),
                extendedCode: sqlite3_extended_errcode(handle)
            )
        }
        defer { sqlite3_finalize(statement) }

        try bind(values, to: statement)

        var rows: [[String: String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: String?] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                guard let namePointer = sqlite3_column_name(statement, index) else { continue }
                let name = String(cString: namePointer)
                if sqlite3_column_type(statement, index) == SQLITE_NULL {
                    row[name] = nil
                } else if let textPointer = sqlite3_column_text(statement, index) {
                    row[name] = String(cString: textPointer)
                } else {
                    row[name] = nil
                }
            }
            rows.append(row)
        }
        return rows
    }

    public func transaction<T>(_ work: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let result = try work()
            try execute("COMMIT;")
            return result
        } catch {
            do {
                try execute("ROLLBACK;")
            } catch let rollbackError {
                throw SQLiteError.transactionRollbackFailed(
                    original: error.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw error
        }
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer?) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text):
                result = sqlite3_bind_text(statement, index, text, -1, transient)
            case .int(let int):
                result = sqlite3_bind_int64(statement, index, int)
            case .double(let double):
                result = sqlite3_bind_double(statement, index, double)
            case .null:
                result = sqlite3_bind_null(statement, index)
            }

            guard result == SQLITE_OK else {
                throw SQLiteError.bindFailed(
                    Self.message(from: handle),
                    resultCode: sqlite3_errcode(handle),
                    extendedCode: sqlite3_extended_errcode(handle)
                )
            }
        }
    }

    private static func message(from handle: OpaquePointer?) -> String {
        if let pointer = sqlite3_errmsg(handle) {
            return String(cString: pointer)
        }
        return "SQLite operation failed"
    }
}
