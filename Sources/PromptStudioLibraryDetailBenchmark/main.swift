import CryptoKit
import Foundation
import PromptStudioCore
@preconcurrency import Darwin

private let performanceRoot = URL(fileURLWithPath: "/Users/guruocen/Documents/PromptStudio Performance Fixtures", isDirectory: true)

private struct Arguments {
    let fixtureRoot: URL
    let outputURL: URL
    let fixturePaths: [String]
    let samples: Int
    let cacheHits: Int
    let rapidRounds: Int
    let rapidSelections: Int
    let includeScales: Bool
    let includeGiant: Bool

    static func parse() throws -> Arguments? {
        let values = Array(CommandLine.arguments.dropFirst())
        if values.contains("--help") || values.isEmpty {
            print("Usage: PromptStudioLibraryDetailBenchmark --fixture-root <phase2a3-root> --output <json> [--fixtures relative,path] [--samples 100] [--include-giant]")
            return nil
        }
        func value(_ flag: String) -> String? {
            guard let index = values.firstIndex(of: flag), index + 1 < values.count else { return nil }
            return values[index + 1]
        }
        guard let root = value("--fixture-root"), let output = value("--output") else {
            throw BenchmarkError.invalidArguments
        }
        let samples = max(100, Int(value("--samples") ?? "100") ?? 100)
        let cacheHits = max(1_000, Int(value("--cache-hits") ?? "1000") ?? 1_000)
        let rapidRounds = max(20, Int(value("--rapid-rounds") ?? "20") ?? 20)
        let rapidSelections = max(50, Int(value("--rapid-selections") ?? "50") ?? 50)
        let fixturePaths = value("--fixtures")?.split(separator: ",").map(String.init) ?? []
        return Arguments(
            fixtureRoot: URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL,
            outputURL: URL(fileURLWithPath: output),
            fixturePaths: fixturePaths,
            samples: samples,
            cacheHits: cacheHits,
            rapidRounds: rapidRounds,
            rapidSelections: rapidSelections,
            includeScales: !values.contains("--no-scales"),
            includeGiant: values.contains("--include-giant")
        )
    }
}

private enum BenchmarkError: Error, LocalizedError {
    case invalidArguments
    case unsafeFixtureRoot(String)
    case malformedFixture(String)
    case goldenMismatch(String)
    case missingSelection(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "invalid benchmark arguments"
        case .unsafeFixtureRoot(let path):
            "fixture root is outside the isolated Performance Fixtures root: " + path
        case .malformedFixture(let path):
            "malformed phase2a3 fixture: " + path
        case .goldenMismatch(let field):
            "independent golden mismatch: " + field
        case .missingSelection(let id):
            "fixture selection is missing: " + id
        }
    }
}

private struct SampleStats {
    let count: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let maxMilliseconds: Double

    init(_ values: [Double]) {
        let sorted = values.sorted()
        count = sorted.count
        guard !sorted.isEmpty else {
            p50Milliseconds = 0
            p95Milliseconds = 0
            maxMilliseconds = 0
            return
        }
        func percentile(_ fraction: Double) -> Double {
            let index = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))
            return sorted[index]
        }
        p50Milliseconds = percentile(0.50)
        p95Milliseconds = percentile(0.95)
        maxMilliseconds = sorted[sorted.count - 1]
    }

    var json: [String: Any] {
        [
            "count": count,
            "p50Milliseconds": p50Milliseconds,
            "p95Milliseconds": p95Milliseconds,
            "maxMilliseconds": maxMilliseconds,
        ]
    }
}

private func monotonicMilliseconds() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
}

private func isSafeFixtureRoot(_ root: URL) -> Bool {
    let path = root.standardizedFileURL.path
    let expectedParent = performanceRoot.standardizedFileURL.path
    return !path.contains("PromptStudio Library")
        && URL(fileURLWithPath: path).deletingLastPathComponent().path == expectedParent
        && URL(fileURLWithPath: path).lastPathComponent.hasPrefix("phase2a3-")
}

private func readJSONObject(_ url: URL) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
        throw BenchmarkError.malformedFixture(url.path)
    }
    return object
}

private func canonicalJSON(_ value: Any) throws -> Data {
    if JSONSerialization.isValidJSONObject(value) {
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    // JSONSerialization rejects scalar top-level values. Wrap then strip the
    // array delimiters so scalar hashes match Python's json.dumps output.
    let wrapped = try JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys, .withoutEscapingSlashes])
    return Data(wrapped.dropFirst().dropLast())
}

private func hashLength(_ value: Any) throws -> (sha256: String, length: Int) {
    let data = try canonicalJSON(value)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return (digest, data.count)
}

private func assertGolden(_ value: Any, expected: Any, field: String) throws {
    guard let expectedDictionary = expected as? [String: Any],
          let expectedHash = expectedDictionary["sha256"] as? String,
          let expectedLength = expectedDictionary["length"] as? Int else {
        throw BenchmarkError.goldenMismatch(field)
    }
    let actual = try hashLength(value)
    guard actual.sha256 == expectedHash, actual.length == expectedLength else {
        throw BenchmarkError.goldenMismatch(field)
    }
}

private func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

private func capturedSourceJSON(_ source: CapturedSource?) -> Any {
    guard let source else { return NSNull() }
    return [
        "pageTitle": source.pageTitle,
        "pageURL": source.pageURL,
        "siteName": source.siteName,
        "capturedAt": iso8601(source.capturedAt),
        "resourceURL": source.resourceURL as Any,
        "imageDOMSourceKind": source.imageDOMSourceKind?.rawValue as Any,
        "imageAcquisitionMethod": source.imageAcquisitionMethod?.rawValue as Any,
        "isScreenshotCapture": source.isScreenshotCapture as Any,
    ]
}

private func itemFields(_ item: PromptItem) -> [String: Any] {
    let references: [[String: Any]] = item.referenceAssets.map {
        ["id": $0.id, "type": $0.type, "path": $0.path, "label": $0.label]
    }
    return [
        "id": item.id,
        "title": item.title,
        "type": item.type.rawValue,
        "assetKind": item.assetKind.rawValue,
        "modelId": item.modelId,
        "modelName": item.modelName,
        "folderId": item.folderId,
        "folderName": item.folderName,
        "category": item.category,
        "assetPath": item.assetPath,
        "thumbnailPath": item.thumbnailPath,
        "aspectRatio": item.aspectRatio,
        "width": item.width,
        "height": item.height,
        "format": item.format,
        "fileSize": item.fileSize,
        "favorite": item.favorite ? 1 : 0,
        "pinnedAt": item.pinnedAt.map(iso8601) as Any,
        "deletedAt": item.deletedAt.map(iso8601) as Any,
        "createdAt": iso8601(item.createdAt),
        "updatedAt": iso8601(item.updatedAt),
        "lastUsedAt": iso8601(item.lastUsedAt),
        "sortOrder": item.sortOrder,
        "tagsJSON": item.tags,
        "referencesJSON": references,
        "description": item.description,
        "captureId": item.captureID as Any,
        "captureSourceJSON": capturedSourceJSON(item.capturedSource),
    ]
}

private func validateGolden(item: PromptItem, expected: [String: Any]) throws {
    guard let fields = expected["fields"] as? [String: Any] else {
        throw BenchmarkError.goldenMismatch("fields")
    }
    for (name, expectedValue) in fields {
        guard let actualValue = itemFields(item)[name] else {
            throw BenchmarkError.goldenMismatch(name)
        }
        try assertGolden(actualValue, expected: expectedValue, field: item.id + "." + name)
    }

    let orderedVersions = item.versions
    let versionOrder: [[String]] = orderedVersions.map {
        [$0.id, $0.version, iso8601($0.createdAt)]
    }
    let versionFields: [String: Any] = [
        "id": orderedVersions.map(\.id),
        "promptItemId": orderedVersions.map(\.promptItemId),
        "version": orderedVersions.map(\.version),
        "prompt": orderedVersions.map(\.prompt),
        "negativePrompt": orderedVersions.map(\.negativePrompt),
        "parametersJSON": orderedVersions.map { $0.parameters },
        "note": orderedVersions.map(\.note),
        "createdAt": orderedVersions.map { iso8601($0.createdAt) },
    ]
    guard let versions = expected["versions"] as? [String: Any],
          let expectedCount = versions["count"] as? Int,
          expectedCount == orderedVersions.count,
          let expectedOrder = versions["order"],
          let expectedFields = versions["fields"] as? [String: Any] else {
        throw BenchmarkError.goldenMismatch(item.id + ".versions")
    }
    try assertGolden(versionOrder, expected: expectedOrder, field: item.id + ".versions.order")
    for (name, value) in versionFields {
        guard let expectedValue = expectedFields[name] else { throw BenchmarkError.goldenMismatch(name) }
        try assertGolden(value, expected: expectedValue, field: item.id + ".versions." + name)
    }

    let references = item.referenceAssets.map {
        ["id": $0.id, "type": $0.type, "path": $0.path, "label": $0.label]
    }
    guard let expectedReferences = expected["references"] as? [String: Any],
          let expectedReferenceCount = expectedReferences["count"] as? Int,
          expectedReferenceCount == references.count,
          let expectedReferenceOrder = expectedReferences["order"],
          let expectedReferenceFields = expectedReferences["fields"] as? [String: Any] else {
        throw BenchmarkError.goldenMismatch(item.id + ".references")
    }
    try assertGolden(references, expected: expectedReferenceOrder, field: item.id + ".references.order")
    for name in ["id", "type", "path", "label"] {
        let value = references.compactMap { $0[name] }
        guard let expectedValue = expectedReferenceFields[name] else { throw BenchmarkError.goldenMismatch(name) }
        try assertGolden(value, expected: expectedValue, field: item.id + ".references." + name)
    }
}

private func residentMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}

private func fixturePath(_ root: URL, _ relativePath: String) throws -> URL {
    let rootPath = root.standardizedFileURL.path
    let path = root.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL
    guard path.path.hasPrefix(rootPath + "/"), !path.path.contains("PromptStudio Library") else {
        throw BenchmarkError.unsafeFixtureRoot(path.path)
    }
    return path
}

private func selectionIDs(from golden: [String: Any]) throws -> [String] {
    guard let ids = golden["selectionIDs"] as? [String], ids.count == 32 else {
        throw BenchmarkError.malformedFixture("golden selectionIDs")
    }
    return ids
}

/// Counts real detail-service invocations. Cache-hit SQL is reported from the
/// observed delta around the hit loop, never from a hard-coded constant.
private final class CountingDetailService: ItemDetailLoading, @unchecked Sendable {
    private let service: ItemDetailLoading
    private let lock = NSLock()
    private var callCount = 0

    init(service: ItemDetailLoading) {
        self.service = service
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func itemDetail(id: String) async throws -> PromptItem? {
        withLock { callCount += 1 }
        return try await service.itemDetail(id: id)
    }

    var calls: Int { withLock { callCount } }
}

private struct LoaderMetrics: Sendable {
    let started: Int
    let completed: Int
    let cancelled: Int
    let maxInFlight: Int
    let inFlight: Int

    var json: [String: Any] {
        [
            "started": started,
            "completed": completed,
            "cancelled": cancelled,
            "maxInFlight": maxInFlight,
            "inFlight": inFlight,
        ]
    }
}

private final class CountingLoader: ItemDetailLoading, @unchecked Sendable {
    private let service: PromptItemDetailService
    private let lock = NSLock()
    private var startedValue = 0
    private var completedValue = 0
    private var cancelledValue = 0
    private var inFlightValue = 0
    private var maxInFlightValue = 0

    init(service: PromptItemDetailService) {
        self.service = service
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func itemDetail(id: String) async throws -> PromptItem? {
        withLock {
            startedValue += 1
            inFlightValue += 1
            maxInFlightValue = max(maxInFlightValue, inFlightValue)
        }
        defer {
            withLock { inFlightValue = max(0, inFlightValue - 1) }
        }
        do {
            try await Task.sleep(nanoseconds: 1_000_000)
            let result = try await service.itemDetail(id: id)
            withLock { completedValue += 1 }
            return result
        } catch is CancellationError {
            withLock { cancelledValue += 1 }
            throw CancellationError()
        }
    }

    var metrics: LoaderMetrics {
        withLock {
            LoaderMetrics(
                started: startedValue,
                completed: completedValue,
                cancelled: cancelledValue,
                maxInFlight: maxInFlightValue,
                inFlight: inFlightValue
            )
        }
    }
}

private struct RapidRunMetrics: Sendable {
    let run: Int
    let selectedCount: Int
    let finalOnly: Bool
    let noBacklog: Bool
    let cancellationMilliseconds: Double
    let finalLoadMilliseconds: Double
    let startedDelta: Int
    let completedDelta: Int
    let cancelledDelta: Int

    var json: [String: Any] {
        [
            "run": run,
            "selectedCount": selectedCount,
            "finalOnly": finalOnly,
            "noBacklog": noBacklog,
            "cancellationMilliseconds": cancellationMilliseconds,
            "finalLoadMilliseconds": finalLoadMilliseconds,
            "startedDelta": startedDelta,
            "completedDelta": completedDelta,
            "cancelledDelta": cancelledDelta,
        ]
    }
}

private struct RapidMetrics: Sendable {
    let rounds: Int
    let selectionsPerRound: Int
    let finalOnlyLoadedRounds: Int
    let noBacklogRounds: Int
    let noBacklog: Bool
    let loader: LoaderMetrics
    let runs: [RapidRunMetrics]

    var json: [String: Any] {
        [
            "rounds": rounds,
            "selectionsPerRound": selectionsPerRound,
            "finalOnlyLoadedRounds": finalOnlyLoadedRounds,
            "noBacklogRounds": noBacklogRounds,
            "noBacklog": noBacklog,
            "loader": loader.json,
            "runs": runs.map(\.json),
        ]
    }
}

@MainActor
private func rapidSelectionBenchmark(
    service: PromptItemDetailService,
    ids: [String],
    rounds: Int,
    selections: Int
) async throws -> RapidMetrics {
    let loader = CountingLoader(service: service)
    let controller = ItemDetailController(loader: loader, cache: ItemDetailCache(maxEntryCount: 32))
    guard !ids.isEmpty else {
        return RapidMetrics(rounds: 0, selectionsPerRound: 0, finalOnlyLoadedRounds: 0, noBacklogRounds: 0, noBacklog: true, loader: loader.metrics, runs: [])
    }
    // Fixtures contain 32 IDs; the rapid harness intentionally cycles them to
    // issue exactly 50 distinct selection events per run. The final event is
    // part of those 50 events, never an extra duplicate selection.
    let candidates = (0..<selections).map { ids[$0 % ids.count] }
    let finalID = candidates[candidates.count - 1]
    var runReports: [RapidRunMetrics] = []
    for run in 0..<rounds {
        controller.cancel()
        controller.cache.removeAll()
        let before = loader.metrics
        let runStarted = monotonicMilliseconds()
        for (index, id) in candidates.enumerated() {
            controller.select(id: id)
            if index == 0 {
            // Give the first generation a chance to enter the loader before
            // replacing it, so cancellation is measured rather than inferred.
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        let finalSelectedAt = monotonicMilliseconds()
        let deadline = Date().addingTimeInterval(3)
        while controller.state != .loaded && Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let after = loader.metrics
        runReports.append(
            RapidRunMetrics(
                run: run,
                selectedCount: candidates.count,
                finalOnly: controller.state == .loaded && controller.currentDetail?.id == finalID,
                noBacklog: after.inFlight == 0,
                cancellationMilliseconds: finalSelectedAt - runStarted,
                finalLoadMilliseconds: max(0, monotonicMilliseconds() - finalSelectedAt),
                startedDelta: after.started - before.started,
                completedDelta: after.completed - before.completed,
                cancelledDelta: after.cancelled - before.cancelled
            )
        )
    }
    controller.cancel()
    let metrics = loader.metrics
    return RapidMetrics(
        rounds: rounds,
        selectionsPerRound: candidates.count,
        finalOnlyLoadedRounds: runReports.filter(\.finalOnly).count,
        noBacklogRounds: runReports.filter(\.noBacklog).count,
        noBacklog: runReports.allSatisfy(\.noBacklog),
        loader: metrics,
        runs: runReports
    )
}

private func cacheBenchmark(item: PromptItem, ids: [String], service: CountingDetailService, hits: Int) async throws -> [String: Any] {
    let cache = ItemDetailCache(maxEntryCount: 32)
    // Populate the cache through the counted service, then measure only the
    // hit loop.  This makes the reported SQL delta an observation of the
    // loader boundary instead of a constant asserted by the harness.
    guard let loadedForCache = try await service.itemDetail(id: item.id) else {
        throw BenchmarkError.missingSelection(item.id)
    }
    _ = cache.insert(loadedForCache, revision: 1)
    var timings: [Double] = []
    let serviceCallsBeforeHits = service.calls
    for _ in 0..<hits {
        let started = monotonicMilliseconds()
        guard cache.get(id: item.id, revision: 1) != nil else { throw BenchmarkError.goldenMismatch("cache") }
        timings.append(monotonicMilliseconds() - started)
    }
    let serviceCallsAfterHits = service.calls

    let uniqueCache = ItemDetailCache(maxEntryCount: 32)
    var uniqueTotal = 0.0
    var uniqueIDs = 0
    var uniqueCost = 0
    let rssBefore = residentMemoryBytes()
    var rssPeak = rssBefore
    for id in ids.prefix(32) {
        let started = monotonicMilliseconds()
        guard let loaded = try await service.itemDetail(id: id) else { continue }
        uniqueTotal += monotonicMilliseconds() - started
        uniqueCost += uniqueCache.insert(loaded, revision: 1)
        uniqueIDs += 1
        rssPeak = max(rssPeak, residentMemoryBytes())
    }
    let rssAfter = residentMemoryBytes()

    let lru = ItemDetailCache(maxEntryCount: 2, maxCostBytes: Int.max)
    var lruFirst = item
    var lruSecond = item
    var lruThird = item
    lruFirst.id += "-lru-1"
    lruSecond.id += "-lru-2"
    lruThird.id += "-lru-3"
    _ = lru.insert(lruFirst, revision: 1)
    _ = lru.insert(lruSecond, revision: 1)
    _ = lru.insert(lruThird, revision: 1)
    let oversize = ItemDetailCache(maxEntryCount: 32, maxCostBytes: 1)
    let oversizeCost = oversize.insert(item, revision: 1)
    return [
        "hits": hits,
        "sqlCalls": serviceCallsAfterHits - serviceCallsBeforeHits,
        "serviceCallsBeforeHits": serviceCallsBeforeHits,
        "serviceCallsAfterHits": serviceCallsAfterHits,
        "timing": SampleStats(timings).json,
        "unique32": [
            "count": uniqueIDs,
            "totalMilliseconds": uniqueTotal,
            "cacheResidentCount": uniqueCache.residentCount,
            "cacheResidentCostBytes": uniqueCache.residentCost,
            "estimatedCostBytes": uniqueCost,
            "rssBeforeBytes": rssBefore,
            "rssAfterBytes": rssAfter,
            "rssDeltaBytes": Int64(rssAfter) - Int64(rssBefore),
            "rssPeakBytes": rssPeak,
        ],
        "countBound": [
            "maxEntries": lru.maxEntryCount,
            "residentCount": lru.residentCount,
            "evictions": lru.evictions,
        ],
        "oversize": [
            "maxCostBytes": oversize.maxCostBytes,
            "estimatedItemCostBytes": ItemDetailCache.retainedCost(of: item),
            "rejected": oversizeCost == 0 && oversize.residentCount == 0,
        ],
    ]
}

private func coldBenchmark(
    service: PromptItemDetailService,
    id: String,
    expected: [String: Any]?,
    samples: Int
) async throws -> [String: Any] {
    var total: [Double] = []
    var first: PromptItem?
    for sample in 0..<samples {
        let started = monotonicMilliseconds()
        guard let item = try await service.itemDetail(id: id) else { throw BenchmarkError.missingSelection(id) }
        let elapsed = monotonicMilliseconds() - started
        if sample == 0 {
            first = item
            if let expected {
                try validateGolden(item: item, expected: expected)
            }
        }
        total.append(elapsed)
    }
    return [
        "selectionIndex": 0,
        "selectionIDHash": SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined(),
        "goldenMatch": first != nil,
        "splitMethod": "combined total (ItemDetailService has no trace hook)",
        "sql": NSNull(),
        "decode": NSNull(),
        "sqlDecodeSupport": [
            "supported": false,
            "reason": "ItemDetailService does not expose SQL/decode trace hooks; only total is measured",
        ],
        "total": SampleStats(total).json,
    ]
}

private func busyLockedProbe(databaseURL: URL) -> [String: Any] {
    let probeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("PromptStudioPhase2A3BusyProbe-" + UUID().uuidString + ".sqlite")
    do {
        // SQLiteDatabase's normal initializer enables WAL. Probe a disposable
        // online-backup clone so the measured writer never changes a fixture's
        // journal mode or SHA.
        try SQLiteDatabase.backup(fromReadOnlyPath: databaseURL.path, to: probeURL.path)
    } catch {
        return [
            "busy": false,
            "locked": false,
            "probeSucceeded": false,
            "fixtureUnchanged": true,
            "errorType": String(describing: type(of: error)),
        ]
    }
    defer { try? FileManager.default.removeItem(at: probeURL) }

    func probeRead() -> [String: Any] {
        do {
            let read = try SQLiteReadConnection(path: probeURL.path, busyTimeoutMilliseconds: 0)
            _ = try read.querySync("SELECT COUNT(*) FROM prompt_items;")
            return ["busy": false, "locked": false, "readSucceeded": true]
        } catch {
            let message = error.localizedDescription.lowercased()
            return [
                "busy": message.contains("busy"),
                "locked": message.contains("locked"),
                "readSucceeded": false,
                "errorType": String(describing: type(of: error)),
            ]
        }
    }

    var ordinary: [String: Any]
    var explicit: [String: Any]
    do {
        let writer = try SQLiteDatabase(path: probeURL.path, mode: .existingReadWrite)
        try writer.execute("BEGIN IMMEDIATE TRANSACTION;")
        ordinary = probeRead()
        try? writer.execute("ROLLBACK;")
    } catch {
        ordinary = [
            "busy": false,
            "locked": false,
            "readSucceeded": false,
            "errorType": String(describing: type(of: error)),
        ]
    }
    do {
        // Keep the explicit-lock probe on the disposable backup as well.  A
        // writer opened against the fixture itself can switch its journal
        // mode or leave WAL sidecars behind, which would make a benchmark
        // run mutate its input.
        let writer = try SQLiteDatabase(path: probeURL.path, mode: .existingReadWrite)
        try writer.execute("BEGIN EXCLUSIVE TRANSACTION;")
        explicit = probeRead()
        try? writer.execute("ROLLBACK;")
    } catch {
        explicit = [
            "busy": false,
            "locked": false,
            "readSucceeded": false,
            "errorType": String(describing: type(of: error)),
        ]
    }
    return [
        "busy": explicit["busy"] as? Bool ?? false,
        "locked": explicit["locked"] as? Bool ?? false,
        "fixtureUnchanged": true,
        "ordinaryWALWriter": [
            "expectedBusy": false,
            "expectedLocked": false,
            "observed": ordinary,
            "coexistencePassed": ordinary["readSucceeded"] as? Bool == true
                && ordinary["busy"] as? Bool == false
                && ordinary["locked"] as? Bool == false,
        ],
        "explicitExclusiveProbe": [
            "expectedMayBlockOnNonWAL": true,
            "observed": explicit,
            "expectedObserved": explicit["busy"] as? Bool == true || explicit["locked"] as? Bool == true,
            "note": "WAL mode may permit a read even while EXCLUSIVE is held; success is reported, not treated as a failure",
        ],
    ]
}

private func selectionIDsFromDatabase(_ databaseURL: URL) throws -> [String] {
    let connection = try SQLiteReadConnection(url: databaseURL)
    return try connection.querySync("SELECT id FROM prompt_items ORDER BY id ASC LIMIT 32;")
        .compactMap { $0["id"] ?? nil }
}

private struct ScaleEntry: Sendable {
    let databaseURL: URL
    let itemCount: Int
    let databaseSHA256: String
    let sourceUnchanged: Bool
    let integrityCheck: String
    let foreignKeyViolationCount: Int
}

private func parseScaleEntries(root: URL, manifest: [String: Any]) throws -> [ScaleEntry] {
    guard let entries = manifest["scales"] as? [[String: Any]] else { return [] }
    return try entries.map { entry in
        guard let databasePath = entry["database"] as? String else {
            throw BenchmarkError.malformedFixture("scale database path")
        }
        let databaseURL = URL(fileURLWithPath: databasePath)
        guard databaseURL.path.hasPrefix(root.path + "/"), !databaseURL.path.contains("PromptStudio Library") else {
            throw BenchmarkError.unsafeFixtureRoot(databaseURL.path)
        }
        return ScaleEntry(
            databaseURL: databaseURL,
            itemCount: entry["itemCount"] as? Int ?? 0,
            databaseSHA256: entry["databaseSHA256"] as? String ?? "",
            sourceUnchanged: entry["sourceUnchanged"] as? Bool ?? false,
            integrityCheck: entry["integrityCheck"] as? String ?? "unknown",
            foreignKeyViolationCount: entry["foreignKeyViolationCount"] as? Int ?? -1
        )
    }
}

private func scaleDetailBenchmark(
    entries: [ScaleEntry],
    arguments: Arguments
) async throws -> [[String: Any]] {
    var reports: [[String: Any]] = []
    for entry in entries {
        let databaseURL = entry.databaseURL
        let ids = try selectionIDsFromDatabase(databaseURL)
        let detail = try await runDetailDatabase(
            databaseURL: databaseURL,
            relativePath: "scales/library-" + String(entry.itemCount),
            ids: ids,
            golden: nil,
            cardinality: ["versions": NSNull(), "references": NSNull()],
            arguments: arguments,
            sourceKind: "isolated-real-scale"
        )
        reports.append([
            "itemCount": entry.itemCount,
            "expectedItemCount": entry.itemCount,
            "databaseSHA256": entry.databaseSHA256,
            "sourceUnchanged": entry.sourceUnchanged,
            "integrityCheck": entry.integrityCheck,
            "foreignKeyViolationCount": entry.foreignKeyViolationCount,
            "detail": detail,
        ])
    }
    return reports
}

private func runDetailDatabase(
    databaseURL: URL,
    relativePath: String,
    ids: [String],
    golden: [String: Any]?,
    cardinality: [String: Any],
    arguments: Arguments,
    sourceKind: String
) async throws -> [String: Any] {
    guard let firstID = ids.first else { throw BenchmarkError.malformedFixture(databaseURL.path) }
    let expectedFirst = (golden?["items"] as? [String: Any])?[firstID] as? [String: Any]
    let service = try PromptItemDetailService(databaseURL: databaseURL)
    let cold = try await coldBenchmark(service: service, id: firstID, expected: expectedFirst, samples: arguments.samples)
    guard let firstItem = try await service.itemDetail(id: firstID) else { throw BenchmarkError.missingSelection(firstID) }
    let countedService = CountingDetailService(service: service)
    let cache = try await cacheBenchmark(item: firstItem, ids: ids, service: countedService, hits: arguments.cacheHits)
    let rapid = try await rapidSelectionBenchmark(
        service: service,
        ids: ids,
        rounds: arguments.rapidRounds,
        selections: arguments.rapidSelections
    )
    return [
        "path": relativePath,
        "sourceKind": sourceKind,
        "cardinality": cardinality,
        "selectionCount": ids.count,
        "cold": cold,
        "cache": cache,
        "rapidSelection": rapid.json,
        "busyLocked": busyLockedProbe(databaseURL: databaseURL),
        "rssBytes": residentMemoryBytes(),
    ]
}

private func runFixture(
    root: URL,
    relativePath: String,
    arguments: Arguments
) async throws -> [String: Any] {
    let libraryURL = try fixturePath(root, relativePath)
    let databaseURL = libraryURL.appendingPathComponent("database/promptstudio.sqlite")
    let goldenURL = libraryURL.appendingPathComponent("golden-results.json")
    let golden = try readJSONObject(goldenURL)
    let ids = try selectionIDs(from: golden)
    return try await runDetailDatabase(
        databaseURL: databaseURL,
        relativePath: relativePath,
        ids: ids,
        golden: golden,
        cardinality: golden["cardinality"] as? [String: Any] ?? [:],
        arguments: arguments,
        sourceKind: "synthetic-matrix"
    )
}

private func gitMetadata() -> [String: Any] {
    func command(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        } catch {
            return "unknown"
        }
    }
    let status = command(["status", "--porcelain"])
    return [
        "commit": command(["rev-parse", "HEAD"]),
        "branch": command(["branch", "--show-current"]),
        "dirty": !status.isEmpty,
    ]
}

@main
private enum Main {
    static func main() async {
        do {
            guard let arguments = try Arguments.parse() else { return }
            guard isSafeFixtureRoot(arguments.fixtureRoot) else {
                throw BenchmarkError.unsafeFixtureRoot(arguments.fixtureRoot.path)
            }
            let rootManifest = try readJSONObject(arguments.fixtureRoot.appendingPathComponent("manifest.json"))
            let fixturePaths: [String]
            if arguments.fixturePaths.isEmpty {
                let matrixEntries = (rootManifest["matrix"] as? [String: Any])?["fixtures"] as? [[String: Any]] ?? []
                fixturePaths = matrixEntries.compactMap { entry in
                    guard let absolute = entry["path"] as? String,
                          absolute.hasPrefix(arguments.fixtureRoot.path + "/"),
                          absolute.hasSuffix("/replica-00") else { return nil }
                    return String(absolute.dropFirst(arguments.fixtureRoot.path.count + 1))
                }
                if fixturePaths.isEmpty {
                    throw BenchmarkError.malformedFixture("matrix fixtures")
                }
            } else {
                fixturePaths = arguments.fixturePaths
            }
            var fixtures: [[String: Any]] = []
            for path in fixturePaths {
                fixtures.append(try await runFixture(root: arguments.fixtureRoot, relativePath: path, arguments: arguments))
                print("benchmarked " + path)
            }
            if arguments.includeGiant {
                fixtures.append(try await runFixture(root: arguments.fixtureRoot, relativePath: "giant/versions-1/refs-0/replica-00", arguments: arguments))
            }
            let scaleEntries = try parseScaleEntries(root: arguments.fixtureRoot, manifest: rootManifest)
            let scaleDetails = arguments.includeScales
                ? try await scaleDetailBenchmark(entries: scaleEntries, arguments: arguments)
                : []
            let report: [String: Any] = [
                "schema": "phase2a3-detail-benchmark",
                "generatedAt": ISO8601DateFormatter().string(from: Date()),
                "git": gitMetadata(),
                "host": [
                    "os": ProcessInfo.processInfo.operatingSystemVersionString,
                    "hostName": Host.current().localizedName ?? "unknown",
                    "processorCount": ProcessInfo.processInfo.processorCount,
                    "swift": "6.3.2-or-compatible",
                ],
                "config": [
                    "coldSamples": arguments.samples,
                    "cacheHits": arguments.cacheHits,
                    "rapidSelectionRounds": arguments.rapidRounds,
                    "rapidSelectionsPerRound": arguments.rapidSelections,
                    "sqlDecodeSplit": NSNull(),
                    "sqlDecodeSplitSupported": false,
                    "sqlDecodeSplitReason": "ItemDetailService does not expose SQL/decode trace hooks; SQL and decode are reported as null",
                ],
                "fixtureRoot": arguments.fixtureRoot.path,
                "fixtureManifest": rootManifest,
                "matrixCoverage": rootManifest["matrix"] as Any,
                "sourceIntegrity": rootManifest["scales"] as Any,
                "summaryScales": scaleDetails,
                "realScaleDetails": scaleDetails,
                "fixtures": fixtures,
                "integrity": [
                    "fixtureManifestPresent": true,
                    "syntheticMatrixPathsAreFixtureURLs": true,
                    "scalePathsAreOpaque": true,
                    "mediaPathsResolvedOrOpened": false,
                    "scalePathInterpretation": "database path strings only; scale media paths are not resolved or opened",
                    "foreignKeyCheck": "reported per fixture",
                    "sourceUnchanged": (rootManifest["scales"] as? [[String: Any]] ?? []).allSatisfy { $0["sourceUnchanged"] as? Bool == true },
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: arguments.outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: arguments.outputURL, options: .atomic)
            print("report: " + arguments.outputURL.path)
        } catch {
            fputs(
                "PromptStudioLibraryDetailBenchmark failed: " + error.localizedDescription
                    + " [" + String(describing: error) + "]\n",
                stderr
            )
            exit(1)
        }
    }
}
