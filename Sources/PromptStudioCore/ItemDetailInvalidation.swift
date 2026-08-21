import Foundation

/// A committed mutation that can make an item-detail snapshot stale.
///
/// The event is deliberately scoped to item IDs.  A listener can therefore
/// refresh only the details it owns instead of reloading the complete library.
public struct ItemDetailInvalidationEvent: Equatable, Sendable {
    public let revision: UInt64
    public let changedItemIDs: Set<String>
    public let removedItemIDs: Set<String>
    public let invalidateAll: Bool
    public let itemRevisions: [String: UInt64]

    public init(
        revision: UInt64 = 0,
        changedItemIDs: Set<String> = [],
        removedItemIDs: Set<String> = [],
        invalidateAll: Bool = false,
        itemRevisions: [String: UInt64] = [:]
    ) {
        self.revision = revision
        self.changedItemIDs = changedItemIDs
        self.removedItemIDs = removedItemIDs
        self.invalidateAll = invalidateAll
        self.itemRevisions = itemRevisions
    }

    public var affectedItemIDs: Set<String> {
        changedItemIDs.union(removedItemIDs)
    }

    public var changedIDs: Set<String> { changedItemIDs }
    public var removedIDs: Set<String> { removedItemIDs }
    public var globalRevision: UInt64 { revision }
    public var isFullInvalidation: Bool { invalidateAll }

    public var isEmpty: Bool {
        !invalidateAll && changedItemIDs.isEmpty && removedItemIDs.isEmpty
    }
}

/// Compatibility spelling for callers that name the event as an invalidation.
public typealias ItemDetailInvalidation = ItemDetailInvalidationEvent
public typealias ItemDetailMutationEvent = ItemDetailInvalidationEvent

/// Optional owner boundary for components that keep a point-detail cache.
/// Repository migrations and writes publish through this hub so a cache can
/// invalidate derived snapshots without coupling to UI/startup code.
public protocol ItemDetailInvalidationProviding: AnyObject {
    var itemDetailInvalidationHub: ItemDetailInvalidationHub { get }
}

/// A cancellable observer registration returned by
/// ``ItemDetailInvalidationHub/subscribe(_:)``.
public final class ItemDetailInvalidationSubscription: @unchecked Sendable {
    private weak var hub: ItemDetailInvalidationHub?
    fileprivate let id: UUID
    private let lock = NSLock()
    private var cancelled = false

    fileprivate init(id: UUID, hub: ItemDetailInvalidationHub) {
        self.id = id
        self.hub = hub
    }

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    public func cancel() {
        let shouldCancel = lock.withLock { () -> Bool in
            guard !cancelled else { return false }
            cancelled = true
            return true
        }
        guard shouldCancel else { return }
        hub?.cancel(id: id)
    }

    deinit {
        cancel()
    }
}

/// A library-scoped, thread-safe mutation hub.
///
/// Hubs are shared by canonical database URL.  Two repository instances that
/// open the same library therefore observe one another's committed writes,
/// while different libraries remain isolated.
public final class ItemDetailInvalidationHub: @unchecked Sendable {
    public typealias Handler = @Sendable (ItemDetailInvalidationEvent) -> Void

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: ItemDetailInvalidationHub] = [:]

    public let libraryURL: URL
    public let databaseURL: URL
    public let revision: LibraryDataRevision

    private let lock = NSLock()
    private var handlers: [UUID: Handler] = [:]
    private var perItemRevisions: [String: UInt64] = [:]

    public init(libraryURL: URL, revision: LibraryDataRevision = LibraryDataRevision()) {
        self.libraryURL = libraryURL.standardizedFileURL
        self.databaseURL = Self.canonicalDatabaseURL(for: libraryURL)
        self.revision = revision
    }

    /// Returns the process-wide hub for a library.  The optional revision is
    /// used only when this library has not been seen before.
    public static func shared(
        for libraryURL: URL,
        revision: LibraryDataRevision? = nil
    ) -> ItemDetailInvalidationHub {
        let key = canonicalDatabaseURL(for: libraryURL).path
        return registryLock.withLock {
            if let existing = registry[key] {
                return existing
            }
            let hub = ItemDetailInvalidationHub(
                libraryURL: libraryURL,
                revision: revision ?? LibraryDataRevision()
            )
            registry[key] = hub
            return hub
        }
    }

    public static func forLibrary(
        _ libraryURL: URL,
        revision: LibraryDataRevision? = nil
    ) -> ItemDetailInvalidationHub {
        shared(for: libraryURL, revision: revision)
    }

    public static func shared(
        libraryURL: URL,
        revision: LibraryDataRevision? = nil
    ) -> ItemDetailInvalidationHub {
        shared(for: libraryURL, revision: revision)
    }

    public static func canonicalDatabaseURL(for libraryURL: URL) -> URL {
        libraryURL
            .appendingPathComponent("database", isDirectory: true)
            .appendingPathComponent("promptstudio.sqlite")
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    public static func canonicalKey(for libraryURL: URL) -> String {
        canonicalDatabaseURL(for: libraryURL).path
    }

    public var currentRevision: UInt64 {
        revision.current
    }

    public func itemRevision(for itemID: String) -> UInt64 {
        lock.withLock { perItemRevisions[itemID] ?? 0 }
    }

    @discardableResult
    public func subscribe(_ handler: @escaping Handler) -> ItemDetailInvalidationSubscription {
        let id = UUID()
        lock.withLock { handlers[id] = handler }
        return ItemDetailInvalidationSubscription(id: id, hub: self)
    }

    public func unsubscribe(_ subscription: ItemDetailInvalidationSubscription) {
        subscription.cancel()
    }

    public func cancel(_ subscription: ItemDetailInvalidationSubscription) {
        subscription.cancel()
    }

    /// Publishes one committed mutation.  Callers must invoke this only after
    /// their transaction has returned successfully; the hub itself never
    /// observes uncommitted database state.
    @discardableResult
    public func publish(
        changedItemIDs: some Sequence<String> = [],
        removedItemIDs: some Sequence<String> = [],
        invalidateAll: Bool = false
    ) -> ItemDetailInvalidationEvent? {
        let changed = Set(changedItemIDs).filter { !$0.isEmpty }
        let removed = Set(removedItemIDs).filter { !$0.isEmpty }
        guard invalidateAll || !changed.isEmpty || !removed.isEmpty else { return nil }

        let event: ItemDetailInvalidationEvent
        let callbacks: [Handler]
        lock.lock()
        let revisionValue = revision.advance()
        var itemRevisions: [String: UInt64] = [:]
        for itemID in changed.union(removed) {
            let next = (perItemRevisions[itemID] ?? 0) &+ 1
            perItemRevisions[itemID] = next
            itemRevisions[itemID] = next
        }
        event = ItemDetailInvalidationEvent(
            revision: revisionValue,
            changedItemIDs: changed,
            removedItemIDs: removed,
            invalidateAll: invalidateAll,
            itemRevisions: itemRevisions
        )
        callbacks = Array(handlers.values)
        lock.unlock()

        for callback in callbacks {
            callback(event)
        }
        return event
    }

    /// A full-library invalidation still advances the shared revision, but
    /// does not manufacture per-item revisions for unknown IDs.
    @discardableResult
    public func invalidateAll() -> ItemDetailInvalidationEvent {
        publish(invalidateAll: true)!
    }

    fileprivate func cancel(id: UUID) {
        _ = lock.withLock { handlers.removeValue(forKey: id) }
    }
}

/// Short alias used by code that treats the hub as a mutation center.
public typealias ItemDetailInvalidationCenter = ItemDetailInvalidationHub
public typealias ItemDetailMutationHub = ItemDetailInvalidationHub
