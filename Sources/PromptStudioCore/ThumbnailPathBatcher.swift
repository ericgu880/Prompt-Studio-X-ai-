import Foundation

/// Coalesces generated thumbnail paths before handing them to a repository.
///
/// A batch is flushed as soon as it reaches `maxBatchSize`, or when the first
/// pending update has waited `flushInterval`.  The handler is intentionally
/// generic so callers can use the same timing/coalescing behavior with a
/// repository, a test recorder, or another persistence layer.
public actor ThumbnailPathBatcher {
    public typealias FlushHandler = @Sendable ([String: String]) async throws -> Void

    public static let defaultMaxBatchSize = 50
    public static let defaultFlushIntervalNanoseconds: UInt64 = 250_000_000

    private let maxBatchSize: Int
    private let flushIntervalNanoseconds: UInt64
    private let flushHandler: FlushHandler
    private var pending: [String: String] = [:]
    private var timerTask: Task<Void, Never>?
    private var cancelled = false
    private var lastErrorDescription: String?

    public init(
        maxBatchSize: Int = 50,
        flushInterval: Duration = .milliseconds(250),
        flushHandler: @escaping FlushHandler
    ) {
        self.maxBatchSize = max(1, maxBatchSize)
        self.flushIntervalNanoseconds = Self.nanoseconds(for: flushInterval)
        self.flushHandler = flushHandler
    }

    public init(
        maxBatchSize: Int = 50,
        flushIntervalNanoseconds: UInt64,
        flushHandler: @escaping FlushHandler
    ) {
        self.maxBatchSize = max(1, maxBatchSize)
        self.flushIntervalNanoseconds = max(1, flushIntervalNanoseconds)
        self.flushHandler = flushHandler
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
        guard !cancelled, !updates.isEmpty else { return 0 }

        var flushedCount = 0
        for (itemID, thumbnailPath) in updates {
            guard !cancelled else { break }
            pending[itemID] = thumbnailPath
            if pending.count >= maxBatchSize {
                cancelTimer()
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
        guard !cancelled else { return 0 }
        cancelTimer()
        guard !pending.isEmpty else { return 0 }
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
    }

    private func scheduleTimerIfNeeded() {
        guard timerTask == nil else { return }
        let nanoseconds = flushIntervalNanoseconds
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
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    private func flushPending() async throws -> Bool {
        guard !cancelled, !pending.isEmpty else { return false }
        let updates = pending
        pending.removeAll(keepingCapacity: true)
        do {
            try await flushHandler(updates)
            lastErrorDescription = nil
            return true
        } catch {
            if !cancelled {
                for (itemID, thumbnailPath) in updates where pending[itemID] == nil {
                    pending[itemID] = thumbnailPath
                }
            }
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    private func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
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
