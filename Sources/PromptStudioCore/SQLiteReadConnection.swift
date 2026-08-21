import Foundation
import SQLite3

/// Scalar functions used by summary SQL to preserve the legacy Swift loader's
/// semantics without materializing prompt/reference payloads in the page row.
/// Every SQLite handle (read-only or read/write) registers these independently.
enum LibraryQuerySQLiteFunctions {
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func register(on handle: OpaquePointer) throws {
        let flags = SQLITE_UTF8 | SQLITE_DETERMINISTIC
        let trimResult = sqlite3_create_function_v2(
            handle,
            "ps_trim_whitespace",
            1,
            flags,
            nil,
            sqliteSummaryTrimWhitespaceCallback,
            nil,
            nil,
            nil
        )
        guard trimResult == SQLITE_OK else {
            throw SQLiteError.openFailed(
                "SQLite could not register ps_trim_whitespace",
                resultCode: trimResult,
                extendedCode: sqlite3_extended_errcode(handle)
            )
        }

        let referencesResult = sqlite3_create_function_v2(
            handle,
            "ps_reference_asset_count",
            1,
            flags,
            nil,
            sqliteReferenceAssetCountCallback,
            nil,
            nil,
            nil
        )
        guard referencesResult == SQLITE_OK else {
            throw SQLiteError.openFailed(
                "SQLite could not register ps_reference_asset_count",
                resultCode: referencesResult,
                extendedCode: sqlite3_extended_errcode(handle)
            )
        }
    }

    fileprivate static func textValue(_ value: OpaquePointer?) -> String? {
        guard sqlite3_value_type(value) != SQLITE_NULL,
              let pointer = sqlite3_value_text(value) else {
            return nil
        }
        let byteCount = Int(sqlite3_value_bytes(value))
        let data = Data(bytes: pointer, count: byteCount)
        return String(data: data, encoding: .utf8)
    }

    fileprivate static func setTextResult(_ value: String, on context: OpaquePointer?) {
        let data = Data(value.utf8)
        data.withUnsafeBytes { rawBuffer in
            let pointer = rawBuffer.bindMemory(to: CChar.self).baseAddress
            sqlite3_result_text(context, pointer, Int32(data.count), transientDestructor)
        }
    }
}

private let sqliteSummaryTrimWhitespaceCallback: @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void = { context, argumentCount, arguments in
    guard argumentCount > 0,
          let arguments,
          let input = LibraryQuerySQLiteFunctions.textValue(arguments[0]) else {
        sqlite3_result_null(context)
        return
    }
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    LibraryQuerySQLiteFunctions.setTextResult(trimmed, on: context)
}

private let sqliteReferenceAssetCountCallback: @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void = { context, argumentCount, arguments in
    guard argumentCount > 0,
          let arguments,
          let text = LibraryQuerySQLiteFunctions.textValue(arguments[0]),
          let data = text.data(using: .utf8),
          let references = try? JSONDecoder().decode([ReferenceAsset].self, from: data) else {
        sqlite3_result_int64(context, 0)
        return
    }
    sqlite3_result_int64(context, Int64(references.count))
}

/// A read-only SQLite connection that gives every query its own handle.
///
/// Handles are deliberately not shared with `SQLiteDatabase` (or with another
/// read query), so `sqlite3_interrupt` can stop one cancelled query without
/// interrupting a writer or another read. There is no serial actor queue:
/// independent queries open independent read-only handles and can run in
/// parallel.
public final class SQLiteReadConnection: @unchecked Sendable {
    public typealias QueryStartHook = @Sendable () -> Void
    public typealias QueryPageAndCountHook = @Sendable () -> Void

    public static let defaultBusyTimeoutMilliseconds: Int32 = 5_000

    public let path: String
    public let busyTimeoutMilliseconds: Int32

    private let activeLock = NSLock()
    private var activeQueries: [ObjectIdentifier: SQLiteReadQuery] = [:]
    private let queryStartHook: QueryStartHook?
    private let queryPageAndCountHook: QueryPageAndCountHook?
    private var migrationLeaseID: UUID?

    public init(
        path: String,
        busyTimeoutMilliseconds: Int32 = SQLiteReadConnection.defaultBusyTimeoutMilliseconds,
        queryStartHook: QueryStartHook? = nil,
        queryPageAndCountHook: QueryPageAndCountHook? = nil
    ) throws {
        guard busyTimeoutMilliseconds >= 0 else {
            throw SQLiteError.openFailed(
                "SQLite busy timeout cannot be negative",
                resultCode: SQLITE_MISUSE,
                extendedCode: SQLITE_MISUSE
            )
        }
        self.path = path
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
        self.queryStartHook = queryStartHook
        self.queryPageAndCountHook = queryPageAndCountHook
        self.migrationLeaseID = nil

        // Reserve the path before the probe opens SQLite.  This closes the
        // rollback reservation window for independent read handles; a failed
        // probe releases the preflight lease before propagating its error.
        let preflightLease = try PromptRepositoryMigrationCoordinator.shared.register(path: path)
        self.migrationLeaseID = preflightLease
        do {
            // Open once during initialization so a missing/unreadable database
            // is reported to the caller. Actual queries get fresh independent
            // handles.
            let probe = try SQLiteReadHandle(path: path, busyTimeoutMilliseconds: busyTimeoutMilliseconds)
            probe.close()
        } catch {
            PromptRepositoryMigrationCoordinator.shared.unregister(path: path, lease: preflightLease)
            self.migrationLeaseID = nil
            throw error
        }
    }

    public convenience init(
        url: URL,
        busyTimeoutMilliseconds: Int32 = SQLiteReadConnection.defaultBusyTimeoutMilliseconds,
        queryStartHook: QueryStartHook? = nil,
        queryPageAndCountHook: QueryPageAndCountHook? = nil
    ) throws {
        try self.init(
            path: url.path,
            busyTimeoutMilliseconds: busyTimeoutMilliseconds,
            queryStartHook: queryStartHook,
            queryPageAndCountHook: queryPageAndCountHook
        )
    }

    deinit {
        interrupt()
        if let migrationLeaseID {
            PromptRepositoryMigrationCoordinator.shared.unregister(path: path, lease: migrationLeaseID)
        }
    }

    /// Runs a query using a fresh per-query cancellation token.
    public func query(
        _ sql: String,
        values: [SQLiteValue] = []
    ) async throws -> [[String: String?]] {
        try await query(sql, values: values, cancellation: SQLiteQueryCancellation())
    }

    /// Runs a query with a caller-owned per-query cancellation token.
    public func query(
        _ sql: String,
        values: [SQLiteValue] = [],
        cancellation: SQLiteQueryCancellation
    ) async throws -> [[String: String?]] {
        try await queryAsync(sql, values: values, cancellation: cancellation)
    }

    /// Alias for callers that prefer the explicit token label.
    public func query(
        _ sql: String,
        values: [SQLiteValue] = [],
        cancellationToken: SQLiteQueryCancellation
    ) async throws -> [[String: String?]] {
        try await queryAsync(sql, values: values, cancellation: cancellationToken)
    }

    /// Reads a Summary page and its matching count from one SQLite read
    /// transaction, guaranteeing that both results observe the same snapshot.
    public func queryPageAndCount(
        pageSQL: String,
        pageValues: [SQLiteValue],
        countSQL: String,
        countValues: [SQLiteValue],
        cancellationToken: SQLiteQueryCancellation? = nil
    ) async throws -> LibraryQueryReadBatch {
        try await queryReadBatch(
            firstSQL: pageSQL,
            firstValues: pageValues,
            secondSQL: countSQL,
            secondValues: countValues,
            cancellationToken: cancellationToken
        )
    }

    /// Runs two read queries on one independent handle and one deferred read
    /// transaction. The result sets therefore observe one SQLite snapshot,
    /// while the optional caller-owned token can interrupt either query.
    public func queryReadBatch(
        firstSQL: String,
        firstValues: [SQLiteValue] = [],
        secondSQL: String,
        secondValues: [SQLiteValue] = [],
        cancellationToken: SQLiteQueryCancellation? = nil
    ) async throws -> LibraryQueryReadBatch {
        let cancellation = cancellationToken ?? SQLiteQueryCancellation()
        return try await withTaskCancellationHandler(operation: {
            do {
                try Task.checkCancellation()
                try cancellation.throwIfCancelled()
                let lease = try beginQuery(cancellation: cancellation)
                defer { endQuery(lease) }
                let pageReadComplete = queryPageAndCountHook
                let result = try await Task.detached(priority: nil) {
                    try lease.query.runPageAndCount(
                        pageSQL: firstSQL,
                        pageValues: firstValues,
                        countSQL: secondSQL,
                        countValues: secondValues,
                        cancellation: cancellation,
                        pageReadComplete: pageReadComplete
                    )
                }.value
                try cancellation.throwIfCancelled()
                try Task.checkCancellation()
                return result
            } catch {
                if cancellation.isCancelled || Task.isCancelled {
                    throw CancellationError()
                }
                throw error
            }
        }, onCancel: {
            cancellation.cancel()
        })
    }

    /// Synchronous form for callers that already own a worker thread. A token
    /// can still interrupt the underlying `sqlite3_step` from another thread.
    public func querySync(
        _ sql: String,
        values: [SQLiteValue] = [],
        cancellation: SQLiteQueryCancellation = SQLiteQueryCancellation()
    ) throws -> [[String: String?]] {
        let lease = try beginQuery(cancellation: cancellation)
        defer { endQuery(lease) }
        return try lease.query.run(sql: sql, values: values, cancellation: cancellation)
    }

    /// Interrupts every query currently running on this connection. Normal
    /// task cancellation uses the query's own token and interrupts only that
    /// query's read handle.
    public func interrupt() {
        activeLock.lock()
        let queries = Array(activeQueries.values)
        activeLock.unlock()
        queries.forEach { $0.interrupt() }
    }

    public func interruptAll() {
        interrupt()
    }

    private func queryAsync(
        _ sql: String,
        values: [SQLiteValue],
        cancellation: SQLiteQueryCancellation
    ) async throws -> [[String: String?]] {
        return try await withTaskCancellationHandler(operation: {
            do {
                // Register the cancellation handler before opening a handle.
                // If cancellation races this check, beginQuery's token hook
                // interrupts the newly-opened handle immediately.
                try Task.checkCancellation()
                try cancellation.throwIfCancelled()
                let lease = try beginQuery(cancellation: cancellation)
                defer { endQuery(lease) }
                let result = try await Task.detached(priority: nil) {
                    try lease.query.run(sql: sql, values: values, cancellation: cancellation)
                }.value
                try cancellation.throwIfCancelled()
                try Task.checkCancellation()
                return result
            } catch {
                if cancellation.isCancelled || Task.isCancelled {
                    throw CancellationError()
                }
                throw error
            }
        }, onCancel: {
            cancellation.cancel()
        })
    }

    private func beginQuery(cancellation: SQLiteQueryCancellation) throws -> SQLiteReadQueryLease {
        let query = try SQLiteReadQuery(
            path: path,
            busyTimeoutMilliseconds: busyTimeoutMilliseconds,
            queryStartHook: queryStartHook
        )
        activeLock.lock()
        activeQueries[ObjectIdentifier(query)] = query
        activeLock.unlock()

        let handlerID = cancellation.addInterruptHandler { [query] in
            query.interrupt()
        }
        return SQLiteReadQueryLease(query: query, cancellation: cancellation, handlerID: handlerID)
    }

    private func endQuery(_ lease: SQLiteReadQueryLease) {
        lease.cancellation.removeInterruptHandler(lease.handlerID)
        activeLock.lock()
        activeQueries.removeValue(forKey: ObjectIdentifier(lease.query))
        activeLock.unlock()
        lease.query.close()
    }
}

private final class SQLiteReadQueryLease: @unchecked Sendable {
    let query: SQLiteReadQuery
    let cancellation: SQLiteQueryCancellation
    let handlerID: UUID

    init(query: SQLiteReadQuery, cancellation: SQLiteQueryCancellation, handlerID: UUID) {
        self.query = query
        self.cancellation = cancellation
        self.handlerID = handlerID
    }
}

private final class SQLiteReadQuery: @unchecked Sendable {
    private let handle: SQLiteReadHandle
    private let queryStartHook: SQLiteReadConnection.QueryStartHook?

    init(
        path: String,
        busyTimeoutMilliseconds: Int32,
        queryStartHook: SQLiteReadConnection.QueryStartHook?
    ) throws {
        self.handle = try SQLiteReadHandle(
            path: path,
            busyTimeoutMilliseconds: busyTimeoutMilliseconds
        )
        self.queryStartHook = queryStartHook
    }

    func interrupt() {
        handle.interrupt()
    }

    func close() {
        handle.close()
    }

    func run(
        sql: String,
        values: [SQLiteValue],
        cancellation: SQLiteQueryCancellation
    ) throws -> [[String: String?]] {
        try cancellation.throwIfCancelled()
        guard let pointer = handle.pointer else {
            throw SQLiteError.stepFailed(
                "SQLite read handle is closed",
                resultCode: SQLITE_MISUSE,
                extendedCode: SQLITE_MISUSE
            )
        }

        let progressContext = SQLiteProgressContext(
            cancellation: cancellation,
            queryStartHook: queryStartHook
        )
        let progressPointer = Unmanaged.passUnretained(progressContext).toOpaque()
        sqlite3_progress_handler(pointer, 1_000, sqliteReadProgressCallback, progressPointer)
        defer { sqlite3_progress_handler(pointer, 0, nil, nil) }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(pointer, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK else {
            if prepareResult == SQLITE_INTERRUPT, cancellation.isCancelled {
                throw CancellationError()
            }
            throw SQLiteError.prepareFailed(
                Self.message(from: pointer),
                resultCode: prepareResult,
                extendedCode: sqlite3_extended_errcode(pointer)
            )
        }
        defer { sqlite3_finalize(statement) }

        try cancellation.throwIfCancelled()
        try bind(values, to: statement, handle: pointer)
        try cancellation.throwIfCancelled()

        var rows: [[String: String?]] = []
        while true {
            try cancellation.throwIfCancelled()
            progressContext.willEnterStep()
            let result = sqlite3_step(statement)
            progressContext.didLeaveStep()
            switch result {
            case SQLITE_ROW:
                try cancellation.throwIfCancelled()
                rows.append(Self.readRow(from: statement))
                try cancellation.throwIfCancelled()
            case SQLITE_DONE:
                try cancellation.throwIfCancelled()
                return rows
            default:
                if result == SQLITE_INTERRUPT, cancellation.isCancelled {
                    throw CancellationError()
                }
                throw SQLiteError.stepFailed(
                    Self.message(from: pointer),
                    resultCode: result,
                    extendedCode: sqlite3_extended_errcode(pointer)
                )
            }
        }
    }

    func runPageAndCount(
        pageSQL: String,
        pageValues: [SQLiteValue],
        countSQL: String,
        countValues: [SQLiteValue],
        cancellation: SQLiteQueryCancellation,
        pageReadComplete: SQLiteReadConnection.QueryPageAndCountHook?
    ) throws -> LibraryQueryReadBatch {
        _ = try run(sql: "BEGIN DEFERRED TRANSACTION;", values: [], cancellation: cancellation)
        do {
            let pageRows = try run(sql: pageSQL, values: pageValues, cancellation: cancellation)
            pageReadComplete?()
            let countRows = try run(sql: countSQL, values: countValues, cancellation: cancellation)
            _ = try run(sql: "COMMIT;", values: [], cancellation: cancellation)
            return LibraryQueryReadBatch(pageRows: pageRows, countRows: countRows)
        } catch {
            // Closing the read handle rolls back an open transaction. Avoid a
            // second SQLite call here because cancellation may already have
            // interrupted the handle.
            throw error
        }
    }

    private func bind(
        _ values: [SQLiteValue],
        to statement: OpaquePointer?,
        handle: OpaquePointer
    ) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text):
                result = text.withCString {
                    sqlite3_bind_text(statement, index, $0, -1, transient)
                }
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
                    resultCode: result,
                    extendedCode: sqlite3_extended_errcode(handle)
                )
            }
        }
    }

    private static func readRow(from statement: OpaquePointer?) -> [String: String?] {
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
        return row
    }

    private static func message(from handle: OpaquePointer?) -> String {
        guard let pointer = sqlite3_errmsg(handle) else {
            return "SQLite operation failed"
        }
        return String(cString: pointer)
    }
}

private final class SQLiteProgressContext: @unchecked Sendable {
    private let cancellation: SQLiteQueryCancellation
    private let queryStartHook: SQLiteReadConnection.QueryStartHook?
    private let lock = NSLock()
    private var stepIsActive = false
    private var didNotifyStepStart = false

    init(
        cancellation: SQLiteQueryCancellation,
        queryStartHook: SQLiteReadConnection.QueryStartHook?
    ) {
        self.cancellation = cancellation
        self.queryStartHook = queryStartHook
    }

    func willEnterStep() {
        lock.lock()
        stepIsActive = true
        lock.unlock()
    }

    func didLeaveStep() {
        lock.lock()
        stepIsActive = false
        lock.unlock()
    }

    func progressResult() -> Int32 {
        let notify: Bool
        lock.lock()
        notify = stepIsActive && !didNotifyStepStart
        if notify {
            didNotifyStepStart = true
        }
        lock.unlock()

        if notify {
            queryStartHook?()
        }
        return cancellation.isCancelled ? 1 : 0
    }
}

private final class SQLiteReadHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: OpaquePointer?

    var pointer: OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    init(path: String, busyTimeoutMilliseconds: Int32) throws {
        var opened: OpaquePointer?
        let openResult = path.withCString {
            sqlite3_open_v2(
                $0,
                &opened,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                nil
            )
        }
        guard openResult == SQLITE_OK, let opened else {
            let message = Self.message(from: opened)
            let extendedCode = sqlite3_extended_errcode(opened)
            sqlite3_close(opened)
            throw SQLiteError.openFailed(
                message,
                resultCode: openResult,
                extendedCode: extendedCode
            )
        }

        sqlite3_extended_result_codes(opened, 1)
        let timeoutResult = sqlite3_busy_timeout(opened, busyTimeoutMilliseconds)
        guard timeoutResult == SQLITE_OK else {
            let message = Self.message(from: opened)
            let extendedCode = sqlite3_extended_errcode(opened)
            sqlite3_close(opened)
            throw SQLiteError.openFailed(
                message,
                resultCode: timeoutResult,
                extendedCode: extendedCode
            )
        }
        do {
            try LibraryQuerySQLiteFunctions.register(on: opened)
        } catch {
            sqlite3_close(opened)
            throw error
        }
        storage = opened
    }

    func interrupt() {
        lock.lock()
        if let storage {
            sqlite3_interrupt(storage)
        }
        lock.unlock()
    }

    func close() {
        lock.lock()
        guard let storage else {
            lock.unlock()
            return
        }
        self.storage = nil
        sqlite3_close(storage)
        lock.unlock()
    }

    deinit {
        close()
    }

    private static func message(from handle: OpaquePointer?) -> String {
        guard let pointer = sqlite3_errmsg(handle) else {
            return "SQLite operation failed"
        }
        return String(cString: pointer)
    }
}

private let sqliteReadProgressCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { context in
    guard let context else { return 0 }
    let progressContext = Unmanaged<SQLiteProgressContext>
        .fromOpaque(context)
        .takeUnretainedValue()
    return progressContext.progressResult()
}

extension SQLiteReadConnection: LibraryQueryRowExecutor {
    public func query(
        sql: String,
        values: [SQLiteValue]
    ) async throws -> [[String: String?]] {
        try await query(sql, values: values)
    }

    /// Witnesses the row-executor snapshot operation with the protocol's
    /// cancellation-free signature. The more specific overload above owns
    /// the single-handle transaction; forwarding here avoids the protocol
    /// extension's two independent-query fallback.
    public func queryPageAndCount(
        pageSQL: String,
        pageValues: [SQLiteValue],
        countSQL: String,
        countValues: [SQLiteValue]
    ) async throws -> LibraryQueryReadBatch {
        try await queryPageAndCount(
            pageSQL: pageSQL,
            pageValues: pageValues,
            countSQL: countSQL,
            countValues: countValues,
            cancellationToken: nil
        )
    }
}
