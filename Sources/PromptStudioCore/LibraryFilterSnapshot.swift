import Foundation

/// The result of one indexed library filter operation.
public struct LibraryFilterResult: Equatable, Sendable {
    /// IDs in the same order as the corresponding `PromptFiltering.apply` result.
    public let ids: [String]

    /// Number of indexed entries inspected after candidate indexes were applied.
    public let scannedCount: Int

    /// Monotonic wall-clock duration for this operation, in nanoseconds.
    public let durationNanoseconds: UInt64

    public init(ids: [String], scannedCount: Int, durationNanoseconds: UInt64) {
        self.ids = ids
        self.scannedCount = scannedCount
        self.durationNanoseconds = durationNanoseconds
    }

    /// Duration in seconds for callers that report timings in `TimeInterval`.
    public var duration: TimeInterval {
        TimeInterval(durationNanoseconds) / 1_000_000_000
    }

    public var orderedIDs: [String] { ids }

    public var scanned: Int { scannedCount }

    public var elapsedNanoseconds: UInt64 { durationNanoseconds }

    public var durationMilliseconds: Double { duration * 1_000 }
}

/// A thread-safe, incrementally maintained index for prompt-library filtering.
///
/// Search text and all filter fields are derived when an item is inserted or
/// updated. A filter copies the immutable index state before doing any work, so
/// concurrent upserts do not block a search and cannot change its result midway.
public final class LibraryFilterSnapshot: @unchecked Sendable {
    public typealias Result = LibraryFilterResult

    private struct IndexedItem: Sendable {
        let item: PromptItem
        let searchableText: String
        let sequence: UInt64
        let tags: Set<String>
        let textFormats: Set<String>
        let assetKinds: Set<String>
        let isDeleted: Bool
        let hasPrompt: Bool
        let hasReference: Bool
        let hasRecentUse: Bool
    }

    private struct State: Sendable {
        var entries: [String: IndexedItem] = [:]
        var insertionOrder: [String] = []
        var nextSequence: UInt64 = 0

        var allIDs: Set<String> = []
        var activeIDs: Set<String> = []
        var deletedIDs: Set<String> = []
        var favoriteIDs: Set<String> = []
        var recentIDs: Set<String> = []
        var promptIDs: Set<String> = []
        var referenceIDs: Set<String> = []

        var folderIDs: [String: Set<String>] = [:]
        var tagIDs: [String: Set<String>] = [:]
        var modelIDs: [String: Set<String>] = [:]
        var typeIDs: [String: Set<String>] = [:]
        var textFormatIDs: [String: Set<String>] = [:]
        var assetKindIDs: [String: Set<String>] = [:]
    }

    private let lock = NSLock()
    private var state: State

    public init(items: [PromptItem] = []) {
        state = State()
        upsert(contentsOf: items)
    }

    public convenience init(_ items: [PromptItem]) {
        self.init(items: items)
    }

    /// Number of currently indexed items.
    public var count: Int {
        withState { $0.entries.count }
    }

    /// Inserts an item or updates the existing item with the same ID.
    ///
    /// Updating an existing ID preserves its insertion sequence, which keeps
    /// default and recent sorting deterministic when sort keys are tied.
    public func upsert(_ item: PromptItem) {
        withMutableState { state in
            if let previous = state.entries[item.id] {
                removeIndexes(for: previous, from: &state)
                let replacement = makeIndexedItem(item, sequence: previous.sequence)
                state.entries[item.id] = replacement
                addIndexes(for: replacement, to: &state)
            } else {
                let replacement = makeIndexedItem(item, sequence: state.nextSequence)
                state.nextSequence &+= 1
                state.insertionOrder.append(item.id)
                state.entries[item.id] = replacement
                addIndexes(for: replacement, to: &state)
            }
        }
    }

    /// Inserts or updates multiple items while holding the index lock once.
    public func upsert(contentsOf items: [PromptItem]) {
        guard !items.isEmpty else { return }
        withMutableState { state in
            for item in items {
                if let previous = state.entries[item.id] {
                    removeIndexes(for: previous, from: &state)
                    let replacement = makeIndexedItem(item, sequence: previous.sequence)
                    state.entries[item.id] = replacement
                    addIndexes(for: replacement, to: &state)
                } else {
                    let replacement = makeIndexedItem(item, sequence: state.nextSequence)
                    state.nextSequence &+= 1
                    state.insertionOrder.append(item.id)
                    state.entries[item.id] = replacement
                    addIndexes(for: replacement, to: &state)
                }
            }
        }
    }

    /// Removes an item by ID and returns the removed value, if present.
    @discardableResult
    public func remove(id: String) -> PromptItem? {
        withMutableState { state in
            guard let previous = state.entries.removeValue(forKey: id) else { return nil }
            removeIndexes(for: previous, from: &state)
            state.insertionOrder.removeAll { $0 == id }
            return previous.item
        }
    }

    @discardableResult
    public func remove(_ id: String) -> PromptItem? {
        remove(id: id)
    }

    /// Removes multiple IDs and returns the values that were present.
    @discardableResult
    public func remove<S: Sequence>(ids: S) -> [PromptItem] where S.Element == String {
        let requestedIDs = Array(ids)
        guard !requestedIDs.isEmpty else { return [] }
        return withMutableState { state in
            var removed: [PromptItem] = []
            removed.reserveCapacity(requestedIDs.count)
            var removedIDs = Set<String>()
            for id in requestedIDs {
                guard let previous = state.entries.removeValue(forKey: id) else { continue }
                removeIndexes(for: previous, from: &state)
                removed.append(previous.item)
                removedIDs.insert(id)
            }
            if !removedIDs.isEmpty {
                state.insertionOrder.removeAll { removedIDs.contains($0) }
            }
            return removed
        }
    }

    /// Returns the current item for an ID, if it is indexed.
    public func item(for id: String) -> PromptItem? {
        withState { $0.entries[id]?.item }
    }

    /// Returns items in the order of the supplied IDs, omitting IDs no longer indexed.
    public func items(for ids: [String]) -> [PromptItem] {
        withState { state in
            ids.compactMap { state.entries[$0]?.item }
        }
    }

    /// Returns all indexed items in insertion order.
    public func allItems() -> [PromptItem] {
        withState { state in
            state.insertionOrder.compactMap { state.entries[$0]?.item }
        }
    }

    /// Filters the current immutable state and returns ordered IDs plus metadata.
    ///
    /// Cancellation is checked before scanning and at least every 128 candidate
    /// entries. Yielding at the same cadence lets a caller's cancellation reach
    /// this task even when the candidate set is large and CPU-bound.
    public func filter(_ filter: PromptFilter) async throws -> LibraryFilterResult {
        let state = withState { $0 }
        return try await Self.filter(state: state, filter: filter)
    }

    /// Synchronous counterpart useful to non-async callers. It has the same
    /// ordering and index semantics but cannot observe task cancellation.
    public func filterSynchronously(_ filter: PromptFilter) -> LibraryFilterResult {
        let state = withState { $0 }
        return Self.filterSynchronously(state: state, filter: filter)
    }

    private func withState<Result>(_ body: (State) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(state)
    }

    private func withMutableState<Result>(_ body: (inout State) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    private static func filter(state: State, filter: PromptFilter) async throws -> LibraryFilterResult {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        try Task.checkCancellation()

        let candidates = candidateIDs(for: filter, state: state)
        let orderedCandidates = state.insertionOrder.filter { candidates.contains($0) }
        let query = filter.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var matchingIDs: [String] = []
        matchingIDs.reserveCapacity(orderedCandidates.count)
        var scannedCount = 0

        for (index, id) in orderedCandidates.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
                await Task.yield()
                try Task.checkCancellation()
            }
            guard let entry = state.entries[id] else { continue }
            scannedCount += 1
            if matches(entry, filter: filter, query: query) {
                matchingIDs.append(id)
            }
        }

        try Task.checkCancellation()
        matchingIDs.sort { lhs, rhs in
            guard let left = state.entries[lhs], let right = state.entries[rhs] else {
                return lhs < rhs
            }
            return orderedBefore(left, right, collection: filter.collection)
        }
        try Task.checkCancellation()

        return LibraryFilterResult(
            ids: matchingIDs,
            scannedCount: scannedCount,
            durationNanoseconds: DispatchTime.now().uptimeNanoseconds - startedAt
        )
    }

    private static func filterSynchronously(state: State, filter: PromptFilter) -> LibraryFilterResult {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let candidates = candidateIDs(for: filter, state: state)
        let orderedCandidates = state.insertionOrder.filter { candidates.contains($0) }
        let query = filter.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var matchingIDs: [String] = []
        matchingIDs.reserveCapacity(orderedCandidates.count)
        var scannedCount = 0

        for id in orderedCandidates {
            guard let entry = state.entries[id] else { continue }
            scannedCount += 1
            if matches(entry, filter: filter, query: query) {
                matchingIDs.append(id)
            }
        }

        matchingIDs.sort { lhs, rhs in
            guard let left = state.entries[lhs], let right = state.entries[rhs] else {
                return lhs < rhs
            }
            return orderedBefore(left, right, collection: filter.collection)
        }

        return LibraryFilterResult(
            ids: matchingIDs,
            scannedCount: scannedCount,
            durationNanoseconds: DispatchTime.now().uptimeNanoseconds - startedAt
        )
    }

    private static func candidateIDs(for filter: PromptFilter, state: State) -> Set<String> {
        var candidates = state.allIDs

        switch filter.collection {
        case .all:
            candidates.formIntersection(state.activeIDs)
        case .imagePrompts:
            candidates.formIntersection(state.typeIDs[PromptType.image.rawValue] ?? [])
            candidates.formIntersection(state.activeIDs)
        case .videoPrompts:
            candidates.formIntersection(state.typeIDs[PromptType.video.rawValue] ?? [])
            candidates.formIntersection(state.activeIDs)
        case .favorites:
            candidates.formIntersection(state.favoriteIDs)
            candidates.formIntersection(state.activeIDs)
        case .recent:
            candidates.formIntersection(state.recentIDs)
            candidates.formIntersection(state.activeIDs)
        case .trash:
            candidates.formIntersection(state.deletedIDs)
        case .folder(let folderID):
            candidates.formIntersection(state.folderIDs[folderID] ?? [])
            candidates.formIntersection(state.activeIDs)
        case .tag(let tag):
            candidates.formIntersection(state.tagIDs[tag] ?? [])
            candidates.formIntersection(state.activeIDs)
        }

        if let modelID = filter.modelId {
            candidates.formIntersection(state.modelIDs[modelID] ?? [])
        }
        if let type = filter.type {
            candidates.formIntersection(state.typeIDs[type.rawValue] ?? [])
        }
        if let textFormat = filter.textFormat {
            candidates.formIntersection(state.textFormatIDs[textFormat.rawValue] ?? [])
        }
        if let assetKind = filter.assetKindFilter {
            candidates.formIntersection(state.assetKindIDs[assetKind.rawValue] ?? [])
        }
        if let tag = filter.requiredTag {
            candidates.formIntersection(state.tagIDs[tag] ?? [])
        }
        if filter.favoriteOnly {
            candidates.formIntersection(state.favoriteIDs)
        }
        if filter.hasPromptOnly {
            candidates.formIntersection(state.promptIDs)
        }
        if filter.hasReferenceOnly {
            candidates.formIntersection(state.referenceIDs)
        }

        return candidates
    }

    private static func matches(_ entry: IndexedItem, filter: PromptFilter, query: String) -> Bool {
        switch filter.collection {
        case .trash where !entry.isDeleted:
            return false
        case .trash:
            break
        case .favorites where !entry.item.favorite || entry.isDeleted:
            return false
        case .recent where entry.isDeleted || !entry.hasRecentUse:
            return false
        case .folder(let folderID) where entry.item.folderId != folderID || entry.isDeleted:
            return false
        case .tag(let tag) where !entry.tags.contains(tag) || entry.isDeleted:
            return false
        case .imagePrompts where entry.item.type != .image || entry.isDeleted:
            return false
        case .videoPrompts where entry.item.type != .video || entry.isDeleted:
            return false
        case .all where entry.isDeleted:
            return false
        default:
            break
        }

        if let modelID = filter.modelId, entry.item.modelId != modelID { return false }
        if let type = filter.type, entry.item.type != type { return false }
        if let textFormat = filter.textFormat, !entry.textFormats.contains(textFormat.rawValue) { return false }
        if let assetKind = filter.assetKindFilter, !entry.assetKinds.contains(assetKind.rawValue) { return false }
        if let tag = filter.requiredTag, !entry.tags.contains(tag) { return false }
        if filter.favoriteOnly, !entry.item.favorite { return false }
        if filter.hasPromptOnly, !entry.hasPrompt { return false }
        if filter.hasReferenceOnly, !entry.hasReference { return false }

        return query.isEmpty || entry.searchableText.contains(query)
    }

    private static func orderedBefore(
        _ lhs: IndexedItem,
        _ rhs: IndexedItem,
        collection: LibraryCollection
    ) -> Bool {
        switch collection {
        case .recent:
            if let lhsKey = lhs.item.itemLastUsedAtSortKey,
               let rhsKey = rhs.item.itemLastUsedAtSortKey {
                if lhsKey != rhsKey { return lhsKey > rhsKey }
            } else if lhs.item.lastUsedAt != rhs.item.lastUsedAt {
                return lhs.item.lastUsedAt > rhs.item.lastUsedAt
            }
            if let lhsKey = lhs.item.itemCreatedAtSortKey,
               let rhsKey = rhs.item.itemCreatedAtSortKey {
                if lhsKey != rhsKey { return lhsKey > rhsKey }
            } else if lhs.item.createdAt != rhs.item.createdAt {
                return lhs.item.createdAt > rhs.item.createdAt
            }
        default:
            if lhs.item.sortOrder != rhs.item.sortOrder {
                return lhs.item.sortOrder < rhs.item.sortOrder
            }
            if let lhsKey = lhs.item.itemCreatedAtSortKey,
               let rhsKey = rhs.item.itemCreatedAtSortKey {
                if lhsKey != rhsKey { return lhsKey > rhsKey }
            } else if lhs.item.createdAt != rhs.item.createdAt {
                return lhs.item.createdAt > rhs.item.createdAt
            }
        }
        if let lhsItemSequence = lhs.item.itemSequence,
           let rhsItemSequence = rhs.item.itemSequence,
           lhsItemSequence != rhsItemSequence {
            return lhsItemSequence < rhsItemSequence
        }
        return lhs.sequence < rhs.sequence
    }

    private func makeIndexedItem(_ item: PromptItem, sequence: UInt64) -> IndexedItem {
        let searchableText = [
            item.title,
            item.modelName,
            item.folderName,
            item.category,
            item.description,
            item.format,
            item.tags.joined(separator: " "),
            item.referenceAssets.map(\.label).joined(separator: " "),
            item.versions.map { [$0.prompt, $0.negativePrompt, $0.note, $0.version].joined(separator: " ") }.joined(separator: " ")
        ].joined(separator: " ").lowercased()

        let hasPrompt = item.currentVersion?.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let tags = Set(item.tags)
        let textFormats = Set(TextFormatFilter.allCases.compactMap { $0.matches(item) ? $0.rawValue : nil })
        let assetKinds = Set(AssetKindFilter.allCases.compactMap { $0.matches(item) ? $0.rawValue : nil })

        return IndexedItem(
            item: item,
            searchableText: searchableText,
            sequence: sequence,
            tags: tags,
            textFormats: textFormats,
            assetKinds: assetKinds,
            isDeleted: item.isDeleted,
            hasPrompt: hasPrompt,
            hasReference: !item.referenceAssets.isEmpty,
            hasRecentUse: item.lastUsedAt.timeIntervalSince1970 > 0
        )
    }

    private func addIndexes(for entry: IndexedItem, to state: inout State) {
        let id = entry.item.id
        state.allIDs.insert(id)
        if entry.isDeleted {
            state.deletedIDs.insert(id)
        } else {
            state.activeIDs.insert(id)
        }
        if entry.item.favorite { state.favoriteIDs.insert(id) }
        if entry.hasRecentUse { state.recentIDs.insert(id) }
        if entry.hasPrompt { state.promptIDs.insert(id) }
        if entry.hasReference { state.referenceIDs.insert(id) }

        insert(id, into: &state.folderIDs, key: entry.item.folderId)
        insert(id, into: &state.modelIDs, key: entry.item.modelId)
        insert(id, into: &state.typeIDs, key: entry.item.type.rawValue)
        for tag in entry.tags { insert(id, into: &state.tagIDs, key: tag) }
        for textFormat in entry.textFormats { insert(id, into: &state.textFormatIDs, key: textFormat) }
        for assetKind in entry.assetKinds { insert(id, into: &state.assetKindIDs, key: assetKind) }
    }

    private func removeIndexes(for entry: IndexedItem, from state: inout State) {
        let id = entry.item.id
        state.allIDs.remove(id)
        state.activeIDs.remove(id)
        state.deletedIDs.remove(id)
        state.favoriteIDs.remove(id)
        state.recentIDs.remove(id)
        state.promptIDs.remove(id)
        state.referenceIDs.remove(id)

        remove(id, from: &state.folderIDs, key: entry.item.folderId)
        remove(id, from: &state.modelIDs, key: entry.item.modelId)
        remove(id, from: &state.typeIDs, key: entry.item.type.rawValue)
        for tag in entry.tags { remove(id, from: &state.tagIDs, key: tag) }
        for textFormat in entry.textFormats { remove(id, from: &state.textFormatIDs, key: textFormat) }
        for assetKind in entry.assetKinds { remove(id, from: &state.assetKindIDs, key: assetKind) }
    }

    private func insert(_ id: String, into index: inout [String: Set<String>], key: String) {
        index[key, default: []].insert(id)
    }

    private func remove(_ id: String, from index: inout [String: Set<String>], key: String) {
        guard var ids = index[key] else { return }
        ids.remove(id)
        if ids.isEmpty {
            index.removeValue(forKey: key)
        } else {
            index[key] = ids
        }
    }
}
