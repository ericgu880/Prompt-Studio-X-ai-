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

private enum ThumbnailBatchTimeoutError: Error, LocalizedError {
    case timedOut

    var errorDescription: String? {
        switch self {
        case .timedOut: "thumbnail batch operation timed out"
        }
    }
}

private final class ThumbnailTimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private var resolved = false

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            self.result = result
        }
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private func requireThumbnailOperationToFinishWithin(
    _ duration: Duration = .milliseconds(250),
    operation: @escaping @Sendable () async throws -> Void
) async throws {
    let state = ThumbnailTimeoutState()
    let operationTask = Task {
        do {
            try await operation()
            state.resolve(.success(()))
        } catch {
            state.resolve(.failure(error))
        }
    }
    let timeoutTask = Task {
        do {
            try await Task.sleep(for: duration)
        } catch {
            return
        }
        state.resolve(.failure(ThumbnailBatchTimeoutError.timedOut))
        operationTask.cancel()
    }
    defer {
        operationTask.cancel()
        timeoutTask.cancel()
    }

    try await withTaskCancellationHandler(operation: {
        try await withCheckedThrowingContinuation { continuation in
            state.install(continuation)
        }
    }, onCancel: {
        operationTask.cancel()
        timeoutTask.cancel()
    })
}

private actor ThumbnailBatcherReference {
    private var value: ThumbnailPathBatcher?

    func set(_ value: ThumbnailPathBatcher) {
        self.value = value
    }

    func get() -> ThumbnailPathBatcher? {
        value
    }
}

private actor ThumbnailReentrantOutcome {
    private var batches: [[String: String]] = []
    private var handlerEnqueueReturned = false
    private var handlerCancelReturned = false

    func record(_ batch: [String: String]) {
        batches.append(batch)
    }

    func markHandlerEnqueueReturned() {
        handlerEnqueueReturned = true
    }

    func markHandlerCancelReturned() {
        handlerCancelReturned = true
    }

    func snapshot() -> [[String: String]] {
        batches
    }

    func didHandlerEnqueueReturn() -> Bool {
        handlerEnqueueReturned
    }

    func didHandlerCancelReturn() -> Bool {
        handlerCancelReturned
    }
}

private actor ThumbnailLateChildGate {
    private var handlerReturned = false
    private var childReleased = false
    private var childCompleted = false
    private var handlerWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var childWaiters: [CheckedContinuation<Void, Never>] = []

    func markHandlerReturned() {
        handlerReturned = true
        let waiters = handlerWaiters
        handlerWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitForHandlerReturn() async {
        guard !handlerReturned else { return }
        await withCheckedContinuation { continuation in
            if handlerReturned {
                continuation.resume()
            } else {
                handlerWaiters.append(continuation)
            }
        }
    }

    func releaseChild() {
        childReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitForChildRelease() async {
        guard !childReleased else { return }
        await withCheckedContinuation { continuation in
            if childReleased {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
        }
    }

    func markChildCompleted() {
        childCompleted = true
        let waiters = childWaiters
        childWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitForChildCompletion() async {
        guard !childCompleted else { return }
        await withCheckedContinuation { continuation in
            if childCompleted {
                continuation.resume()
            } else {
                childWaiters.append(continuation)
            }
        }
    }
}

private actor ThumbnailFlushGate {
    private var didStart = false
    private var released = false
    private var finished = false
    private var cancelCompleted = false
    private var childStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var childStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForStart() async {
        guard !didStart else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            if released { continuation.resume() } else { releaseWaiters.append(continuation) }
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func markStarted() {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func finish() { finished = true }
    func markChildStarted() {
        childStarted = true
        let waiters = childStartWaiters
        childStartWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    func waitForChildStart() async {
        guard !childStarted else { return }
        await withCheckedContinuation { continuation in
            if childStarted { continuation.resume() } else { childStartWaiters.append(continuation) }
        }
    }
    func markCancelCompleted() {
        cancelCompleted = true
        let waiters = cancelWaiters
        cancelWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    func waitForCancelCompleted() async {
        guard !cancelCompleted else { return }
        await withCheckedContinuation { continuation in
            if cancelCompleted { continuation.resume() } else { cancelWaiters.append(continuation) }
        }
    }
    func isFinished() -> Bool { finished }
    func isCancelCompleted() -> Bool { cancelCompleted }
}

private actor ThumbnailReentrantFlushGate {
    private var batches: [[String: String]] = []
    private var latestByID: [String: String] = [:]
    private var firstStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstReleased = false

    func receive(_ batch: [String: String]) async {
        batches.append(batch)
        latestByID.merge(batch) { _, newest in newest }
        let startWaiters = firstStartWaiters
        firstStartWaiters.removeAll()
        for waiter in startWaiters { waiter.resume() }
        guard batches.count == 1, !firstReleased else { return }
        await withCheckedContinuation { continuation in
            if firstReleased {
                continuation.resume()
            } else {
                firstReleaseWaiters.append(continuation)
            }
        }
    }

    func waitForFirstStart() async {
        guard batches.isEmpty else { return }
        await withCheckedContinuation { continuation in
            if batches.isEmpty {
                firstStartWaiters.append(continuation)
            } else {
                continuation.resume()
            }
        }
    }

    func releaseFirst() {
        firstReleased = true
        let waiters = firstReleaseWaiters
        firstReleaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func batchCount() -> Int { batches.count }

    func snapshot() -> [[String: String]] { batches }

    func latestPath(for itemID: String) -> String? { latestByID[itemID] }
}

private enum ThumbnailBatchTestError: Error, LocalizedError {
    case forcedFailure

    var errorDescription: String? {
        switch self {
        case .forcedFailure: "forced thumbnail batch failure"
        }
    }
}

private final class ThumbnailRetryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let failuresBeforeSuccess: Int?
    private var attemptCount = 0
    private var successfulBatches: [[String: String]] = []

    init(failuresBeforeSuccess: Int?) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func handle(_ batch: [String: String]) throws {
        lock.lock()
        attemptCount += 1
        let shouldFail = failuresBeforeSuccess.map { attemptCount <= $0 } ?? true
        if !shouldFail {
            successfulBatches.append(batch)
        }
        lock.unlock()
        if shouldFail {
            throw ThumbnailBatchTestError.forcedFailure
        }
    }

    var attempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return attemptCount
    }

    var successes: [[String: String]] {
        lock.lock()
        defer { lock.unlock() }
        return successfulBatches
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

func testThumbnailPathBatcherCancelAndWaitSettlesRunningHandler() async throws {
    let gate = ThumbnailFlushGate()
    let batcher = ThumbnailPathBatcher(
        maxBatchSize: 1,
        flushIntervalNanoseconds: 1_000_000_000,
        flushHandler: { _ in
            await gate.markStarted()
            await gate.waitForRelease()
            await gate.finish()
        }
    )

    let enqueueTask = Task {
        try? await batcher.enqueue(itemID: "gated", thumbnailPath: "/tmp/gated.jpg")
    }
    await gate.waitForStart()
    let cancelTask = Task {
        await batcher.cancelAndWait()
        await gate.markCancelCompleted()
    }
    try await Task.sleep(nanoseconds: 5_000_000)
    let finishedWhileWaiting = await gate.isFinished()
    let cancelCompletedWhileWaiting = await gate.isCancelCompleted()
    try expect(!finishedWhileWaiting, "cancelAndWait must remain pending while the flush handler is physically gated")
    try expect(!cancelCompletedWhileWaiting, "cancelAndWait must not return before the running handler settles")

    await gate.release()
    _ = await enqueueTask.value
    await cancelTask.value
    let finished = await gate.isFinished()
    let cancelCompleted = await gate.isCancelCompleted()
    let pendingCount = await batcher.pendingCount
    try expect(finished, "cancelAndWait must return only after the running flush handler settles")
    try expect(cancelCompleted, "cancelAndWait should complete after the physical handler barrier")
    try expect(pendingCount == 0, "cancelAndWait must drop updates queued for the canceled context")
}

func testThumbnailPathBatcherSerializesReentrantSameIDAndUsesLatestPath() async throws {
    let gate = ThumbnailReentrantFlushGate()
    let batcher = ThumbnailPathBatcher(
        maxBatchSize: 1,
        flushIntervalNanoseconds: 1_000_000_000,
        flushHandler: { batch in await gate.receive(batch) }
    )

    let oldTask = Task {
        try? await batcher.enqueue(itemID: "reentrant", thumbnailPath: "/tmp/old.jpg")
    }
    await gate.waitForFirstStart()

    let latestTask = Task {
        try? await batcher.enqueue(itemID: "reentrant", thumbnailPath: "/tmp/new.jpg")
    }
    try await Task.sleep(nanoseconds: 5_000_000)
    let batchCountBeforeRelease = await gate.batchCount()
    try expect(batchCountBeforeRelease == 1, "a reentrant same-ID update must wait behind the older handler")

    await gate.releaseFirst()
    _ = await oldTask.value
    _ = await latestTask.value
    let batches = await gate.snapshot()
    try expect(
        batches == [
            ["reentrant": "/tmp/old.jpg"],
            ["reentrant": "/tmp/new.jpg"]
        ],
        "a late old handler must settle before the latest same-ID successor is delivered"
    )
    let pendingCount = await batcher.pendingCount
    let latestPath = await gate.latestPath(for: "reentrant")
    try expect(pendingCount == 0, "the latest same-ID successor must not remain pending")
    try expect(latestPath == "/tmp/new.jpg", "the final persisted same-ID path must be the newest value")
}

func testThumbnailPathBatcherHandlerEnqueueRegistersSuccessorWithoutDeadlock() async throws {
    let outcome = ThumbnailReentrantOutcome()
    let batcher = ThumbnailPathBatcher(
        maxBatchSize: 1,
        flushIntervalNanoseconds: 1_000_000_000,
        contextualFlushHandler: { context, batch in
            await outcome.record(batch)
            guard batch["initial"] != nil else { return }
            try await requireThumbnailOperationToFinishWithin(.milliseconds(100)) {
                _ = try await context.enqueue(itemID: "successor", thumbnailPath: "/tmp/successor.jpg")
            }
            await outcome.markHandlerEnqueueReturned()
        }
    )

    try await requireThumbnailOperationToFinishWithin {
        _ = try await batcher.enqueue(itemID: "initial", thumbnailPath: "/tmp/initial.jpg")
    }

    let batches = await outcome.snapshot()
    let pendingCount = await batcher.pendingCount
    let didHandlerEnqueueReturn = await outcome.didHandlerEnqueueReturn()
    try expect(didHandlerEnqueueReturn, "handler enqueue should return before the outer flush settles")
    try expect(
        batches == [
            ["initial": "/tmp/initial.jpg"],
            ["successor": "/tmp/successor.jpg"]
        ],
        "a threshold successor registered by the handler should flush after the current handler settles"
    )
    try expect(pendingCount == 0, "a threshold successor should not remain pending after the outer flush settles")
}

func testThumbnailPathBatcherHandlerCancelAndWaitSkipsCurrentTaskWithoutDeadlock() async throws {
    let outcome = ThumbnailReentrantOutcome()
    let batcher = ThumbnailPathBatcher(
        maxBatchSize: 1,
        flushIntervalNanoseconds: 1_000_000_000,
        contextualFlushHandler: { context, batch in
            await outcome.record(batch)
            guard batch["initial"] != nil else { return }
            try await requireThumbnailOperationToFinishWithin(.milliseconds(100)) {
                await context.cancelAndWait()
            }
            await outcome.markHandlerCancelReturned()
        }
    )

    try await requireThumbnailOperationToFinishWithin {
        _ = try await batcher.enqueue(itemID: "initial", thumbnailPath: "/tmp/initial.jpg")
    }

    let batches = await outcome.snapshot()
    let pendingCount = await batcher.pendingCount
    let isCancelled = await batcher.isCancelled
    let didHandlerCancelReturn = await outcome.didHandlerCancelReturn()
    try expect(didHandlerCancelReturn, "handler cancelAndWait should return without awaiting its own task")
    try expect(batches == [["initial": "/tmp/initial.jpg"]], "handler cancellation should not schedule a successor batch")
    try expect(pendingCount == 0 && isCancelled, "handler cancellation should clear pending state and remain canceled")
}

func testThumbnailPathBatcherInheritedLegacyChildPreservesPhysicalCancelBarrier() async throws {
    let reference = ThumbnailBatcherReference()
    let gate = ThumbnailFlushGate()
    let batcher = ThumbnailPathBatcher(
        maxBatchSize: 1,
        flushIntervalNanoseconds: 1_000_000_000,
        flushHandler: { _ in
            guard let batcher = await reference.get() else {
                throw CoreUnitTestError.failure("legacy child barrier test must publish its batcher reference")
            }
            await gate.markStarted()
            Task {
                await gate.markChildStarted()
                await batcher.cancelAndWait()
                await gate.markCancelCompleted()
            }
            await gate.waitForRelease()
            await gate.finish()
        }
    )
    await reference.set(batcher)

    let enqueueTask = Task {
        try? await batcher.enqueue(itemID: "legacy-child", thumbnailPath: "/tmp/legacy-child.jpg")
    }
    await gate.waitForStart()
    await gate.waitForChildStart()
    try await Task.sleep(nanoseconds: 5_000_000)
    let cancelCompletedWhileParentIsGated = await gate.isCancelCompleted()
    try expect(!cancelCompletedWhileParentIsGated, "an inherited legacy child must not bypass the physical handler barrier")

    await gate.release()
    _ = await enqueueTask.value
    try await requireThumbnailOperationToFinishWithin {
        await gate.waitForCancelCompleted()
    }
    let handlerFinished = await gate.isFinished()
    try expect(handlerFinished, "the physical handler must settle before inherited-child cancellation returns")
}

func testThumbnailPathBatcherHandlerFlushSkipsCurrentTaskWithoutDeadlock() async throws {
    let outcome = ThumbnailReentrantOutcome()
    let batcher = ThumbnailPathBatcher(
        maxBatchSize: 1,
        flushIntervalNanoseconds: 1_000_000_000,
        contextualFlushHandler: { context, batch in
            await outcome.record(batch)
            guard batch["initial"] != nil else { return }
            _ = try await context.enqueue(itemID: "successor", thumbnailPath: "/tmp/successor.jpg")
            try await requireThumbnailOperationToFinishWithin(.milliseconds(100)) {
                _ = try await context.flush()
            }
            await outcome.markHandlerEnqueueReturned()
        }
    )

    try await requireThumbnailOperationToFinishWithin {
        _ = try await batcher.enqueue(itemID: "initial", thumbnailPath: "/tmp/initial.jpg")
    }

    let batches = await outcome.snapshot()
    let pendingCount = await batcher.pendingCount
    let didHandlerReturn = await outcome.didHandlerEnqueueReturn()
    try expect(didHandlerReturn, "handler flush should return without awaiting the active handler task")
    try expect(
        batches == [
            ["initial": "/tmp/initial.jpg"],
            ["successor": "/tmp/successor.jpg"]
        ],
        "outer flush should deliver the threshold successor after the handler settles"
    )
    try expect(pendingCount == 0, "handler flush should not leave a threshold successor pending")
}

func testThumbnailPathBatcherInheritedLateChildDoesNotStickSuccessorPending() async throws {
    let reference = ThumbnailBatcherReference()
    let outcome = ThumbnailReentrantOutcome()
    let gate = ThumbnailLateChildGate()
    let batcher = ThumbnailPathBatcher(
        maxBatchSize: 1,
        flushIntervalNanoseconds: 1_000_000_000,
        flushHandler: { batch in
            await outcome.record(batch)
            guard batch["initial"] != nil else { return }
            guard let batcher = await reference.get() else {
                throw CoreUnitTestError.failure("late child test must publish its batcher reference")
            }
            Task {
                await gate.waitForChildRelease()
                _ = try? await batcher.enqueue(itemID: "successor", thumbnailPath: "/tmp/successor.jpg")
                await gate.markChildCompleted()
            }
            await gate.markHandlerReturned()
        }
    )
    await reference.set(batcher)

    let initialTask = Task {
        try? await batcher.enqueue(itemID: "initial", thumbnailPath: "/tmp/initial.jpg")
    }
    defer { initialTask.cancel() }
    try await requireThumbnailOperationToFinishWithin {
        await gate.waitForHandlerReturn()
        _ = await initialTask.value
    }
    await gate.releaseChild()
    try await requireThumbnailOperationToFinishWithin {
        await gate.waitForChildCompletion()
    }

    let batches = await outcome.snapshot()
    let pendingCount = await batcher.pendingCount
    try expect(
        batches == [
            ["initial": "/tmp/initial.jpg"],
            ["successor": "/tmp/successor.jpg"]
        ],
        "a late inherited child should flush its threshold successor after the original handler settles"
    )
    try expect(pendingCount == 0, "a late inherited child must not strand a threshold successor")
}

func testThumbnailPathBatcherDetachedHandlerEnqueueSkipsCurrentTaskWithoutDeadlock() async throws {
    let outcome = ThumbnailReentrantOutcome()
    let batcher = ThumbnailPathBatcher(
        maxBatchSize: 1,
        flushIntervalNanoseconds: 1_000_000_000,
        contextualFlushHandler: { context, batch in
            await outcome.record(batch)
            guard batch["initial"] != nil else { return }
            try await requireThumbnailOperationToFinishWithin(.milliseconds(100)) {
                _ = try await Task.detached {
                    try await context.enqueue(itemID: "successor", thumbnailPath: "/tmp/successor.jpg")
                }.value
            }
            await outcome.markHandlerEnqueueReturned()
        }
    )

    try await requireThumbnailOperationToFinishWithin {
        _ = try await batcher.enqueue(itemID: "initial", thumbnailPath: "/tmp/initial.jpg")
    }

    let batches = await outcome.snapshot()
    let pendingCount = await batcher.pendingCount
    let didHandlerReturn = await outcome.didHandlerEnqueueReturn()
    try expect(didHandlerReturn, "detached handler enqueue should return without awaiting the active handler task")
    try expect(
        batches == [
            ["initial": "/tmp/initial.jpg"],
            ["successor": "/tmp/successor.jpg"]
        ],
        "detached handler enqueue should deliver a threshold successor after the handler settles"
    )
    try expect(pendingCount == 0, "detached handler enqueue should not leave a threshold successor pending")
}

func testThumbnailPathBatcherDetachedHandlerCancelAndWaitSkipsCurrentTaskWithoutDeadlock() async throws {
    let outcome = ThumbnailReentrantOutcome()
    let batcher = ThumbnailPathBatcher(
        maxBatchSize: 1,
        flushIntervalNanoseconds: 1_000_000_000,
        contextualFlushHandler: { context, batch in
            await outcome.record(batch)
            guard batch["initial"] != nil else { return }
            try await requireThumbnailOperationToFinishWithin(.milliseconds(100)) {
                await Task.detached {
                    await context.cancelAndWait()
                }.value
            }
            await outcome.markHandlerCancelReturned()
        }
    )

    try await requireThumbnailOperationToFinishWithin {
        _ = try await batcher.enqueue(itemID: "initial", thumbnailPath: "/tmp/initial.jpg")
    }

    let batches = await outcome.snapshot()
    let pendingCount = await batcher.pendingCount
    let isCancelled = await batcher.isCancelled
    let didHandlerReturn = await outcome.didHandlerCancelReturn()
    try expect(didHandlerReturn, "detached handler cancelAndWait should return without awaiting the active handler task")
    try expect(batches == [["initial": "/tmp/initial.jpg"]], "detached handler cancellation should not schedule a successor")
    try expect(pendingCount == 0 && isCancelled, "detached handler cancellation should clear pending state")
}

func testThumbnailPathBatcherDetachedHandlerFlushSkipsCurrentTaskWithoutDeadlock() async throws {
    let outcome = ThumbnailReentrantOutcome()
    let batcher = ThumbnailPathBatcher(
        maxBatchSize: 1,
        flushIntervalNanoseconds: 1_000_000_000,
        contextualFlushHandler: { context, batch in
            await outcome.record(batch)
            guard batch["initial"] != nil else { return }
            _ = try await context.enqueue(itemID: "successor", thumbnailPath: "/tmp/successor.jpg")
            try await requireThumbnailOperationToFinishWithin(.milliseconds(100)) {
                _ = try await Task.detached {
                    try await context.flush()
                }.value
            }
            await outcome.markHandlerEnqueueReturned()
        }
    )

    try await requireThumbnailOperationToFinishWithin {
        _ = try await batcher.enqueue(itemID: "initial", thumbnailPath: "/tmp/initial.jpg")
    }

    let batches = await outcome.snapshot()
    let pendingCount = await batcher.pendingCount
    let didHandlerReturn = await outcome.didHandlerEnqueueReturn()
    try expect(didHandlerReturn, "detached handler flush should return without awaiting the active handler task")
    try expect(
        batches == [
            ["initial": "/tmp/initial.jpg"],
            ["successor": "/tmp/successor.jpg"]
        ],
        "detached handler flush should allow the outer flush to deliver the successor"
    )
    try expect(pendingCount == 0, "detached handler flush should not leave a threshold successor pending")
}

func testThumbnailPathBatcherRetriesAutomaticTimerFailureUntilSuccess() async throws {
    let recorder = ThumbnailRetryRecorder(failuresBeforeSuccess: 1)
    let batcher = ThumbnailPathBatcher(
        maxBatchSize: 50,
        flushIntervalNanoseconds: 1_000_000,
        automaticRetryLimit: 2,
        automaticRetryBackoffNanoseconds: 1_000_000,
        flushHandler: { batch in try recorder.handle(batch) }
    )

    _ = try await batcher.enqueue(itemID: "retry-success", thumbnailPath: "/tmp/retry-success.jpg")
    try await Task.sleep(nanoseconds: 40_000_000)
    try expect(recorder.attempts == 2, "automatic timer retry should make one bounded retry after a failure")
    try expect(recorder.successes == [["retry-success": "/tmp/retry-success.jpg"]], "a later automatic retry should deliver the pending batch")
    let pendingCount = await batcher.pendingCount
    let lastError = await batcher.lastError
    try expect(pendingCount == 0, "a successful automatic retry should clear pending updates")
    try expect(lastError == nil, "a successful automatic retry should clear lastError")
}

func testThumbnailPathBatcherStopsAutomaticRetryAfterBoundedExhaustion() async throws {
    let recorder = ThumbnailRetryRecorder(failuresBeforeSuccess: 3)
    let batcher = ThumbnailPathBatcher(
        maxBatchSize: 50,
        flushIntervalNanoseconds: 1_000_000,
        automaticRetryLimit: 2,
        automaticRetryBackoffNanoseconds: 1_000_000,
        flushHandler: { batch in try recorder.handle(batch) }
    )

    _ = try await batcher.enqueue(itemID: "retry-exhausted", thumbnailPath: "/tmp/retry-exhausted.jpg")
    try await Task.sleep(nanoseconds: 40_000_000)
    let attemptsAtExhaustion = recorder.attempts
    let pendingCount = await batcher.pendingCount
    let lastError = await batcher.lastError
    try expect(attemptsAtExhaustion == 3, "automatic retries must stop after the configured retry limit")
    try expect(pendingCount == 1, "exhausted automatic retries should retain the pending update")
    try expect(lastError == ThumbnailBatchTestError.forcedFailure.localizedDescription, "exhaustion should keep the latest automatic failure observable")

    try await Task.sleep(nanoseconds: 20_000_000)
    try expect(recorder.attempts == attemptsAtExhaustion, "automatic retry exhaustion must not loop forever")

    _ = try await batcher.enqueue(itemID: "retry-exhausted", thumbnailPath: "/tmp/retry-exhausted-new.jpg")
    try await Task.sleep(nanoseconds: 40_000_000)
    try expect(recorder.attempts == attemptsAtExhaustion + 1, "a new pending value should start a fresh bounded retry window")
    try expect(recorder.successes == [["retry-exhausted": "/tmp/retry-exhausted-new.jpg"]], "the fresh retry window should deliver the newest path")
}

func testThumbnailPathBatcherExplicitFlushStillThrowsWithoutAutomaticRetry() async throws {
    let recorder = ThumbnailRetryRecorder(failuresBeforeSuccess: nil)
    let batcher = ThumbnailPathBatcher(
        maxBatchSize: 50,
        flushIntervalNanoseconds: 1_000_000,
        automaticRetryLimit: 2,
        automaticRetryBackoffNanoseconds: 1_000_000,
        flushHandler: { batch in try recorder.handle(batch) }
    )

    _ = try await batcher.enqueue(itemID: "explicit-failure", thumbnailPath: "/tmp/explicit-failure.jpg")
    do {
        _ = try await batcher.flush()
        throw CoreUnitTestError.failure("explicit flush should expose the handler failure")
    } catch ThumbnailBatchTestError.forcedFailure {
        // Expected: explicit flush retains its throwing contract.
    }
    try expect(recorder.attempts == 1, "explicit flush failure must not start automatic retries")
    let pendingCount = await batcher.pendingCount
    try expect(pendingCount == 1, "explicit flush failure should retain the pending update for a later explicit retry")
    try await Task.sleep(nanoseconds: 20_000_000)
    try expect(recorder.attempts == 1, "an explicit flush failure must not be retried by the canceled timer")
}
