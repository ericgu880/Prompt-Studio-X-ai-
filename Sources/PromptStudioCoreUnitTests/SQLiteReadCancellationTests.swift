import Foundation
import PromptStudioCore
import SQLite3

private let sqliteReadCancellationSlowQuery = """
WITH RECURSIVE spin(value) AS (
    SELECT 0
    UNION ALL
    SELECT value + 1 FROM spin WHERE value < 100000000
)
SELECT value FROM spin;
"""

private func waitForSQLiteReadStep(
    _ starts: DispatchSemaphore,
    label: String
) throws {
    guard starts.wait(timeout: DispatchTime.now() + .seconds(5)) == .success else {
        throw CoreUnitTestError.failure("\(label) did not enter sqlite3_step within 5 seconds")
    }
}

private func expectNoSQLiteReadStep(_ starts: DispatchSemaphore) throws {
    guard starts.wait(timeout: .now() + .milliseconds(100)) == .timedOut else {
        throw CoreUnitTestError.failure("a task cancelled before query start should not enter sqlite3_step")
    }
}

private func sqliteInterruptResultCode(_ error: Error) -> Int32? {
    switch error {
    case let SQLiteError.prepareFailed(_, resultCode, _),
         let SQLiteError.stepFailed(_, resultCode, _):
        return resultCode
    default:
        return nil
    }
}

private func sqliteReadCancellationFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PromptStudioSQLiteReadCancellationTests")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let databaseURL = root.appendingPathComponent("read-cancellation.sqlite")
    let writer = try SQLiteDatabase(path: databaseURL.path)
    try writer.execute("CREATE TABLE fixture(value INTEGER NOT NULL);")
    try writer.execute("INSERT INTO fixture(value) VALUES (1), (2), (3);")
    return databaseURL
}

private func assertSQLiteReadCancellation(
    _ task: Task<[[String: String?]], Error>,
    label: String
) async throws {
    do {
        _ = try await task.value
        throw CoreUnitTestError.failure("\(label) should throw CancellationError")
    } catch is CancellationError {
        return
    } catch {
        throw CoreUnitTestError.failure("\(label) should throw CancellationError, got \(error)")
    }
}

func runSQLiteReadCancellationTests() async throws {
    try await testSQLiteReadCancellationAlreadyCancelledBeforeHandle()
    try await testSQLiteReadCancellationAllowsNextQueryImmediately()
    try await testSQLiteReadCancellationDoesNotBuildBacklogAcrossFiftySwitches()
    try await testSQLiteReadCancellationLeavesWriterIndependent()
    try await testSQLiteReadConnectionBindsSQLiteValues()
    try await testSQLiteReadConnectionRejectsWrites()
    try await testSQLiteReadConnectionPropagatesStepErrors()
    try await testSQLiteReadConnectionPreservesExternalInterruptCode()
}

private func testSQLiteReadCancellationAlreadyCancelledBeforeHandle() async throws {
    let databaseURL = try sqliteReadCancellationFixture()
    let starts = DispatchSemaphore(value: 0)
    let readConnection = try SQLiteReadConnection(path: databaseURL.path) {
        starts.signal()
    }
    let ready = DispatchSemaphore(value: 0)
    let gate = DispatchSemaphore(value: 0)
    let task = Task {
        ready.signal()
        try waitForSQLiteReadStep(gate, label: "pre-cancel task gate")
        return try await readConnection.query("SELECT 1 AS value;")
    }

    try waitForSQLiteReadStep(ready, label: "pre-cancel task readiness")
    task.cancel()
    gate.signal()
    try await assertSQLiteReadCancellation(task, label: "pre-cancelled read")
    try expectNoSQLiteReadStep(starts)
}

private func testSQLiteReadCancellationAllowsNextQueryImmediately() async throws {
    let databaseURL = try sqliteReadCancellationFixture()
    let starts = DispatchSemaphore(value: 0)
    let readConnection = try SQLiteReadConnection(path: databaseURL.path) {
        starts.signal()
    }
    let first = Task {
        try await readConnection.query(sqliteReadCancellationSlowQuery)
    }
    let second = Task {
        try await readConnection.query(sqliteReadCancellationSlowQuery)
    }

    try waitForSQLiteReadStep(starts, label: "first slow read")
    try waitForSQLiteReadStep(starts, label: "second slow read")
    first.cancel()
    second.cancel()

    let started = DispatchTime.now().uptimeNanoseconds
    let rows = try await readConnection.query("SELECT 7 AS value;")
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
    try expect(rows.first?["value"] == "7", "a read after cancellation should return its row")
    try expect(elapsed < 0.5, "a read after cancellation should not wait behind cancelled reads (\(elapsed)s)")
    try await assertSQLiteReadCancellation(first, label: "first slow read")
    try await assertSQLiteReadCancellation(second, label: "second slow read")
}

private func testSQLiteReadCancellationDoesNotBuildBacklogAcrossFiftySwitches() async throws {
    let databaseURL = try sqliteReadCancellationFixture()
    let starts = DispatchSemaphore(value: 0)
    let readConnection = try SQLiteReadConnection(path: databaseURL.path) {
        starts.signal()
    }
    var maximumCancellationLatency = 0.0
    var cancellationLatencies: [Double] = []
    let overlapWidth = 4

    // Keep a small overlapping set so the test exercises cancellation while
    // multiple handles are in sqlite3_step without relying on an unbounded
    // executor thread pool. Repeat that overlap for 50 total switches.
    for batchStart in stride(from: 0, to: 50, by: overlapWidth) {
        let batchCount = min(overlapWidth, 50 - batchStart)
        var tasks: [Task<[[String: String?]], Error>] = []
        for _ in 0..<batchCount {
            tasks.append(Task {
                try await readConnection.query(sqliteReadCancellationSlowQuery)
            })
        }
        for offset in 0..<batchCount {
            try waitForSQLiteReadStep(starts, label: "switch \(batchStart + offset)")
        }

        let cancellationStarted = DispatchTime.now().uptimeNanoseconds
        tasks.forEach { $0.cancel() }
        for (offset, task) in tasks.enumerated() {
            let index = batchStart + offset
            try await assertSQLiteReadCancellation(task, label: "switch \(index)")
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - cancellationStarted) / 1_000_000_000
            maximumCancellationLatency = max(maximumCancellationLatency, elapsed)
            cancellationLatencies.append(elapsed)
        }
    }

    let orderedLatencies = cancellationLatencies.sorted()
    let p50 = orderedLatencies[max(0, Int(ceil(Double(orderedLatencies.count) * 0.50)) - 1)]
    let p95 = orderedLatencies[max(0, Int(ceil(Double(orderedLatencies.count) * 0.95)) - 1)]
    print(String(
        format: "SQLite read cancellation across 50 switches: p50=%.4fms p95=%.4fms max=%.4fms",
        p50 * 1_000,
        p95 * 1_000,
        maximumCancellationLatency * 1_000
    ))
    try expect(
        maximumCancellationLatency < 0.5,
        "fifty cancelled reads should not accumulate a backlog (max cancellation latency \(maximumCancellationLatency)s)"
    )
}

private func testSQLiteReadCancellationLeavesWriterIndependent() async throws {
    let databaseURL = try sqliteReadCancellationFixture()
    let starts = DispatchSemaphore(value: 0)
    let readConnection = try SQLiteReadConnection(path: databaseURL.path) {
        starts.signal()
    }
    let readTask = Task {
        try await readConnection.query(sqliteReadCancellationSlowQuery)
    }

    try waitForSQLiteReadStep(starts, label: "writer isolation read")
    let writerTask = Task.detached {
        let writer = try SQLiteDatabase(path: databaseURL.path, mode: .existingReadWrite)
        try writer.transaction {
            try writer.run("INSERT INTO fixture(value) VALUES (?);", values: [.int(4)])
        }
    }
    readTask.cancel()
    try await assertSQLiteReadCancellation(readTask, label: "writer isolation read")
    do {
        try await writerTask.value
    } catch let SQLiteError.stepFailed(_, resultCode, _)
        where resultCode == SQLITE_BUSY || resultCode == SQLITE_LOCKED {
        throw CoreUnitTestError.failure("writer transaction should not fail with SQLITE_BUSY/SQLITE_LOCKED")
    } catch let SQLiteError.openFailed(_, resultCode, _)
        where resultCode == SQLITE_BUSY || resultCode == SQLITE_LOCKED {
        throw CoreUnitTestError.failure("writer open should not fail with SQLITE_BUSY/SQLITE_LOCKED")
    } catch {
        throw CoreUnitTestError.failure("writer transaction should finish without SQLite errors: \(error)")
    }

    let writer = try SQLiteDatabase(path: databaseURL.path, mode: .existingReadWrite)
    let rows = try writer.query("SELECT value FROM fixture ORDER BY value;")
    try expect(rows.compactMap { $0["value"] ?? nil } == ["1", "2", "3", "4"], "writer transaction should finish after read interruption")
}

private func testSQLiteReadConnectionBindsSQLiteValues() async throws {
    let databaseURL = try sqliteReadCancellationFixture()
    let readConnection = try SQLiteReadConnection(path: databaseURL.path)
    let rows = try await readConnection.query(
        "SELECT ? AS text, ? AS int, ? AS double, ? AS null_value;",
        values: [.text("bound"), .int(42), .double(1.5), .null]
    )
    try expect(rows.first?["text"] == "bound", "read queries should bind SQLiteValue.text")
    try expect(rows.first?["int"] == "42", "read queries should bind SQLiteValue.int")
    try expect(rows.first?["double"] == "1.5", "read queries should bind SQLiteValue.double")
    try expect(rows.first?["null_value"] == nil, "read queries should bind SQLiteValue.null")
}

private func testSQLiteReadConnectionRejectsWrites() async throws {
    let databaseURL = try sqliteReadCancellationFixture()
    let readConnection = try SQLiteReadConnection(path: databaseURL.path)
    for sql in [
        "CREATE TABLE should_not_exist(value INTEGER);",
        "INSERT INTO fixture(value) VALUES (99);"
    ] {
        do {
            _ = try await readConnection.query(sql)
            throw CoreUnitTestError.failure("read-only query should reject write SQL: \(sql)")
        } catch let SQLiteError.prepareFailed(_, resultCode, _),
                let SQLiteError.stepFailed(_, resultCode, _) {
            let primaryCode = resultCode & 0xFF
            try expect(
                primaryCode == SQLITE_READONLY,
                "read-only write rejection should report SQLITE_READONLY, got \(resultCode)"
            )
        } catch {
            throw CoreUnitTestError.failure("read-only write rejection should report SQLITE_READONLY, got \(error)")
        }
    }
}

private func testSQLiteReadConnectionPropagatesStepErrors() async throws {
    let databaseURL = try sqliteReadCancellationFixture()
    let readConnection = try SQLiteReadConnection(path: databaseURL.path)
    do {
        _ = try await readConnection.query("SELECT abs(-9223372036854775808) AS value;")
        throw CoreUnitTestError.failure("a SQLite step error must be returned to the caller")
    } catch let SQLiteError.stepFailed(_, resultCode, _) {
        try expect(resultCode == SQLITE_ERROR, "integer overflow should surface as SQLITE_ERROR")
    }
}

private func testSQLiteReadConnectionPreservesExternalInterruptCode() async throws {
    let databaseURL = try sqliteReadCancellationFixture()
    let starts = DispatchSemaphore(value: 0)
    let readConnection = try SQLiteReadConnection(path: databaseURL.path) {
        starts.signal()
    }
    let token = SQLiteQueryCancellation()
    let task = Task {
        try await readConnection.query(sqliteReadCancellationSlowQuery, cancellation: token)
    }

    try waitForSQLiteReadStep(starts, label: "external interrupt read")
    readConnection.interrupt()
    do {
        _ = try await task.value
        throw CoreUnitTestError.failure("an external read interrupt should stop the slow query")
    } catch {
        guard let resultCode = sqliteInterruptResultCode(error) else {
            throw CoreUnitTestError.failure("an external read interrupt should report SQLITE_INTERRUPT, got \(error)")
        }
        try expect(resultCode == SQLITE_INTERRUPT, "an external read interrupt should preserve SQLITE_INTERRUPT")
    }
}
