import Foundation
import SQLite3

public enum SQLiteValue: Sendable {
    case text(String)
    case int(Int64)
    case double(Double)
    case null
}

public enum SQLiteError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message), .prepareFailed(let message), .stepFailed(let message), .bindFailed(let message):
            message
        }
    }
}

public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        if sqlite3_open(path, &handle) != SQLITE_OK {
            throw SQLiteError.openFailed(Self.message(from: handle))
        }
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA journal_mode = WAL;")
    }

    deinit {
        sqlite3_close(handle)
    }

    public func execute(_ sql: String) throws {
        if sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK {
            throw SQLiteError.stepFailed(Self.message(from: handle))
        }
    }

    public func run(_ sql: String, values: [SQLiteValue] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(Self.message(from: handle))
        }
        defer { sqlite3_finalize(statement) }

        try bind(values, to: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError.stepFailed(Self.message(from: handle))
        }
    }

    public func query(_ sql: String, values: [SQLiteValue] = []) throws -> [[String: String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(Self.message(from: handle))
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
                throw SQLiteError.bindFailed(Self.message(from: handle))
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
