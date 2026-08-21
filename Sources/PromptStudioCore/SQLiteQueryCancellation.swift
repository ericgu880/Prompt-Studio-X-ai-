import Foundation

/// A per-query cancellation token shared by Swift tasks and SQLite's progress
/// callback. Cancelling the token is idempotent and invokes every interrupt
/// handler currently registered for the query.
public final class SQLiteQueryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [UUID: @Sendable () -> Void] = [:]

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        let pendingHandlers: [@Sendable () -> Void]
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        pendingHandlers = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()

        for handler in pendingHandlers {
            handler()
        }
    }

    public func throwIfCancelled() throws {
        if isCancelled {
            throw CancellationError()
        }
    }

    func addInterruptHandler(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let invokeImmediately: Bool
        lock.lock()
        if cancelled {
            invokeImmediately = true
        } else {
            handlers[id] = handler
            invokeImmediately = false
        }
        lock.unlock()

        if invokeImmediately {
            handler()
        }
        return id
    }

    func removeInterruptHandler(_ id: UUID) {
        lock.lock()
        handlers.removeValue(forKey: id)
        lock.unlock()
    }
}
