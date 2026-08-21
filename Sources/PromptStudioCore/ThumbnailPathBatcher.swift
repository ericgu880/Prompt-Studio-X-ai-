import Foundation

/// Coalesces generated thumbnail paths before handing them to a repository.
///
/// A batch is flushed as soon as it reaches `maxBatchSize`, or when the first
/// pending update has waited `flushInterval`.  The handler is intentionally
/// generic so callers can use the same timing/coalescing behavior with a
/// repository, a test recorder, or another persistence layer. Handler calls
/// are serialized; updates received while a handler is running become the
/// successor batch, so a newer path for the same ID cannot race an older one.
public actor ThumbnailPathBatcher {
    /// Legacy non-reentrant handler. A handler that needs to call back into the
    /// batcher must use `ContextualFlushHandler` and its explicit context.
    public typealias FlushHandler = @Sendable ([String: String]) async throws -> Void

    /// Capability handed to a contextual flush handler for the exact flush
    /// that invoked it. Calls made through this value can safely re-enter the
    /// batcher from child or detached tasks without waiting on that same
    /// handler task. Keep this context when spawning asynchronous work; the
    /// legacy one-argument handler does not provide that guarantee to detached
    /// tasks.
    public struct HandlerContext: Sendable {
        fileprivate let batcher: ThumbnailPathBatcher
        fileprivate let batcherID: UUID
        fileprivate let flushID: UUID

        fileprivate init(batcher: ThumbnailPathBatcher, batcherID: UUID, flushID: UUID) {
            self.batcher = batcher
            self.batcherID = batcherID
            self.flushID = flushID
        }

        @discardableResult
        public func enqueue(_ updates: [String: String]) async throws -> Int {
            try await batcher.enqueue(updates, handlerContext: self)
        }

        @discardableResult
        public func enqueue(itemID: String, thumbnailPath: String) async throws -> Int {
            try await enqueue([itemID: thumbnailPath])
        }

        @discardableResult
        public func flush() async throws -> Int {
            try await batcher.flush(handlerContext: self)
        }

        public func cancelAndWait() async {
            await batcher.cancelAndWait(handlerContext: self)
        }
    }

    public typealias ContextualFlushHandler = @Sendable (HandlerContext, [String: String]) async throws -> Void

    public static let defaultMaxBatchSize = 50
    public static let defaultFlushIntervalNanoseconds: UInt64 = 250_000_000
    public static let defaultAutomaticRetryLimit = 3
    public static let defaultAutomaticRetryBackoffNanoseconds: UInt64 = 50_000_000

    private let maxBatchSize: Int
    private let flushIntervalNanoseconds: UInt64
    private let automaticRetryLimit: Int
    private let automaticRetryBackoffNanoseconds: UInt64
    private let flushHandler: FlushHandler?
    private let contextualFlushHandler: ContextualFlushHandler?
    private let batcherID = UUID()
    private var pending: [String: String] = [:]
    private var timerTask: Task<Void, Never>?
    private var runningFlushTasks: [UUID: Task<Void, Error>] = [:]
    private var activeFlushID: UUID?
    private var activeFlushUpdates: [String: String] = [:]
    private var activeFlushTask: Task<Void, Error>?
    private var automaticRetryAttempt = 0
    private var automaticRetryExhausted = false
    private var cancelled = false
    private var forceFlushAfterActive = false
    private var lastErrorDescription: String?

    /// `automaticRetryLimit` counts retries after the initial timer attempt.
    /// Automatic retries use bounded exponential backoff and stop with the
    /// pending batch retained when the limit is exhausted.
    public init(
        maxBatchSize: Int = 50,
        flushInterval: Duration = .milliseconds(250),
        automaticRetryLimit: Int = ThumbnailPathBatcher.defaultAutomaticRetryLimit,
        automaticRetryBackoff: Duration = .milliseconds(50),
        flushHandler: @escaping FlushHandler
    ) {
        self.maxBatchSize = max(1, maxBatchSize)
        self.flushIntervalNanoseconds = Self.nanoseconds(for: flushInterval)
        self.automaticRetryLimit = max(0, automaticRetryLimit)
        self.automaticRetryBackoffNanoseconds = Self.nanoseconds(for: automaticRetryBackoff)
        self.flushHandler = flushHandler
        self.contextualFlushHandler = nil
    }

    public init(
        maxBatchSize: Int = 50,
        flushIntervalNanoseconds: UInt64,
        automaticRetryLimit: Int = ThumbnailPathBatcher.defaultAutomaticRetryLimit,
        automaticRetryBackoffNanoseconds: UInt64 = ThumbnailPathBatcher.defaultAutomaticRetryBackoffNanoseconds,
        flushHandler: @escaping FlushHandler
    ) {
        self.maxBatchSize = max(1, maxBatchSize)
        self.flushIntervalNanoseconds = max(1, flushIntervalNanoseconds)
        self.automaticRetryLimit = max(0, automaticRetryLimit)
        self.automaticRetryBackoffNanoseconds = max(1, automaticRetryBackoffNanoseconds)
        self.flushHandler = flushHandler
        self.contextualFlushHandler = nil
    }

    /// Creates a batcher whose handler receives a `HandlerContext`. Detached
    /// or child tasks that may re-enter the batcher must capture and use that
    /// context rather than calling the batcher directly.
    public init(
        maxBatchSize: Int = 50,
        flushInterval: Duration = .milliseconds(250),
        automaticRetryLimit: Int = ThumbnailPathBatcher.defaultAutomaticRetryLimit,
        automaticRetryBackoff: Duration = .milliseconds(50),
        contextualFlushHandler: @escaping ContextualFlushHandler
    ) {
        self.maxBatchSize = max(1, maxBatchSize)
        self.flushIntervalNanoseconds = Self.nanoseconds(for: flushInterval)
        self.automaticRetryLimit = max(0, automaticRetryLimit)
        self.automaticRetryBackoffNanoseconds = Self.nanoseconds(for: automaticRetryBackoff)
        self.flushHandler = nil
        self.contextualFlushHandler = contextualFlushHandler
    }

    /// Nanosecond-based counterpart to the contextual-handler initializer.
    public init(
        maxBatchSize: Int = 50,
        flushIntervalNanoseconds: UInt64,
        automaticRetryLimit: Int = ThumbnailPathBatcher.defaultAutomaticRetryLimit,
        automaticRetryBackoffNanoseconds: UInt64 = ThumbnailPathBatcher.defaultAutomaticRetryBackoffNanoseconds,
        contextualFlushHandler: @escaping ContextualFlushHandler
    ) {
        self.maxBatchSize = max(1, maxBatchSize)
        self.flushIntervalNanoseconds = max(1, flushIntervalNanoseconds)
        self.automaticRetryLimit = max(0, automaticRetryLimit)
        self.automaticRetryBackoffNanoseconds = max(1, automaticRetryBackoffNanoseconds)
        self.flushHandler = nil
        self.contextualFlushHandler = contextualFlushHandler
    }

    public var pendingCount: Int { pending.count }

    public var isCancelled: Bool { cancelled }

    /// The most recent automatic flush failure, if any. Explicit `flush()`
    /// calls still throw the underlying error directly.
    public var lastError: String? { lastErrorDescription }

    /// Adds one update and returns the number of batches flushed synchronously
    /// as a result of this call (normally zero or one).
    @discardableResult
    public func enqueue(itemID: String, thumbnailPath: String) async throws -> Int {
        try await enqueue([itemID: thumbnailPath])
    }

    @discardableResult
    public func enqueue(itemID: String, path: String) async throws -> Int {
        try await enqueue(itemID: itemID, thumbnailPath: path)
    }

    @discardableResult
    public func append(itemID: String, thumbnailPath: String) async throws -> Int {
        try await enqueue(itemID: itemID, thumbnailPath: thumbnailPath)
    }

    @discardableResult
    public func add(itemID: String, thumbnailPath: String) async throws -> Int {
        try await enqueue(itemID: itemID, thumbnailPath: thumbnailPath)
    }

    /// Adds several updates. Duplicate IDs are coalesced with the last path
    /// supplied. Large inputs are split into `maxBatchSize`-sized writes.
    @discardableResult
    public func enqueue(_ updates: [String: String]) async throws -> Int {
        try await enqueue(updates, handlerContext: nil)
    }

    @discardableResult
    fileprivate func enqueue(
        _ updates: [String: String],
        handlerContext: HandlerContext?
    ) async throws -> Int {
        guard !cancelled, !updates.isEmpty else { return 0 }

        resetAutomaticRetryState()
        var flushedCount = 0
        for (itemID, thumbnailPath) in updates {
            guard !cancelled else { break }
            pending[itemID] = thumbnailPath
            if pending.count >= maxBatchSize {
                cancelTimer()
                if isCurrentHandlerCall(handlerContext) {
                    continue
                }
                _ = try await flushPending()
                flushedCount += 1
            } else {
                scheduleTimerIfNeeded()
            }
        }
        return flushedCount
    }

    /// Flushes all pending updates immediately. The returned value is either
    /// zero (nothing pending) or one (one repository batch).
    @discardableResult
    public func flush() async throws -> Int {
        try await flush(handlerContext: nil)
    }

    @discardableResult
    fileprivate func flush(handlerContext: HandlerContext?) async throws -> Int {
        guard !cancelled else { return 0 }
        cancelTimer()
        guard !pending.isEmpty else { return 0 }
        if isCurrentHandlerCall(handlerContext) {
            forceFlushAfterActive = true
            return 0
        }
        _ = try await flushPending()
        return 1
    }

    /// Drops pending updates and prevents future enqueues. A handler that is
    /// already running is not interrupted, but its failed updates are not
    /// requeued after cancellation.
    public func cancel() {
        cancelled = true
        cancelTimer()
        pending.removeAll(keepingCapacity: false)
        forceFlushAfterActive = false
    }

    /// Prevents new work and waits for every handler that entered before the
    /// cancellation barrier. Repository transactions are allowed to settle;
    /// callers can then replace their library context without a late commit.
    public func cancelAndWait() async {
        await cancelAndWait(handlerContext: nil)
    }

    fileprivate func cancelAndWait(handlerContext: HandlerContext?) async {
        cancel()
        let currentFlushID = isCurrentHandlerCall(handlerContext) ? activeFlushID : nil
        let tasks = runningFlushTasks.compactMap { flushID, task in
            flushID == currentFlushID ? nil : task
        }
        for task in tasks {
            _ = try? await task.value
        }
    }

    private func isCurrentHandlerCall(_ handlerContext: HandlerContext?) -> Bool {
        guard let handlerContext, let activeFlushID else { return false }
        return handlerContext.batcherID == batcherID && handlerContext.flushID == activeFlushID
    }

    private func scheduleTimerIfNeeded() {
        guard timerTask == nil, !automaticRetryExhausted else { return }
        scheduleTimer(after: flushIntervalNanoseconds)
    }

    private func scheduleTimer(after nanoseconds: UInt64) {
        guard timerTask == nil else { return }
        timerTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.timerDidFire()
        }
    }

    private func timerDidFire() async {
        timerTask = nil
        guard !cancelled, !pending.isEmpty else { return }
        do {
            _ = try await flushPending()
            resetAutomaticRetryState()
        } catch {
            lastErrorDescription = error.localizedDescription
            guard !cancelled, !pending.isEmpty else { return }
            guard automaticRetryAttempt < automaticRetryLimit else {
                timerTask?.cancel()
                timerTask = nil
                automaticRetryExhausted = true
                return
            }
            automaticRetryAttempt += 1
            timerTask?.cancel()
            timerTask = nil
            scheduleTimer(after: automaticRetryDelayNanoseconds(for: automaticRetryAttempt))
        }
    }

    private func flushPending() async throws -> Bool {
        while true {
            if let activeFlushID, let activeFlushTask {
                do {
                    try await activeFlushTask.value
                    settleActiveFlush(id: activeFlushID, error: nil)
                } catch {
                    settleActiveFlush(id: activeFlushID, error: error)
                    forceFlushAfterActive = false
                    throw error
                }
                if cancelled { return false }
                continue
            }

            guard !cancelled, !pending.isEmpty else { return false }
            let updates = pending
            pending.removeAll(keepingCapacity: true)
            let flushID = UUID()
            let handler = flushHandler
            let contextualHandler = contextualFlushHandler
            let handlerContext = HandlerContext(batcher: self, batcherID: batcherID, flushID: flushID)
            let flushTask = Task {
                if let contextualHandler {
                    try await contextualHandler(handlerContext, updates)
                } else if let handler {
                    try await handler(updates)
                }
            }
            activeFlushID = flushID
            activeFlushUpdates = updates
            activeFlushTask = flushTask
            runningFlushTasks[flushID] = flushTask
            do {
                try await flushTask.value
                settleActiveFlush(id: flushID, error: nil)
                if cancelled { return false }
                let shouldFlushSuccessor = forceFlushAfterActive || pending.count >= maxBatchSize
                forceFlushAfterActive = false
                if !shouldFlushSuccessor { return true }
                continue
            } catch {
                settleActiveFlush(id: flushID, error: error)
                forceFlushAfterActive = false
                throw error
            }
        }
    }

    private func settleActiveFlush(id: UUID, error: Error?) {
        guard activeFlushID == id else { return }
        let updates = activeFlushUpdates
        activeFlushID = nil
        activeFlushUpdates.removeAll(keepingCapacity: true)
        activeFlushTask = nil
        runningFlushTasks[id] = nil

        if let error {
            if !cancelled {
                for (itemID, thumbnailPath) in updates where pending[itemID] == nil {
                    pending[itemID] = thumbnailPath
                }
            }
            lastErrorDescription = error.localizedDescription
        } else {
            lastErrorDescription = nil
        }
    }

    private func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
        resetAutomaticRetryState()
    }

    private func resetAutomaticRetryState() {
        automaticRetryAttempt = 0
        automaticRetryExhausted = false
    }

    private func automaticRetryDelayNanoseconds(for retryAttempt: Int) -> UInt64 {
        guard retryAttempt > 0 else { return max(1, automaticRetryBackoffNanoseconds) }
        var delay = max(1, automaticRetryBackoffNanoseconds)
        for _ in 1..<retryAttempt {
            if delay > UInt64.max / 2 {
                return UInt64.max
            }
            delay *= 2
        }
        return delay
    }

    private static func nanoseconds(for interval: Duration) -> UInt64 {
        let components = interval.components
        let seconds = max(0, components.seconds)
        let attoseconds = max(0, components.attoseconds)
        let wholeSeconds = UInt64(seconds)
        let nanosFromSeconds = wholeSeconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !nanosFromSeconds.overflow else { return UInt64.max }
        let nanosFromAttoseconds = UInt64(attoseconds / 1_000_000_000)
        let total = nanosFromSeconds.partialValue.addingReportingOverflow(nanosFromAttoseconds)
        return max(1, total.overflow ? UInt64.max : total.partialValue)
    }
}
