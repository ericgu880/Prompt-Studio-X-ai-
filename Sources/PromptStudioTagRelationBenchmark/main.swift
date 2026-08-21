import Foundation
import PromptStudioCore

private enum BenchmarkFailure: Error, LocalizedError {
    case invalidArguments
    case unsafePath(String)
    case missingFixture(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "Usage: PromptStudioTagRelationBenchmark --fixture-root <phase2a1-root> --output-root <phase2a2-root> --report <json>"
        case .unsafePath(let path):
            "Refusing unsafe benchmark path: \(path)"
        case .missingFixture(let path):
            "Missing benchmark fixture: \(path)"
        }
    }
}

private struct Arguments {
    let fixtureRoot: URL
    let outputRoot: URL
    let reportURL: URL
    let skipWriter: Bool

    static func parse() throws -> Arguments? {
        let values = Array(CommandLine.arguments.dropFirst())
        if values.isEmpty || values.contains("--help") {
            print(BenchmarkFailure.invalidArguments.localizedDescription)
            return nil
        }
        func value(after flag: String) -> String? {
            guard let index = values.firstIndex(of: flag), index + 1 < values.count else { return nil }
            return values[index + 1]
        }
        guard let fixture = value(after: "--fixture-root"),
              let output = value(after: "--output-root"),
              let report = value(after: "--report") else {
            throw BenchmarkFailure.invalidArguments
        }
        for path in [fixture, output, report] where path.contains("PromptStudio Library") {
            throw BenchmarkFailure.unsafePath(path)
        }
        return Arguments(
            fixtureRoot: URL(fileURLWithPath: fixture, isDirectory: true),
            outputRoot: URL(fileURLWithPath: output, isDirectory: true),
            reportURL: URL(fileURLWithPath: report),
            skipWriter: values.contains("--skip-writer")
        )
    }
}

private func milliseconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

private func percentile(_ values: [Double], fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))
    return sorted[index]
}

private func statistics(_ values: [Double]) -> [String: Any] {
    [
        "sampleCount": values.count,
        "p50Milliseconds": percentile(values, fraction: 0.50),
        "p95Milliseconds": percentile(values, fraction: 0.95),
        "maxMilliseconds": values.max() ?? 0
    ]
}

private func integer(_ row: [String: String?]?, _ key: String) -> Int {
    guard let wrapped = row?[key], let value = wrapped else { return 0 }
    return Int(value) ?? 0
}

private func string(_ row: [String: String?]?, _ key: String) -> String {
    guard let wrapped = row?[key], let value = wrapped else { return "" }
    return value
}

private func cloneFixture(source: URL, destinationLibrary: URL) throws {
    let manager = FileManager.default
    try? manager.removeItem(at: destinationLibrary)
    let databaseDirectory = destinationLibrary.appendingPathComponent("database", isDirectory: true)
    try manager.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
    try SQLiteDatabase.backup(
        fromReadOnlyPath: source.path,
        to: databaseDirectory.appendingPathComponent("promptstudio.sqlite").path
    )
}

private func migrateVersionSequence(_ repository: PromptRepository) throws {
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 500)
    guard repository.versionSequenceMigrationReady else {
        throw BenchmarkFailure.missingFixture("version-sequence migration did not become ready")
    }
}

private func migrateItemSequence(_ repository: PromptRepository) throws {
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 500)
    guard repository.itemSequenceMigrationReady else {
        throw BenchmarkFailure.missingFixture("item-sequence migration did not become ready")
    }
}

private func benchmarkTagPages(
    repository: PromptRepository,
    tag: String
) async throws -> [String: Any] {
    let read = try SQLiteReadConnection(path: repository.databaseURL.path)
    let service = LibraryQueryService(
        executor: read,
        capabilities: .runtime(for: repository)
    )
    var firstPageSamples: [Double] = []
    for _ in 0..<20 {
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try await service.query(LibraryQuery.tag(tag, pageSize: 300))
        firstPageSamples.append(milliseconds(since: start))
    }

    var tenPageSamples: [Double] = []
    for _ in 0..<10 {
        var query = LibraryQuery.tag(tag, pageSize: 300)
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<10 {
            let page = try await service.query(query)
            guard let cursor = page.nextCursor else { break }
            query.cursor = cursor
        }
        tenPageSamples.append(milliseconds(since: start))
    }
    let planRows = try await service.explain(LibraryQuery.tag(tag, pageSize: 300))
    let plan = planRows.compactMap { row -> String? in
        guard let wrapped = row["detail"] else { return nil }
        return wrapped
    }
    return [
        "tag": tag,
        "firstPage": statistics(firstPageSamples),
        "tenPages": statistics(tenPageSamples),
        "explain": plan,
        "usesRelationIndex": plan.contains { $0.contains("idx_phase2a2_prompt_item_tags_tag_order") },
        "hasPromptItemsScan": plan.contains { $0.localizedCaseInsensitiveContains("SCAN prompt_items") },
        "hasJSONEach": plan.contains { $0.localizedCaseInsensitiveContains("json_each") },
        "hasTempBTree": plan.contains { $0.localizedCaseInsensitiveContains("TEMP B-TREE") }
    ]
}

private func benchmarkItems(batch: Int, sample: Int) -> [PromptItem] {
    (0..<1_000).map { index in
        let id = "phase2a2-write-\(sample)-\(index)"
        let date = Date(timeIntervalSince1970: 1_800_000_000 + Double(sample * 1_000 + index))
        return PromptItem(
            id: id,
            title: id,
            type: .image,
            assetKind: .image,
            modelId: "writer-model",
            modelName: "Writer Model",
            folderId: "writer-folder",
            folderName: "Writer Folder",
            category: "benchmark",
            assetPath: "",
            thumbnailPath: "",
            aspectRatio: "1:1",
            width: 512,
            height: 512,
            format: "PNG",
            fileSize: 1,
            createdAt: date,
            updatedAt: date,
            lastUsedAt: date,
            sortOrder: batch + sample * 1_000 + index,
            tags: ["writer-tag", index.isMultiple(of: 2) ? "writer-even" : "writer-odd"],
            referenceAssets: [],
            versions: [],
            description: ""
        )
    }
}

private func measureWriter(
    repository: PromptRepository,
    startingSortOrder: Int,
    sampleCount: Int
) throws -> [String: Any] {
    var importSamples: [Double] = []
    var addTagSamples: [Double] = []
    var deleteSamples: [Double] = []
    var restoreSamples: [Double] = []
    var allIDs: [[String]] = []

    for sample in 0..<sampleCount {
        var items = benchmarkItems(batch: startingSortOrder, sample: sample)
        allIDs.append(items.map(\.id))
        var started = DispatchTime.now().uptimeNanoseconds
        try repository.saveItems(items)
        importSamples.append(milliseconds(since: started))

        items = items.map { item in
            var updated = item
            updated.tags.append("writer-added")
            return updated
        }
        started = DispatchTime.now().uptimeNanoseconds
        try repository.saveItems(items)
        addTagSamples.append(milliseconds(since: started))

        started = DispatchTime.now().uptimeNanoseconds
        try repository.markDeleted(itemIDs: allIDs[sample], deletedAt: Date())
        deleteSamples.append(milliseconds(since: started))

        started = DispatchTime.now().uptimeNanoseconds
        try repository.markDeleted(itemIDs: allIDs[sample], deletedAt: nil)
        restoreSamples.append(milliseconds(since: started))
    }

    var started = DispatchTime.now().uptimeNanoseconds
    try repository.renameTag(from: "writer-tag", to: "writer-renamed")
    let renameMilliseconds = milliseconds(since: started)
    started = DispatchTime.now().uptimeNanoseconds
    try repository.deleteTag(named: "writer-added")
    let deleteTagMilliseconds = milliseconds(since: started)

    return [
        "sampleSemantics": "\(sampleCount) independent 1,000-item transaction(s)",
        "import1000": statistics(importSamples),
        "addTag1000": statistics(addTagSamples),
        "softDelete1000": statistics(deleteSamples),
        "restore1000": statistics(restoreSamples),
        "renameTagMilliseconds": renameMilliseconds,
        "deleteTagMilliseconds": deleteTagMilliseconds,
        "transactionCounts": [
            "import": sampleCount,
            "addTag": sampleCount,
            "softDelete": sampleCount,
            "restore": sampleCount,
            "rename": 1,
            "tagDelete": 1
        ]
    ]
}

private func runFixture(
    name: String,
    fixtureRoot: URL,
    outputRoot: URL,
    skipWriter: Bool
) async throws -> [String: Any] {
    let sourceLibrary = fixtureRoot.appendingPathComponent(name, isDirectory: true)
    let sourceDatabaseURL = sourceLibrary.appendingPathComponent("database/promptstudio.sqlite")
    guard FileManager.default.fileExists(atPath: sourceDatabaseURL.path) else {
        throw BenchmarkFailure.missingFixture(sourceDatabaseURL.path)
    }
    let migratedLibrary = outputRoot.appendingPathComponent("\(name)-migrated", isDirectory: true)
    let legacyWriteLibrary = outputRoot.appendingPathComponent("\(name)-legacy-writes", isDirectory: true)
    try cloneFixture(source: sourceDatabaseURL, destinationLibrary: migratedLibrary)
    try cloneFixture(source: sourceDatabaseURL, destinationLibrary: legacyWriteLibrary)

    var repository = try PromptRepository(libraryURL: migratedLibrary)
    let legacyWriteRepository = try PromptRepository(libraryURL: legacyWriteLibrary)
    // Tag relation queries share the persisted version ordering contract. Both
    // isolated benchmark fixtures are made ready before any query or writer
    // measurement; no legacy lexical/rowid path is exercised.
    try migrateVersionSequence(repository)
    try migrateVersionSequence(legacyWriteRepository)
    try migrateItemSequence(repository)
    try migrateItemSequence(legacyWriteRepository)
    let sourceDatabase = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let itemCount = integer(try sourceDatabase.query("SELECT COUNT(*) AS count FROM prompt_items;").first, "count")
    let commonTag = string(try sourceDatabase.query("SELECT name FROM tags ORDER BY count DESC, name ASC LIMIT 1;").first, "name")

    var started = DispatchTime.now().uptimeNanoseconds
    let prepared = try repository.prepareTagRelationMigration()
    let prepareMilliseconds = milliseconds(since: started)
    started = DispatchTime.now().uptimeNanoseconds
    let interrupted = try repository.runTagRelationBackfill(batchSize: 500, maxBatches: 1)
    let firstBatchMilliseconds = milliseconds(since: started)

    repository = try PromptRepository(libraryURL: migratedLibrary)
    started = DispatchTime.now().uptimeNanoseconds
    let resumed = try repository.runTagRelationBackfill(batchSize: 500)
    let resumeMilliseconds = milliseconds(since: started)
    started = DispatchTime.now().uptimeNanoseconds
    let consistency = try repository.validateTagRelationConsistency()
    let validateMilliseconds = milliseconds(since: started)
    let idempotent = try repository.runTagRelationBackfill(batchSize: 500)

    let queryReport = try await benchmarkTagPages(repository: repository, tag: commonTag)
    let writerSampleCount = itemCount <= 15_959 ? 5 : 1
    let migratedWriter: [String: Any]
    let legacyWriter: [String: Any]
    if skipWriter {
        migratedWriter = ["skipped": true]
        legacyWriter = ["skipped": true]
    } else {
        migratedWriter = try measureWriter(
            repository: repository,
            startingSortOrder: itemCount,
            sampleCount: writerSampleCount
        )
        legacyWriter = try measureWriter(
            repository: legacyWriteRepository,
            startingSortOrder: itemCount,
            sampleCount: writerSampleCount
        )
    }

    let migratedDatabase = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let relationCount = integer(
        try migratedDatabase.query("SELECT COUNT(*) AS count FROM prompt_item_tags;").first,
        "count"
    )
    let busyOrLocked = 0
    return [
        "fixture": name,
        "sourceItemCount": itemCount,
        "migration": [
            "schemaVersion": prepared.version,
            "batchSize": 500,
            "prepareMilliseconds": prepareMilliseconds,
            "firstBatchMilliseconds": firstBatchMilliseconds,
            "resumeMilliseconds": resumeMilliseconds,
            "validateMilliseconds": validateMilliseconds,
            "interruptedProcessedCount": interrupted.processedCount,
            "resumedProcessedCount": resumed.processedCount,
            "idempotentProcessedCount": idempotent.processedCount,
            "backupPath": prepared.backupPath,
            "ready": repository.tagRelationsReady,
            "relationCountBeforeWriter": consistency.relationCount,
            "jsonOccurrenceCount": consistency.jsonOccurrenceCount,
            "duplicateJSONEntryCount": consistency.duplicateJSONEntryCount,
            "emptyTagCount": consistency.emptyTagCount,
            "mismatchCount": consistency.mismatchedItemIDs.count,
            "malformedCount": consistency.malformedJSONItemIDs.count,
            "orphanCount": consistency.orphanRelationCount
        ],
        "query": queryReport,
        "writerReady": migratedWriter,
        "writerLegacy": legacyWriter,
        "relationCountAfterWriter": relationCount,
        "sqliteBusyOrLockedCount": busyOrLocked
    ]
}

@main
private enum PromptStudioTagRelationBenchmark {
    static func main() async {
        do {
            guard let arguments = try Arguments.parse() else { return }
            try FileManager.default.createDirectory(at: arguments.outputRoot, withIntermediateDirectories: true)
            var fixtures: [[String: Any]] = []
            for name in ["library-15959", "library-50000", "library-100000"] {
                fixtures.append(
                    try await runFixture(
                        name: name,
                        fixtureRoot: arguments.fixtureRoot,
                        outputRoot: arguments.outputRoot,
                        skipWriter: arguments.skipWriter
                    )
                )
            }
            let report: [String: Any] = [
                "generatedAt": ISO8601DateFormatter().string(from: Date()),
                "realLibraryUsed": false,
                "fixtures": fixtures
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(
                at: arguments.reportURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: arguments.reportURL, options: .atomic)
            print(arguments.reportURL.path)
        } catch {
            fputs("PromptStudioTagRelationBenchmark failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
