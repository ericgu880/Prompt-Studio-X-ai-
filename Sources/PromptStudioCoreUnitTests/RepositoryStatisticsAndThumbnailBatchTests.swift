import Foundation
import PromptStudioCore

private final class ThumbnailBatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var batches: [[String: String]] = []

    func append(_ batch: [String: String]) {
        lock.lock()
        batches.append(batch)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return batches.count
    }

    var totalUpdateCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return batches.reduce(0) { $0 + $1.count }
    }
}

func testLibraryStatisticsUseDirectAggregates() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())

    var activeFavorite = sampleItem(title: "Active favorite", prompt: "active favorite")
    activeFavorite.id = "statistics-active-favorite"
    activeFavorite.versions = []
    activeFavorite.folderId = "statistics-folder-a"
    activeFavorite.favorite = true
    activeFavorite.lastUsedAt = Date(timeIntervalSince1970: 1_700_000_000)

    var activePlain = sampleItem(title: "Active plain", prompt: "active plain")
    activePlain.id = "statistics-active-plain"
    activePlain.versions = []
    activePlain.folderId = "statistics-folder-a"
    activePlain.favorite = false
    activePlain.lastUsedAt = Date(timeIntervalSince1970: 0)

    var trashFavorite = sampleItem(title: "Trash favorite", prompt: "trash favorite")
    trashFavorite.id = "statistics-trash"
    trashFavorite.versions = []
    trashFavorite.folderId = "statistics-folder-b"
    trashFavorite.favorite = true
    trashFavorite.lastUsedAt = Date(timeIntervalSince1970: 1_700_000_000)
    trashFavorite.deletedAt = Date(timeIntervalSince1970: 1_700_000_100)

    try repository.saveItems([activeFavorite, activePlain, trashFavorite])
    let statistics = try repository.loadLibraryStatistics()

    try expect(statistics.activeCount == 2, "statistics should count only live prompt items as active")
    try expect(statistics.favoriteCount == 1, "statistics should exclude deleted favorites")
    try expect(statistics.recentCount == 1, "statistics should count only live items with a recent-use timestamp")
    try expect(statistics.trashCount == 1, "statistics should count deleted prompt items as trash")
    try expect(statistics.folderCounts == ["statistics-folder-a": 2], "folder counts should group live items directly by folder ID")
    try expect(statistics.active == statistics.activeCount && statistics["statistics-folder-a"] == 2, "statistics aliases should expose the same aggregate values")
    try expect(try repository.loadStatistics() == statistics, "loadStatistics should preserve the aggregate result")
}

func testPromptRepositoryThumbnailPathBatchIsAtomicAndSkipsTags() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    var first = sampleItem(title: "Thumbnail first", prompt: "first")
    first.id = "thumbnail-batch-first"
    first.versions = []
    first.tags = ["thumbnail-batch-tag"]
    var second = sampleItem(title: "Thumbnail second", prompt: "second")
    second.id = "thumbnail-batch-second"
    second.versions = []
    second.tags = ["thumbnail-batch-tag"]
    try repository.saveItems([first, second])

    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    try database.execute(
        """
        CREATE TRIGGER abort_thumbnail_batch
        BEFORE UPDATE OF thumbnailPath ON prompt_items
        WHEN NEW.id = 'thumbnail-batch-second'
        BEGIN
            SELECT RAISE(ABORT, 'forced thumbnail batch rollback');
        END;
        """
    )
    try database.execute(
        """
        CREATE TRIGGER reject_thumbnail_tag_write
        BEFORE INSERT ON tags
        BEGIN
            SELECT RAISE(ABORT, 'thumbnail update must not refresh tags');
        END;
        """
    )

    var caughtError: Error?
    do {
        try repository.updateThumbnailPaths([
            first.id: "/tmp/generated-first.jpg",
            second.id: "/tmp/generated-second.jpg"
        ])
    } catch {
        caughtError = error
    }
    try expect(caughtError?.localizedDescription.contains("forced thumbnail batch rollback") == true, "thumbnail batch should expose trigger failures")

    let rolledBack = Dictionary(uniqueKeysWithValues: try repository.loadItems().map { ($0.id, $0) })
    try expect(rolledBack[first.id]?.thumbnailPath == first.thumbnailPath, "thumbnail batch rollback should restore the first path")
    try expect(rolledBack[second.id]?.thumbnailPath == second.thumbnailPath, "thumbnail batch rollback should retain the second path")

    try database.execute("DROP TRIGGER abort_thumbnail_batch;")
    try repository.updateThumbnailPaths([first.id: "/tmp/generated-first.jpg", second.id: "/tmp/generated-second.jpg"])
    let updated = Dictionary(uniqueKeysWithValues: try repository.loadItems().map { ($0.id, $0) })
    try expect(updated[first.id]?.thumbnailPath == "/tmp/generated-first.jpg", "thumbnail batch should persist the first path")
    try expect(updated[second.id]?.thumbnailPath == "/tmp/generated-second.jpg", "thumbnail batch should persist the second path")
    try expect(try repository.loadTags().first(where: { $0.name == "thumbnail-batch-tag" })?.count == 2, "thumbnail path updates must not refresh tags")

    try repository.updateThumbnailPaths([:])
}

func testThumbnailPathBatcherFlushesAtFiftyAndSupportsFlushCancel() async throws {
    let recorder = ThumbnailBatchRecorder()
    let batcher = ThumbnailPathBatcher(
        maxBatchSize: 50,
        flushIntervalNanoseconds: 1_000_000_000,
        flushHandler: { batch in recorder.append(batch) }
    )

    for index in 0..<500 {
        _ = try await batcher.enqueue(itemID: "batch-\(index)", thumbnailPath: "/tmp/\(index).jpg")
    }
    try expect(recorder.count == 10, "500 thumbnail paths should flush in at most ten fifty-item batches")
    try expect(recorder.totalUpdateCount == 500, "every thumbnail path should be delivered exactly once")
    let fullBatchPendingCount = await batcher.pendingCount
    try expect(fullBatchPendingCount == 0, "a full final batch should leave no pending paths")

    let exactRecorder = ThumbnailBatchRecorder()
    let exact = ThumbnailPathBatcher(
        maxBatchSize: 50,
        flushIntervalNanoseconds: 1_000_000_000,
        flushHandler: { batch in exactRecorder.append(batch) }
    )
    for index in 0..<50 {
        _ = try await exact.enqueue(itemID: "exact-\(index)", thumbnailPath: "/tmp/exact-\(index).jpg")
    }
    try expect(exactRecorder.count == 1 && exactRecorder.totalUpdateCount == 50, "exactly fifty thumbnail paths should use one batch")

    let explicitRecorder = ThumbnailBatchRecorder()
    let explicit = ThumbnailPathBatcher(
        maxBatchSize: 50,
        flushIntervalNanoseconds: 1_000_000_000,
        flushHandler: { batch in explicitRecorder.append(batch) }
    )
    _ = try await explicit.enqueue(itemID: "explicit", thumbnailPath: "/tmp/explicit.jpg")
    let explicitPendingCount = await explicit.pendingCount
    try expect(explicitPendingCount == 1, "a sub-capacity batch should remain pending until flush")
    _ = try await explicit.flush()
    try expect(explicitRecorder.count == 1 && explicitRecorder.totalUpdateCount == 1, "explicit flush should write the pending batch once")

    let timedRecorder = ThumbnailBatchRecorder()
    let timed = ThumbnailPathBatcher(
        maxBatchSize: 50,
        flushIntervalNanoseconds: 10_000_000,
        flushHandler: { batch in timedRecorder.append(batch) }
    )
    _ = try await timed.enqueue(itemID: "timed", thumbnailPath: "/tmp/timed.jpg")
    try await Task.sleep(nanoseconds: 30_000_000)
    try expect(timedRecorder.count == 1, "the flush timer should write a partial batch when its deadline arrives")

    let cancelledRecorder = ThumbnailBatchRecorder()
    let cancelled = ThumbnailPathBatcher(
        maxBatchSize: 50,
        flushIntervalNanoseconds: 1_000_000,
        flushHandler: { batch in cancelledRecorder.append(batch) }
    )
    _ = try await cancelled.enqueue(itemID: "cancelled", thumbnailPath: "/tmp/cancelled.jpg")
    await cancelled.cancel()
    try await Task.sleep(nanoseconds: 20_000_000)
    try expect(cancelledRecorder.count == 0, "cancel should drop pending thumbnail paths before the timer fires")
    let cancelledPendingCount = await cancelled.pendingCount
    let isCancelled = await cancelled.isCancelled
    try expect(cancelledPendingCount == 0 && isCancelled, "cancel should clear pending state and reject future writes")
}
