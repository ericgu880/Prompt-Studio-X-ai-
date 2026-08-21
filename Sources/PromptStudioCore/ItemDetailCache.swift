import Foundation

/// A bounded, revision-aware cache for point-loaded prompt details.
///
/// The cache uses a small lock-protected dictionary and an MRU-to-LRU key list.
/// Keeping the implementation synchronous makes cache access cheap for both
/// MainActor owners and background loaders while the lock provides the required
/// cross-thread safety.
public final class ItemDetailCache: @unchecked Sendable {
    public static let defaultMaxEntryCount = 32
    public static let defaultMaxCostBytes = 64 * 1024 * 1024

    public struct Metrics: Equatable, Sendable {
        public let hits: Int
        public let misses: Int
        public let evictions: Int
        public let residentCount: Int
        public let residentCost: Int

        public init(
            hits: Int,
            misses: Int,
            evictions: Int,
            residentCount: Int,
            residentCost: Int
        ) {
            self.hits = hits
            self.misses = misses
            self.evictions = evictions
            self.residentCount = residentCount
            self.residentCost = residentCost
        }
    }

    /// A short-lived read ticket for an owner that may complete a detail load
    /// later. Any invalidation advances the cache epoch, making older tickets
    /// unusable. The ticket carries the ID as well so it cannot be replayed for
    /// another item.
    public struct AccessToken: Equatable, Sendable {
        fileprivate let id: String
        fileprivate let epoch: UInt64
    }

    public typealias Token = AccessToken
    public typealias CacheToken = AccessToken

    private struct Key: Hashable {
        let id: String
        let revision: UInt64
    }

    private struct Entry {
        let item: PromptItem
        let cost: Int
    }

    public let maxEntryCount: Int
    public let maxCostBytes: Int

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    /// Most recently used key is at the end of this array.
    private var lruOrder: [Key] = []
    /// Highest revision accepted for resident IDs and a bounded number of
    /// recently evicted/oversize IDs. Tombstones preserve revision ordering
    /// without retaining an unbounded ID dictionary.
    private var newestRevisionByID: [String: UInt64] = [:]
    private var revisionMetadataOrder: [String] = []
    private var invalidationEpoch: UInt64 = 0
    private var hitCount = 0
    private var missCount = 0
    private var evictionCount = 0
    private var totalCost = 0

    public init(
        maxEntryCount: Int = ItemDetailCache.defaultMaxEntryCount,
        maxCostBytes: Int = ItemDetailCache.defaultMaxCostBytes
    ) {
        self.maxEntryCount = max(0, maxEntryCount)
        self.maxCostBytes = max(0, maxCostBytes)
    }

    public func token(for id: String) -> AccessToken {
        withLock {
            AccessToken(id: id, epoch: invalidationEpoch)
        }
    }

    public func token(id: String) -> AccessToken {
        token(for: id)
    }

    public func loadToken(for id: String) -> AccessToken {
        token(for: id)
    }

    public func loadToken(id: String) -> AccessToken {
        token(for: id)
    }

    public func generationToken(for id: String) -> AccessToken {
        token(for: id)
    }

    public func generationToken(id: String) -> AccessToken {
        token(for: id)
    }

    public func currentToken(for id: String) -> AccessToken {
        token(for: id)
    }

    public func currentToken(id: String) -> AccessToken {
        token(for: id)
    }

    /// Returns a detail only when both its ID and externally supplied revision
    /// match. A successful read promotes the entry to MRU.
    public func get(id: String, revision: UInt64) -> PromptItem? {
        withLock {
            let key = Key(id: id, revision: revision)
            guard let entry = entries[key], newestRevisionByID[id] == revision else {
                missCount = saturatingAdd(missCount, 1)
                return nil
            }
            hitCount = saturatingAdd(hitCount, 1)
            touch(key)
            return entry.item
        }
    }

    public func get(_ id: String, revision: UInt64) -> PromptItem? {
        get(id: id, revision: revision)
    }

    /// Inserts an item and returns the retained cost in bytes. An item whose
    /// estimate exceeds `maxCostBytes` is deliberately not retained and
    /// returns zero. A stale revision is likewise ignored.
    @discardableResult
    public func insert(_ item: PromptItem, revision: UInt64) -> Int {
        insert(item, revision: revision, token: token(for: item.id))
    }

    /// Compare-and-insert variant for asynchronous owners. A token captured
    /// before `invalidate`, `remove`, or `removeAll` cannot publish a late
    /// completion, even if its owner ignored task cancellation.
    @discardableResult
    public func insert(_ item: PromptItem, revision: UInt64, token: AccessToken) -> Int {
        let cost = Self.retainedCost(of: item)
        return withLock {
            guard token.id == item.id, token.epoch == invalidationEpoch else {
                return 0
            }

            if let newest = newestRevisionByID[item.id], revision < newest {
                return 0
            }

            // Remove all older revisions before replacing the resident record.
            // Preserve the metadata while doing so; it is rewritten below.
            removeEntries(forID: item.id, clearRevisionMetadata: false)
            recordRevision(item.id, revision: revision)

            let key = Key(id: item.id, revision: revision)
            guard maxEntryCount > 0, maxCostBytes > 0, cost <= maxCostBytes else {
                // If a resident entry has the same key, an oversize replacement
                // must not leave the old value looking current. A newer
                // oversize revision also invalidates all older revisions above.
                removeEntry(key)
                trimRevisionMetadata(protectedID: item.id)
                return 0
            }

            removeEntry(key)
            entries[key] = Entry(item: item, cost: cost)
            lruOrder.append(key)
            totalCost = saturatingAdd(totalCost, cost)
            trimToBounds()
            return entries[key]?.cost ?? 0
        }
    }

    @discardableResult
    public func insert(item: PromptItem, revision: UInt64) -> Int {
        insert(item, revision: revision)
    }

    @discardableResult
    public func insert(item: PromptItem, revision: UInt64, token: AccessToken) -> Int {
        insert(item, revision: revision, token: token)
    }

    @discardableResult
    public func compareAndInsert(_ item: PromptItem, revision: UInt64, token: AccessToken) -> Int {
        insert(item, revision: revision, token: token)
    }

    @discardableResult
    public func insert(_ item: PromptItem, revision: UInt64, ifCurrent token: AccessToken) -> Int {
        insert(item, revision: revision, token: token)
    }

    /// Removes all revisions for the supplied IDs. Invalidation and permanent
    /// removal intentionally share cache semantics; ownership of deletion
    /// state belongs to the controller/repository.
    public func invalidate<S: Sequence>(ids: S) where S.Element == String {
        let requested = Set(ids)
        guard !requested.isEmpty else { return }
        withLock {
            advanceInvalidationEpoch()
            for id in requested {
                removeEntries(forID: id)
                newestRevisionByID.removeValue(forKey: id)
            }
        }
    }

    public func invalidate(id: String) {
        invalidate(ids: [id])
    }

    public func remove<S: Sequence>(ids: S) where S.Element == String {
        invalidate(ids: ids)
    }

    public func remove(id: String) {
        remove(ids: [id])
    }

    public func removeAll() {
        withLock {
            advanceInvalidationEpoch()
            entries.removeAll(keepingCapacity: true)
            lruOrder.removeAll(keepingCapacity: true)
            newestRevisionByID.removeAll(keepingCapacity: true)
            revisionMetadataOrder.removeAll(keepingCapacity: true)
            totalCost = 0
        }
    }

    public func invalidateAll() {
        removeAll()
    }

    public var metrics: Metrics {
        withLock {
            Metrics(
                hits: hitCount,
                misses: missCount,
                evictions: evictionCount,
                residentCount: entries.count,
                residentCost: totalCost
            )
        }
    }

    public var hits: Int { metrics.hits }
    public var misses: Int { metrics.misses }
    public var evictions: Int { metrics.evictions }
    public var residentCount: Int { metrics.residentCount }
    public var residentCost: Int { metrics.residentCost }

    /// Diagnostic count for tests and telemetry. It is intentionally bounded
    /// by `maxEntryCount` and must not grow with evicted/oversize IDs.
    public var revisionMetadataCount: Int {
        withLock { newestRevisionByID.count }
    }

    public var diagnosticMetadataCount: Int {
        revisionMetadataCount
    }

    public var metadataCount: Int {
        revisionMetadataCount
    }

    /// Conservative retained-memory estimate. String payloads are charged at
    /// two bytes per UTF-8 byte plus object overhead, and every nested array,
    /// reference, version, parameter, and captured-source field is included.
    public static func retainedCost(of item: PromptItem) -> Int {
        var cost = 512
        cost = addString(cost, item.id)
        cost = addString(cost, item.title)
        cost = addString(cost, item.modelId)
        cost = addString(cost, item.modelName)
        cost = addString(cost, item.folderId)
        cost = addString(cost, item.folderName)
        cost = addString(cost, item.category)
        cost = addString(cost, item.assetPath)
        cost = addString(cost, item.thumbnailPath)
        cost = addString(cost, item.aspectRatio)
        cost = addString(cost, item.format)
        cost = addString(cost, item.description)
        if let captureID = item.captureID {
            cost = addString(cost, captureID)
        }

        cost = satAdd(cost, satMultiply(item.tags.count, 16))
        for tag in item.tags {
            cost = addString(cost, tag)
        }

        cost = satAdd(cost, satMultiply(item.referenceAssets.count, 64))
        for reference in item.referenceAssets {
            cost = addString(cost, reference.id)
            cost = addString(cost, reference.type)
            cost = addString(cost, reference.path)
            cost = addString(cost, reference.label)
        }

        cost = satAdd(cost, satMultiply(item.versions.count, 96))
        for version in item.versions {
            cost = addString(cost, version.id)
            cost = addString(cost, version.promptItemId)
            cost = addString(cost, version.version)
            cost = addString(cost, version.prompt)
            cost = addString(cost, version.negativePrompt)
            cost = addString(cost, version.note)
            cost = satAdd(cost, 32)
            cost = satAdd(cost, satMultiply(version.parameters.count, 32))
            for (key, value) in version.parameters {
                cost = addString(cost, key)
                cost = addString(cost, value)
            }
        }

        if let capturedSource = item.capturedSource {
            cost = satAdd(cost, 192)
            cost = addString(cost, capturedSource.pageTitle)
            cost = addString(cost, capturedSource.pageURL)
            cost = addString(cost, capturedSource.siteName)
            if let resourceURL = capturedSource.resourceURL {
                cost = addString(cost, resourceURL)
            }
            if capturedSource.imageDOMSourceKind != nil {
                cost = satAdd(cost, 32)
            }
            if capturedSource.imageAcquisitionMethod != nil {
                cost = satAdd(cost, 32)
            }
            if capturedSource.isScreenshotCapture != nil {
                cost = satAdd(cost, 8)
            }
        }
        return max(1, cost)
    }

    public static func estimateCost(of item: PromptItem) -> Int {
        retainedCost(of: item)
    }

    private func trimToBounds() {
        while entries.count > maxEntryCount || totalCost > maxCostBytes {
            guard let key = lruOrder.first else { break }
            removeEntry(key)
            evictionCount = saturatingAdd(evictionCount, 1)
        }
        trimRevisionMetadata()
    }

    private func touch(_ key: Key) {
        if let index = lruOrder.firstIndex(of: key) {
            lruOrder.remove(at: index)
        }
        lruOrder.append(key)
    }

    @discardableResult
    private func removeEntry(_ key: Key) -> Entry? {
        let removed = entries.removeValue(forKey: key)
        if removed != nil, let index = lruOrder.firstIndex(of: key) {
            lruOrder.remove(at: index)
        }
        if let removed {
            totalCost = totalCost >= removed.cost ? totalCost - removed.cost : 0
        }
        return removed
    }

    private func removeEntries(forID id: String, clearRevisionMetadata: Bool = true) {
        let keys = lruOrder.filter { $0.id == id }
        for key in keys {
            removeEntry(key)
        }
        if clearRevisionMetadata {
            removeRevisionMetadata(id)
        }
    }

    private func recordRevision(_ id: String, revision: UInt64) {
        newestRevisionByID[id] = revision
        if let index = revisionMetadataOrder.firstIndex(of: id) {
            revisionMetadataOrder.remove(at: index)
        }
        revisionMetadataOrder.append(id)
    }

    private func removeRevisionMetadata(_ id: String) {
        newestRevisionByID.removeValue(forKey: id)
        if let index = revisionMetadataOrder.firstIndex(of: id) {
            revisionMetadataOrder.remove(at: index)
        }
    }

    private func trimRevisionMetadata(protectedID: String? = nil) {
        let limit = maxEntryCount
        guard limit > 0 else {
            newestRevisionByID.removeAll(keepingCapacity: true)
            revisionMetadataOrder.removeAll(keepingCapacity: true)
            return
        }

        while newestRevisionByID.count > limit {
            guard let candidateIndex = revisionMetadataOrder.firstIndex(where: { id in
                id != protectedID && !entries.keys.contains(where: { $0.id == id })
            }) else {
                if let protectedID, newestRevisionByID.count > limit {
                    removeRevisionMetadata(protectedID)
                }
                break
            }
            let candidate = revisionMetadataOrder.remove(at: candidateIndex)
            newestRevisionByID.removeValue(forKey: candidate)
        }
    }

    private func advanceInvalidationEpoch() {
        if invalidationEpoch < UInt64.max {
            invalidationEpoch += 1
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static func addString(_ cost: Int, _ value: String) -> Int {
        satAdd(cost, stringCost(value))
    }

    private static func stringCost(_ value: String) -> Int {
        satAdd(satMultiply(value.utf8.count, 2), 32)
    }

    private static func satAdd(_ lhs: Int, _ rhs: Int) -> Int {
        guard rhs > 0 else { return lhs }
        return lhs > Int.max - rhs ? Int.max : lhs + rhs
    }

    private static func satMultiply(_ lhs: Int, _ rhs: Int) -> Int {
        guard lhs > 0, rhs > 0 else { return 0 }
        return lhs > Int.max / rhs ? Int.max : lhs * rhs
    }

    private func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        Self.satAdd(lhs, rhs)
    }
}
