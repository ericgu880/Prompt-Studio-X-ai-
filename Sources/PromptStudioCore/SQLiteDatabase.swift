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
    case backupFailed(String, resultCode: Int32, extendedCode: Int32)
    case transactionRollbackFailed(original: String, rollback: String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message, _, _),
             .prepareFailed(let message, _, _),
             .stepFailed(let message, _, _),
             .bindFailed(let message, _, _),
             .backupFailed(let message, _, _):
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
             .bindFailed(_, let code, _),
             .backupFailed(_, let code, _):
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
             .bindFailed(_, _, let code),
             .backupFailed(_, _, let code):
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

public struct SQLiteBackupValidationReport: Equatable, Sendable {
    public let integrityOK: Bool
    public let foreignKeyViolationCount: Int
    public let tableRowCounts: [String: Int]

    public init(
        integrityOK: Bool,
        foreignKeyViolationCount: Int,
        tableRowCounts: [String: Int]
    ) {
        self.integrityOK = integrityOK
        self.foreignKeyViolationCount = foreignKeyViolationCount
        self.tableRowCounts = tableRowCounts
    }
}

public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let databasePath: String
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String, mode: SQLiteOpenMode = .createIfNeeded) throws {
        self.databasePath = path
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
        try execute("PRAGMA busy_timeout = 5000;")
        if let handle {
            try LibraryQuerySQLiteFunctions.register(on: handle)
        }
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

    /// Creates a point-in-time copy using SQLite's online backup API. The
    /// source connection remains open, so a WAL snapshot is copied without
    /// touching the source database or its journal mode.
    public func backup(to destinationPath: String) throws {
        guard let source = handle else {
            throw SQLiteError.backupFailed(
                "SQLite backup source is closed",
                resultCode: SQLITE_MISUSE,
                extendedCode: SQLITE_MISUSE
            )
        }

        let destinationURL = URL(fileURLWithPath: destinationPath)
        let parent = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var destination: OpaquePointer?
        let openResult = sqlite3_open_v2(
            destinationPath,
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )
        guard openResult == SQLITE_OK else {
            throw SQLiteError.backupFailed(
                Self.message(from: destination),
                resultCode: sqlite3_errcode(destination),
                extendedCode: sqlite3_extended_errcode(destination)
            )
        }
        defer { sqlite3_close(destination) }

        sqlite3_extended_result_codes(destination, 1)
        let backup = sqlite3_backup_init(destination, "main", source, "main")
        guard let backup else {
            throw SQLiteError.backupFailed(
                Self.message(from: destination),
                resultCode: sqlite3_errcode(destination),
                extendedCode: sqlite3_extended_errcode(destination)
            )
        }

        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            let resultCode = stepResult == SQLITE_DONE ? finishResult : stepResult
            throw SQLiteError.backupFailed(
                Self.message(from: destination),
                resultCode: resultCode,
                extendedCode: sqlite3_extended_errcode(destination)
            )
        }
    }

    /// Copies an existing database through a read-only source handle. This is
    /// intended for immutable benchmark/fixture cloning and includes committed
    /// WAL frames without changing the source journal mode or database header.
    public static func backup(fromReadOnlyPath sourcePath: String, to destinationPath: String) throws {
        var source: OpaquePointer?
        let sourceOpenResult = sqlite3_open_v2(
            sourcePath,
            &source,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard sourceOpenResult == SQLITE_OK, let source else {
            defer { sqlite3_close(source) }
            throw SQLiteError.backupFailed(
                Self.message(from: source),
                resultCode: sourceOpenResult,
                extendedCode: sqlite3_extended_errcode(source)
            )
        }
        defer { sqlite3_close(source) }

        let destinationURL = URL(fileURLWithPath: destinationPath)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var destination: OpaquePointer?
        let destinationOpenResult = sqlite3_open_v2(
            destinationPath,
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )
        guard destinationOpenResult == SQLITE_OK, let destination else {
            defer { sqlite3_close(destination) }
            throw SQLiteError.backupFailed(
                Self.message(from: destination),
                resultCode: destinationOpenResult,
                extendedCode: sqlite3_extended_errcode(destination)
            )
        }
        defer { sqlite3_close(destination) }

        let backup = sqlite3_backup_init(destination, "main", source, "main")
        guard let backup else {
            throw SQLiteError.backupFailed(
                Self.message(from: destination),
                resultCode: sqlite3_errcode(destination),
                extendedCode: sqlite3_extended_errcode(destination)
            )
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            let resultCode = stepResult == SQLITE_DONE ? finishResult : stepResult
            throw SQLiteError.backupFailed(
                Self.message(from: destination),
                resultCode: resultCode,
                extendedCode: sqlite3_extended_errcode(destination)
            )
        }
    }

    /// Restores a read-only backup into this live connection using SQLite's
    /// online backup API. This keeps the destination handle valid while
    /// replacing its pages and is used only by explicit migration rollback.
    public func restore(
        fromReadOnlyPath sourcePath: String,
        moveItem: ((String, String) throws -> Void)? = nil
    ) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourcePath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw SQLiteError.backupFailed(
                "SQLite restore source does not exist",
                resultCode: SQLITE_CANTOPEN,
                extendedCode: SQLITE_CANTOPEN
            )
        }

        // Validate into a same-volume staging path before touching the live
        // database. This keeps a malformed/corrupt source from leaving the
        // destination empty after a failed copy/open.
        let stagedPath = databasePath + ".restore-staged-\(UUID().uuidString).sqlite"
        defer { try? fileManager.removeItem(atPath: stagedPath) }
        do {
            try fileManager.copyItem(atPath: sourcePath, toPath: stagedPath)
            let staged = try SQLiteDatabase(path: stagedPath, mode: .existingReadWrite)
            let integrity = try staged.query("PRAGMA integrity_check;").first?["integrity_check"] ?? nil
            guard integrity == "ok" else {
                throw SQLiteError.backupFailed(
                    "SQLite restore source failed integrity_check",
                    resultCode: SQLITE_CORRUPT,
                    extendedCode: SQLITE_CORRUPT
                )
            }
        } catch {
            throw SQLiteError.backupFailed(
                "SQLite restore source could not be staged: \(error.localizedDescription)",
                resultCode: SQLITE_CORRUPT,
                extendedCode: SQLITE_CORRUPT
            )
        }

        let originalPath = databasePath + ".restore-original-\(UUID().uuidString).sqlite"
        var originalMoved = false
        var replacementInstalled = false
        var sidecarPairs: [(live: String, original: String)] = []
        var movedSidecars: [(live: String, original: String)] = []
        let move: (String, String) throws -> Void = moveItem ?? { source, destination in
            try fileManager.moveItem(atPath: source, toPath: destination)
        }
        do {
            // Move the live pathname before closing its handle. If this first
            // move is rejected, the open handle and every live byte remain
            // untouched; the catch path can simply surface the failure.
            try move(databasePath, originalPath)
            originalMoved = true
            if let handle {
                let closeResult = sqlite3_close(handle)
                guard closeResult == SQLITE_OK else {
                    throw SQLiteError.backupFailed(
                        "SQLite restore destination is still busy",
                        resultCode: closeResult,
                        extendedCode: sqlite3_extended_errcode(handle)
                    )
                }
                self.handle = nil
            }
            sidecarPairs = ["-wal", "-shm"].compactMap { suffix -> (live: String, original: String)? in
                let live = databasePath + suffix
                guard fileManager.fileExists(atPath: live) else { return nil }
                return (live: live, original: originalPath + suffix)
            }
            for pair in sidecarPairs {
                try move(pair.live, pair.original)
                movedSidecars.append(pair)
            }
            try move(stagedPath, databasePath)
            replacementInstalled = true
            try reopenAfterRestore()
            try? fileManager.removeItem(atPath: originalPath)
            for pair in sidecarPairs {
                try? fileManager.removeItem(atPath: pair.original)
            }
        } catch {
            if originalMoved {
                if let handle {
                    sqlite3_close(handle)
                }
                handle = nil
            }
            // A failed first move leaves the live path untouched. Only clean
            // up the destination after the staged replacement was installed.
            if replacementInstalled {
                try? fileManager.removeItem(atPath: databasePath)
            }
            if originalMoved {
                try? fileManager.moveItem(atPath: originalPath, toPath: databasePath)
            }
            for pair in movedSidecars.reversed() {
                try? fileManager.moveItem(atPath: pair.original, toPath: pair.live)
            }
            if originalMoved {
                try? reopenAfterRestore()
            }
            throw SQLiteError.backupFailed(
                "SQLite restore could not atomically replace destination: \(error.localizedDescription)",
                resultCode: SQLITE_IOERR,
                extendedCode: SQLITE_IOERR
            )
        }
    }

    private func reopenAfterRestore() throws {
        let openResult = sqlite3_open_v2(
            databasePath,
            &handle,
            SQLITE_OPEN_READWRITE,
            nil
        )
        guard openResult == SQLITE_OK else {
            throw SQLiteError.backupFailed(
                Self.message(from: handle),
                resultCode: openResult,
                extendedCode: sqlite3_extended_errcode(handle)
            )
        }
        sqlite3_extended_result_codes(handle, 1)
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA busy_timeout = 5000;")
        if let handle {
            try LibraryQuerySQLiteFunctions.register(on: handle)
        }
    }

    /// Opens a backup read-only and verifies its SQLite structure and the
    /// source table counts captured immediately before backup creation.
    public static func validateBackup(
        at path: String,
        expectedTableRowCounts: [String: Int]
    ) throws -> SQLiteBackupValidationReport {
        var backupHandle: OpaquePointer?
        let immutableURI = URL(fileURLWithPath: path).absoluteString + "?immutable=1"
        let openResult = sqlite3_open_v2(
            immutableURI,
            &backupHandle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI,
            nil
        )
        guard openResult == SQLITE_OK, let backupHandle else {
            defer { sqlite3_close(backupHandle) }
            throw SQLiteError.backupFailed(
                Self.message(from: backupHandle),
                resultCode: openResult,
                extendedCode: sqlite3_extended_errcode(backupHandle)
            )
        }
        defer { sqlite3_close(backupHandle) }
        sqlite3_extended_result_codes(backupHandle, 1)

        let integrityRows = try queryFirstColumn(
            handle: backupHandle,
            sql: "PRAGMA integrity_check;"
        )
        let integrityOK = integrityRows == ["ok"]
        guard integrityOK else {
            throw SQLiteError.backupFailed(
                "SQLite backup failed integrity_check: \(integrityRows.joined(separator: ", "))",
                resultCode: SQLITE_CORRUPT,
                extendedCode: SQLITE_CORRUPT
            )
        }

        let foreignKeyViolationCount = try rowCount(
            handle: backupHandle,
            sql: "PRAGMA foreign_key_check;"
        )
        guard foreignKeyViolationCount == 0 else {
            throw SQLiteError.backupFailed(
                "SQLite backup contains \(foreignKeyViolationCount) foreign-key violations",
                resultCode: SQLITE_CONSTRAINT,
                extendedCode: SQLITE_CONSTRAINT | (3 << 8)
            )
        }

        var actualCounts: [String: Int] = [:]
        for (table, expectedCount) in expectedTableRowCounts.sorted(by: { $0.key < $1.key }) {
            guard isSafeSQLiteIdentifier(table) else {
                throw SQLiteError.backupFailed(
                    "Unsafe SQLite backup table identifier: \(table)",
                    resultCode: SQLITE_MISUSE,
                    extendedCode: SQLITE_MISUSE
                )
            }
            let values = try queryFirstColumn(
                handle: backupHandle,
                sql: "SELECT COUNT(*) FROM \(table);"
            )
            guard let value = values.first, let actualCount = Int(value) else {
                throw SQLiteError.backupFailed(
                    "SQLite backup could not count table \(table)",
                    resultCode: SQLITE_CORRUPT,
                    extendedCode: SQLITE_CORRUPT
                )
            }
            actualCounts[table] = actualCount
            guard actualCount == expectedCount else {
                throw SQLiteError.backupFailed(
                    "SQLite backup table \(table) expected \(expectedCount) rows but contains \(actualCount)",
                    resultCode: SQLITE_CORRUPT,
                    extendedCode: SQLITE_CORRUPT
                )
            }
        }

        return SQLiteBackupValidationReport(
            integrityOK: integrityOK,
            foreignKeyViolationCount: foreignKeyViolationCount,
            tableRowCounts: actualCounts
        )
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

    /// Runs a write statement and returns SQLite's affected-row count.
    @discardableResult
    public func runAndReturnChanges(_ sql: String, values: [SQLiteValue] = []) throws -> Int {
        try run(sql, values: values)
        let changed = try query("SELECT changes() AS changed;").first?["changed"] ?? nil
        return Int(changed ?? "0") ?? 0
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
                    let byteCount = Int(sqlite3_column_bytes(statement, index))
                    let data = Data(bytes: textPointer, count: byteCount)
                    row[name] = String(decoding: data, as: UTF8.self)
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

    private static func queryFirstColumn(handle: OpaquePointer, sql: String) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.backupFailed(
                Self.message(from: handle),
                resultCode: sqlite3_errcode(handle),
                extendedCode: sqlite3_extended_errcode(handle)
            )
        }
        defer { sqlite3_finalize(statement) }

        var values: [String] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return values }
            guard result == SQLITE_ROW else {
                throw SQLiteError.backupFailed(
                    Self.message(from: handle),
                    resultCode: sqlite3_errcode(handle),
                    extendedCode: sqlite3_extended_errcode(handle)
                )
            }
            if let value = sqlite3_column_text(statement, 0) {
                values.append(String(cString: value))
            } else {
                values.append("")
            }
        }
    }

    private static func rowCount(handle: OpaquePointer, sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.backupFailed(
                Self.message(from: handle),
                resultCode: sqlite3_errcode(handle),
                extendedCode: sqlite3_extended_errcode(handle)
            )
        }
        defer { sqlite3_finalize(statement) }

        var count = 0
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return count }
            guard result == SQLITE_ROW else {
                throw SQLiteError.backupFailed(
                    Self.message(from: handle),
                    resultCode: sqlite3_errcode(handle),
                    extendedCode: sqlite3_extended_errcode(handle)
                )
            }
            count += 1
        }
    }

    private static func isSafeSQLiteIdentifier(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first) else {
            return false
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return value.unicodeScalars.dropFirst().allSatisfy(allowed.contains)
    }
}
