import Foundation
import PromptStudioCore
@preconcurrency import Darwin

private struct Arguments {
    let fixtureRoot: URL
    let outputURL: URL
    let fixtureNames: [String]

    static func parse() throws -> Arguments? {
        let values = Array(CommandLine.arguments.dropFirst())
        if values.contains("--help") || values.isEmpty {
            print("Usage: PromptStudioLibraryQueryBenchmark --fixture-root <path> --output <json> [--fixtures name1,name2]")
            return nil
        }
        guard let rootIndex = values.firstIndex(of: "--fixture-root"), rootIndex + 1 < values.count,
              let outputIndex = values.firstIndex(of: "--output"), outputIndex + 1 < values.count else {
            throw BenchmarkError.invalidArguments
        }
        let requestedPaths = [values[rootIndex + 1], values[outputIndex + 1]]
        guard requestedPaths.allSatisfy({ !$0.contains("PromptStudio Library") }) else {
            throw BenchmarkError.invalidArguments
        }
        let fixtureNames: [String]
        if let fixturesIndex = values.firstIndex(of: "--fixtures"), fixturesIndex + 1 < values.count {
            fixtureNames = values[fixturesIndex + 1]
                .split(separator: ",")
                .map(String.init)
                .filter { !$0.isEmpty }
            guard !fixtureNames.isEmpty else { throw BenchmarkError.invalidArguments }
        } else {
            fixtureNames = ["library-15959", "library-50000", "library-100000"]
        }
        return Arguments(
            fixtureRoot: URL(fileURLWithPath: values[rootIndex + 1], isDirectory: true),
            outputURL: URL(fileURLWithPath: values[outputIndex + 1]),
            fixtureNames: fixtureNames
        )
    }
}

private enum BenchmarkError: Error, LocalizedError {
    case invalidArguments
    case malformedGolden(String)
    case goldenMismatch(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments: "invalid benchmark arguments"
        case .malformedGolden(let field): "malformed golden field: \(field)"
        case .goldenMismatch(let query): "shadow query differs from golden result: \(query)"
        }
    }
}

private protocol BenchmarkTimedExecutor: LibraryQueryRowExecutor {
    func takeDurations() -> [Double]
}

private final class TimedReadExecutor: BenchmarkTimedExecutor, @unchecked Sendable {
    private let connection: SQLiteReadConnection
    private let lock = NSLock()
    private var recorded: [Double] = []

    init(path: String) throws {
        connection = try SQLiteReadConnection(path: path)
    }

    func query(sql: String, values: [SQLiteValue]) async throws -> [[String: String?]] {
        let start = DispatchTime.now().uptimeNanoseconds
        let rows = try await connection.query(sql, values: values)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        lock.withLock {
            recorded.append(elapsed)
        }
        return rows
    }

    func queryPageAndCount(
        pageSQL: String,
        pageValues: [SQLiteValue],
        countSQL: String,
        countValues: [SQLiteValue]
    ) async throws -> LibraryQueryReadBatch {
        let start = DispatchTime.now().uptimeNanoseconds
        let batch = try await connection.queryPageAndCount(
            pageSQL: pageSQL,
            pageValues: pageValues,
            countSQL: countSQL,
            countValues: countValues
        )
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        lock.withLock {
            // Snapshot reads intentionally expose one combined SQLite timing.
            recorded.append(elapsed)
            recorded.append(0)
        }
        return batch
    }

    func takeDurations() -> [Double] {
        lock.withLock {
            let result = recorded
            recorded.removeAll(keepingCapacity: true)
            return result
        }
    }
}

private struct Golden {
    let itemCount: Int
    let folderID: String
    let modelID: String
    let type: PromptType
    let idsByQuery: [String: [String]]

    init(url: URL) throws {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let root = object as? [String: Any],
              let itemCount = root["itemCount"] as? Int,
              let parameters = root["parameters"] as? [String: Any],
              let folderID = parameters["folderId"] as? String,
              let modelID = parameters["modelId"] as? String,
              let rawType = parameters["type"] as? String,
              let type = PromptType(rawValue: rawType),
              let queries = root["queries"] as? [String: Any] else {
            throw BenchmarkError.malformedGolden(url.path)
        }
        var idsByQuery: [String: [String]] = [:]
        for (name, value) in queries {
            guard let query = value as? [String: Any], let ids = query["ids"] as? [String] else {
                throw BenchmarkError.malformedGolden("queries.\(name).ids")
            }
            idsByQuery[name] = ids
        }
        self.itemCount = itemCount
        self.folderID = folderID
        self.modelID = modelID
        self.type = type
        self.idsByQuery = idsByQuery
    }
}

private func queries(golden: Golden) -> [(String, LibraryQuery)] {
    [
        ("all", LibraryQuery(.all)),
        ("folder", LibraryQuery(.folder(golden.folderID))),
        ("type", LibraryQuery(.type(golden.type))),
        ("model", LibraryQuery(.model(golden.modelID))),
        ("favorite", LibraryQuery(.favorite)),
        ("combined", LibraryQuery(.folder(golden.folderID), type: golden.type, modelId: golden.modelID, favoriteOnly: true)),
        ("recent", LibraryQuery(.recent)),
        ("trash", LibraryQuery(.trash))
    ]
}

private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let ordered = values.sorted()
    let index = max(0, min(ordered.count - 1, Int(ceil(Double(ordered.count) * fraction)) - 1))
    return ordered[index]
}

private func stats(_ values: [Double]) -> [String: Any] {
    ["p50Milliseconds": percentile(values, 0.50), "p95Milliseconds": percentile(values, 0.95)]
}

private func backupFixture(from source: URL, to destination: URL) throws {
    let manager = FileManager.default
    try? manager.removeItem(at: destination)
    try manager.copyItem(at: source, to: destination)
    for suffix in ["-wal", "-shm"] {
        try? manager.removeItem(atPath: destination.path + suffix)
    }
}

private func cloneFixture(sourceDatabase: URL, destinationLibrary: URL) throws {
    let manager = FileManager.default
    try? manager.removeItem(at: destinationLibrary)
    let databaseDirectory = destinationLibrary.appendingPathComponent("database", isDirectory: true)
    try manager.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
    try backupFixture(
        from: sourceDatabase,
        to: databaseDirectory.appendingPathComponent("promptstudio.sqlite")
    )
}

private func migrateFixture(_ libraryURL: URL) throws -> PromptRepository {
    let repository = try PromptRepository(libraryURL: libraryURL)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 500)
    guard repository.versionSequenceMigrationReady else {
        throw BenchmarkError.malformedGolden("version-sequence migration did not become ready")
    }
    // Golden IDs/fields are loaded from the legacy fixture before this helper
    // is called.  Runtime Summary SQL now requires the explicit item-sequence
    // gate, so make each isolated benchmark clone ready after that legacy
    // golden has been captured.
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 500)
    guard repository.itemSequenceMigrationReady else {
        throw BenchmarkError.malformedGolden("item-sequence migration did not become ready")
    }
    return repository
}

private func explain(
    databasePath: String,
    query: LibraryQuery,
    capabilities: LibraryQueryCapabilities
) throws -> [String] {
    let database = try SQLiteDatabase(path: databasePath, mode: .existingReadWrite)
    let built = try LibraryQuerySQLBuilder.build(query, capabilities: capabilities)
    return try database.query("EXPLAIN QUERY PLAN \(built.sql)", values: built.values)
        .compactMap { $0["detail"] ?? nil }
}

private func explainCount(
    databasePath: String,
    query: LibraryQuery,
    capabilities: LibraryQueryCapabilities
) throws -> [String] {
    let database = try SQLiteDatabase(path: databasePath, mode: .existingReadWrite)
    let built = try LibraryQuerySQLBuilder.buildCount(query, capabilities: capabilities)
    return try database.query("EXPLAIN QUERY PLAN \(built.sql)", values: built.values)
        .compactMap { $0["detail"] ?? nil }
}

private func benchmarkFirstPage<Executor: BenchmarkTimedExecutor>(
    service: LibraryQueryService,
    executor: Executor,
    query: LibraryQuery,
    iterations: Int
) async throws -> [String: Any] {
    for _ in 0..<2 {
        _ = try await service.query(query)
        _ = executor.takeDurations()
    }
    var total: [Double] = []
    var sql: [Double] = []
    var count: [Double] = []
    var decode: [Double] = []
    for _ in 0..<iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try await service.query(query)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        let calls = executor.takeDurations()
        total.append(elapsed)
        sql.append(calls.first ?? 0)
        count.append(calls.dropFirst().first ?? 0)
        decode.append(max(0, elapsed - calls.reduce(0, +)))
    }
    return ["sql": stats(sql), "count": stats(count), "decode": stats(decode), "total": stats(total)]
}

private func loadAllIDs(
    service: LibraryQueryService,
    baseQuery: LibraryQuery
) async throws -> ([String], [Double]) {
    var ids: [String] = []
    var pageDurations: [Double] = []
    var cursor: LibraryItemCursor?
    repeat {
        var query = baseQuery
        query.cursor = cursor
        let start = DispatchTime.now().uptimeNanoseconds
        let page = try await service.query(query)
        pageDurations.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        ids.append(contentsOf: page.items.map(\.id))
        cursor = page.nextCursor
    } while cursor != nil
    return (ids, pageDurations)
}

private func estimatedSummaryBytes(_ summaries: [LibraryItemSummary]) -> Int {
    summaries.reduce(0) { partial, item in
        partial + MemoryLayout<LibraryItemSummary>.stride
            + item.id.utf8.count + item.title.utf8.count
            + item.modelId.utf8.count + item.modelName.utf8.count
            + item.folderId.utf8.count + item.folderName.utf8.count
            + item.category.utf8.count + item.assetPath.utf8.count
            + item.thumbnailPath.utf8.count + item.aspectRatio.utf8.count
            + item.format.utf8.count
    }
}

private func residentMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(
                mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                $0,
                &count
            )
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}

private func benchmarkSummaryMemory(service: LibraryQueryService) async throws -> [String: Any] {
    let idle = residentMemoryBytes()
    var retained: [LibraryItemSummary] = []
    var query = LibraryQuery(.all)
    var after300 = idle
    for pageIndex in 0..<10 {
        let page = try await service.query(query)
        retained.append(contentsOf: page.items)
        if pageIndex == 0 {
            after300 = residentMemoryBytes()
        }
        guard let cursor = page.nextCursor else { break }
        query.cursor = cursor
    }
    let after3000 = residentMemoryBytes()
    return withExtendedLifetime(retained) {
        [
            "processResidentBytesAtServiceIdle": idle,
            "processResidentBytesWith300Summaries": after300,
            "processResidentBytesWith3000Summaries": after3000,
            "residentDelta300Bytes": Int64(after300) - Int64(idle),
            "residentDelta3000Bytes": Int64(after3000) - Int64(idle),
            "retainedSummaryCount": retained.count,
            "estimatedRetainedSummaryBytes": estimatedSummaryBytes(retained)
        ]
    }
}

private func insertBenchmarkRows(repository: PromptRepository, count: Int) throws -> Double {
    let createdAt = Date(timeIntervalSince1970: 1_767_225_600)
    let items = (0..<count).map { index in
        PromptItem(
            id: "write-benchmark-\(index)",
            title: "write-benchmark-\(index)",
            type: .image,
            assetKind: .image,
            modelId: "model-write",
            modelName: "Model",
            folderId: "folder-write",
            folderName: "Folder",
            category: "fixture",
            assetPath: "assets/write-benchmark-\(index).png",
            aspectRatio: "1:1",
            width: 512,
            height: 512,
            format: "PNG",
            fileSize: 1024,
            createdAt: createdAt,
            updatedAt: createdAt,
            lastUsedAt: Date(timeIntervalSince1970: 0),
            sortOrder: index,
            versions: []
        )
    }
    let start = DispatchTime.now().uptimeNanoseconds
    try repository.saveItems(items)
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

private func runFixture(_ libraryURL: URL) async throws -> [String: Any] {
    let source = libraryURL.appendingPathComponent("database/promptstudio.sqlite")
    let golden = try Golden(url: libraryURL.appendingPathComponent("golden-results.json"))
    let work = FileManager.default.temporaryDirectory
        .appendingPathComponent("PromptStudioPhase2A1Benchmark-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let unindexedLibrary = work.appendingPathComponent("unindexed-library", isDirectory: true)
    let indexedLibrary = work.appendingPathComponent("indexed-library", isDirectory: true)
    let unindexedWriteLibrary = work.appendingPathComponent("unindexed-write-library", isDirectory: true)
    let indexedWriteLibrary = work.appendingPathComponent("indexed-write-library", isDirectory: true)
    try cloneFixture(sourceDatabase: source, destinationLibrary: unindexedLibrary)
    try cloneFixture(sourceDatabase: source, destinationLibrary: indexedLibrary)
    try cloneFixture(sourceDatabase: source, destinationLibrary: unindexedWriteLibrary)
    try cloneFixture(sourceDatabase: source, destinationLibrary: indexedWriteLibrary)

    // Every benchmark connection is a migration-ready isolated fixture. The
    // unindexed variants intentionally drop only the latest-version index after
    // migration so EXPLAIN still compares the real runtime SQL contract.
    let unindexedRepository = try migrateFixture(unindexedLibrary)
    let indexedRepository = try migrateFixture(indexedLibrary)
    let unindexedWriteRepository = try migrateFixture(unindexedWriteLibrary)
    let indexedWriteRepository = try migrateFixture(indexedWriteLibrary)
    let unindexed = unindexedRepository.databaseURL
    let indexed = indexedRepository.databaseURL
    let unindexedWrite = unindexedWriteRepository.databaseURL
    let indexedWrite = indexedWriteRepository.databaseURL
    for databaseURL in [unindexed, unindexedWrite] {
        let database = try SQLiteDatabase(path: databaseURL.path, mode: .existingReadWrite)
        try database.execute("DROP INDEX IF EXISTS idx_phase2a4_prompt_versions_latest;")
    }

    let indexDatabase = try SQLiteDatabase(path: indexed.path, mode: .existingReadWrite)
    let indexStarted = DispatchTime.now().uptimeNanoseconds
    try LibraryQuerySQLBuilder.installPhase2A1Indexes(using: { try indexDatabase.execute($0) })
    let indexMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - indexStarted) / 1_000_000
    let indexedWriteDatabase = try SQLiteDatabase(path: indexedWrite.path, mode: .existingReadWrite)
    try LibraryQuerySQLBuilder.installPhase2A1Indexes(using: { try indexedWriteDatabase.execute($0) })

    let read = try TimedReadExecutor(path: indexed.path)
    let capabilities = LibraryQueryCapabilities.runtime(for: indexedRepository)
    let service = LibraryQueryService(executor: read, capabilities: capabilities)
    let memoryReport = try await benchmarkSummaryMemory(service: service)
    _ = read.takeDurations()
    var queryReports: [String: Any] = [:]
    var memory300 = 0
    var memory3000 = 0
    for (name, query) in queries(golden: golden) {
        let prePlan = try explain(databasePath: unindexed.path, query: query, capabilities: capabilities)
        let postPlan = try explain(databasePath: indexed.path, query: query, capabilities: capabilities)
        let preCountPlan = try explainCount(databasePath: unindexed.path, query: query, capabilities: capabilities)
        let postCountPlan = try explainCount(databasePath: indexed.path, query: query, capabilities: capabilities)
        let firstPage = try await benchmarkFirstPage(service: service, executor: read, query: query, iterations: 20)
        let (actualIDs, pageDurations) = try await loadAllIDs(service: service, baseQuery: query)
        guard actualIDs == golden.idsByQuery[name] else { throw BenchmarkError.goldenMismatch(name) }

        var firstTenQuery = query
        var firstTenItems: [LibraryItemSummary] = []
        var firstTenDurations: [Double] = []
        for _ in 0..<10 {
            let started = DispatchTime.now().uptimeNanoseconds
            let page = try await service.query(firstTenQuery)
            firstTenDurations.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            firstTenItems.append(contentsOf: page.items)
            guard let cursor = page.nextCursor else { break }
            firstTenQuery.cursor = cursor
        }
        if name == "all" {
            memory300 = estimatedSummaryBytes(Array(firstTenItems.prefix(300)))
            memory3000 = estimatedSummaryBytes(Array(firstTenItems.prefix(3_000)))
        }
        queryReports[name] = [
            "firstPage": firstPage,
            "tenPages": stats(firstTenDurations),
            "allPages": stats(pageDurations),
            "pageCount": pageDurations.count,
            "goldenCount": actualIDs.count,
            "goldenMatch": true,
            "preIndexExplain": prePlan,
            "postIndexExplain": postPlan,
            "preIndexCountExplain": preCountPlan,
            "postIndexCountExplain": postCountPlan
        ]
    }

    let unindexedWriteMilliseconds = try insertBenchmarkRows(repository: unindexedWriteRepository, count: 1_000)
    let indexedWriteMilliseconds = try insertBenchmarkRows(repository: indexedWriteRepository, count: 1_000)
    return [
        "itemCount": golden.itemCount,
        "summaryStrideBytes": MemoryLayout<LibraryItemSummary>.stride,
        "estimatedSummaryBytes300": memory300,
        "estimatedSummaryBytes3000": memory3000,
        "memory": memoryReport,
        "indexInstallMilliseconds": indexMilliseconds,
        "write1000": [
            "withoutIndexesMilliseconds": unindexedWriteMilliseconds,
            "withIndexesMilliseconds": indexedWriteMilliseconds,
            "ratio": indexedWriteMilliseconds / max(unindexedWriteMilliseconds, 0.001)
        ],
        "queries": queryReports
    ]
}

@main
private enum Main {
    static func main() async {
        do {
            guard let arguments = try Arguments.parse() else { return }
            var fixtures: [String: Any] = [:]
            for name in arguments.fixtureNames {
                let library = arguments.fixtureRoot.appendingPathComponent(name, isDirectory: true)
                fixtures[name] = try await runFixture(library)
                print("benchmarked \(name)")
            }
            let report: [String: Any] = [
                "generatedAt": ISO8601DateFormatter().string(from: Date()),
                "fixtureRoot": arguments.fixtureRoot.path,
                "golden": "old in-memory filter IDs and order",
                "fixtures": fixtures
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(
                at: arguments.outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: arguments.outputURL, options: .atomic)
            print("report: \(arguments.outputURL.path)")
        } catch {
            fputs("PromptStudioLibraryQueryBenchmark failed: \(error.localizedDescription) [\(String(describing: error))]\n", stderr)
            exit(1)
        }
    }
}
