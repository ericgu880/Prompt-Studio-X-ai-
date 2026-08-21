import Foundation
import Combine

/// Fields that the Summary SQL path intentionally does not evaluate.
///
/// The browser shadow must fail closed for these fields.  In particular, a
/// non-empty free-text query cannot be silently dropped while switching from
/// the legacy browser to the summary path.  A future SearchDocument/FTS path
/// can consume these values without changing this conversion contract.
public enum LibraryBrowserUnsupportedFilterField: String, CaseIterable, Codable, Equatable, Sendable {
    case freeText
    case textFormat
    case assetKind
    case requiredTag
    case hasPrompt
    case hasReferences

    public var displayName: String {
        switch self {
        case .freeText: return "free text"
        case .textFormat: return "text format"
        case .assetKind: return "asset kind"
        case .requiredTag: return "required tag"
        case .hasPrompt: return "has prompt"
        case .hasReferences: return "has references"
        }
    }
}

public typealias LibraryBrowserUnsupportedFilterCapability = LibraryBrowserUnsupportedFilterField

/// Errors surfaced by the opt-in browser shadow state.
public enum LibraryBrowserStateError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedFilters([LibraryBrowserUnsupportedFilterField])
    case invalidPageSize(Int)
    case cursorQueryFingerprintMismatch
    case staleDataRevision(requested: UInt64, current: UInt64)
    case requestSuperseded

    public var unsupportedFields: [LibraryBrowserUnsupportedFilterField] {
        guard case .unsupportedFilters(let fields) = self else { return [] }
        return fields
    }

    public var errorDescription: String? {
        switch self {
        case .unsupportedFilters(let fields):
            let names = fields.map(\.displayName).joined(separator: ", ")
            return "Library Summary cannot evaluate unsupported filter fields: \(names)"
        case .invalidPageSize(let size):
            return "library browser page size must be positive (got \(size))"
        case .cursorQueryFingerprintMismatch:
            return "library browser cursor does not belong to the current query"
        case .staleDataRevision(let requested, let current):
            return "library browser data changed during paging (revision \(requested), current \(current))"
        case .requestSuperseded:
            return "library browser request was superseded by a newer query"
        }
    }
}

/// A small public constraint record for the eventual SearchDocument/FTS path.
///
/// Summary rows deliberately contain no prompt, version, or reference text.
/// Until a SearchDocument index exists, conversion rejects free text and the
/// text-derived filters above instead of scanning or materializing the full
/// library on the browser path.
public struct LibrarySearchDocumentConstraint: Equatable, Sendable {
    public let supportsFreeText: Bool
    public let supportsTextFormat: Bool
    public let supportsAssetKind: Bool
    public let supportsRequiredTag: Bool
    public let supportsHasPrompt: Bool
    public let supportsHasReferences: Bool

    public init(
        supportsFreeText: Bool = false,
        supportsTextFormat: Bool = false,
        supportsAssetKind: Bool = false,
        supportsRequiredTag: Bool = false,
        supportsHasPrompt: Bool = false,
        supportsHasReferences: Bool = false
    ) {
        self.supportsFreeText = supportsFreeText
        self.supportsTextFormat = supportsTextFormat
        self.supportsAssetKind = supportsAssetKind
        self.supportsRequiredTag = supportsRequiredTag
        self.supportsHasPrompt = supportsHasPrompt
        self.supportsHasReferences = supportsHasReferences
    }

    public init(
        supportsFreeText: Bool = false,
        supportsTextFormat: Bool = false,
        supportsAssetKind: Bool = false,
        supportsPromptPresence: Bool,
        supportsReferencePresence: Bool
    ) {
        self.init(
            supportsFreeText: supportsFreeText,
            supportsTextFormat: supportsTextFormat,
            supportsAssetKind: supportsAssetKind,
            supportsHasPrompt: supportsPromptPresence,
            supportsHasReferences: supportsReferencePresence
        )
    }

    public static let summaryPath = LibrarySearchDocumentConstraint()

    /// Older names are retained as read-only aliases while the public
    /// capability surface converges on the unsupported-filter field names.
    public var supportsPromptPresence: Bool { supportsHasPrompt }
    public var supportsReferencePresence: Bool { supportsHasReferences }
}

/// A mismatch observed while validating the summary shadow against the legacy
/// PromptFiltering/LibraryFilterSnapshot implementation.
public enum LibraryBrowserShadowValidationMismatch: Equatable, Sendable {
    case unsupportedFilters([LibraryBrowserUnsupportedFilterField])
    case ids(expected: [String], actual: [String])
    case count(expected: Int, actual: Int)
    case queryFailed(String)
    case cancelled

    public var message: String {
        switch self {
        case .unsupportedFilters(let fields):
            return LibraryBrowserStateError.unsupportedFilters(fields).localizedDescription
        case .ids(let expected, let actual):
            return "library shadow IDs/order mismatch (expected \(expected.count), got \(actual.count))"
        case .count(let expected, let actual):
            return "library shadow count mismatch (expected \(expected), got \(actual))"
        case .queryFailed(let message):
            return "library shadow query failed: \(message)"
        case .cancelled:
            return "library shadow validation was cancelled"
        }
    }
}

/// IDs-only parity report.  PromptItem values are never retained by this
/// report or by LibraryBrowserState; the optional snapshot owns its own index.
public struct LibraryBrowserShadowValidationReport: Equatable, Sendable {
    public let filter: PromptFilter
    public let query: LibraryQuery?
    public let expectedIDs: [String]
    public let actualIDs: [String]
    public let expectedCount: Int
    public let actualCount: Int
    public let mismatch: LibraryBrowserShadowValidationMismatch?

    public init(
        filter: PromptFilter,
        query: LibraryQuery?,
        expectedIDs: [String],
        actualIDs: [String],
        expectedCount: Int,
        actualCount: Int,
        mismatch: LibraryBrowserShadowValidationMismatch?
    ) {
        self.filter = filter
        self.query = query
        self.expectedIDs = expectedIDs
        self.actualIDs = actualIDs
        self.expectedCount = expectedCount
        self.actualCount = actualCount
        self.mismatch = mismatch
    }

    public var matches: Bool { mismatch == nil }
    public var isMatch: Bool { matches }
    public var passed: Bool { matches }
    public var mismatchMessage: String? { mismatch?.message }
}

/// @MainActor, opt-in state for exercising the Summary query path without
/// changing the existing AppState items/filteredItems/selectedItem data flow.
///
/// Replace requests keep the old page visible until the first page completes;
/// the resulting page is then committed as one state transition. Append
/// requests are bound to the cursor fingerprint and data revision that created
/// that cursor.  QuerySession cancellation is used in addition to local
/// generation/revision checks, so a late result cannot mutate this state.
@MainActor
public final class LibraryBrowserState: ObservableObject {
    public nonisolated static let searchDocumentConstraint = LibrarySearchDocumentConstraint.summaryPath

    @Published public private(set) var currentQuery: LibraryQuery
    /// A replacement query waiting for its first page. `currentQuery` remains
    /// the query represented by `summaries` until that page commits.
    @Published public private(set) var pendingQuery: LibraryQuery?
    @Published public private(set) var summaries: [LibraryItemSummary] = []
    @Published public private(set) var totalCount: Int = 0
    @Published public private(set) var nextCursor: LibraryQueryCursor?
    @Published public private(set) var hasMore: Bool = false

    /// `initial` and `loadingNext` are intentionally short names because the
    /// shadow is meant to be easy to inspect from a debug overlay.
    @Published public private(set) var initial: Bool = false
    @Published public private(set) var loadingNext: Bool = false
    @Published public private(set) var shadowLoading: Bool = false
    @Published public private(set) var error: Error?

    @Published public private(set) var queryRevision: UInt64 = 0
    @Published public private(set) var dataRevision: UInt64
    @Published public private(set) var generation: UInt64 = 0
    @Published public var selectionID: String?

    /// Aliases make state inspection readable at call sites without changing
    /// the canonical contract above.
    public var isInitialLoading: Bool { initial }
    public var initialLoading: Bool { initial }
    public var isLoadingNext: Bool { loadingNext }
    public var nextLoading: Bool { loadingNext }
    public var isShadowLoading: Bool { shadowLoading }
    public var items: [LibraryItemSummary] { summaries }
    public var displayQuery: LibraryQuery { currentQuery }
    public var requestedQuery: LibraryQuery { pendingQuery ?? currentQuery }
    /// `activeTask` may retain a just-cancelled exact task as a physical
    /// replacement barrier; that task is not a live logical request.
    public var hasActiveRequest: Bool { activeToken != nil }
    public var activeRequest: Bool { hasActiveRequest }
    public var selectedItemID: String? {
        get { selectionID }
        set { selectionID = newValue }
    }

    public let service: LibraryQueryService
    public let session: LibraryQuerySession

    private struct RequestToken: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case initial, append }

        let queryRevision: UInt64
        let generation: UInt64
        let dataRevision: UInt64
        let kind: Kind
        let cursor: LibraryQueryCursor?
    }

    private var activeToken: RequestToken?
    private var activeTask: Task<Void, Never>?
    private var shadowGeneration: UInt64 = 0
    private var summaryIDs: Set<String> = []
    private var lastFailedRequestKind: RequestToken.Kind?
    private var lastFailedQuery: LibraryQuery?

    public init(
        service: LibraryQueryService,
        session: LibraryQuerySession? = nil,
        initialQuery: LibraryQuery? = nil
    ) {
        self.service = service
        self.session = session ?? LibraryQuerySession(service: service)
        self.dataRevision = service.dataRevision.current
        self.currentQuery = initialQuery ?? LibraryQuery.all()
        self.pendingQuery = nil
    }

    /// Uses one independent real SQLite read connection for every page.  The
    /// service retains the connection through its row-executor closure.
    public convenience init(repository: PromptRepository, pageSize: Int = LibraryQuerySQLBuilder.defaultPageSize) throws {
        guard pageSize > 0 else { throw LibraryBrowserStateError.invalidPageSize(pageSize) }
        let connection = try SQLiteReadConnection(path: repository.databaseURL.path)
        let service = LibraryQueryService(executor: connection, repository: repository)
        self.init(service: service, initialQuery: LibraryQuery.all(pageSize: pageSize))
    }

    public convenience init(
        databaseURL: URL,
        capabilities: LibraryQueryCapabilities,
        dataRevision: LibraryDataRevision = LibraryDataRevision(),
        pageSize: Int = LibraryQuerySQLBuilder.defaultPageSize
    ) throws {
        guard pageSize > 0 else { throw LibraryBrowserStateError.invalidPageSize(pageSize) }
        let connection = try SQLiteReadConnection(url: databaseURL)
        let service = LibraryQueryService(
            executor: connection,
            dataRevision: dataRevision,
            capabilities: capabilities
        )
        self.init(service: service, initialQuery: LibraryQuery.all(pageSize: pageSize))
    }

    // MARK: PromptFilter conversion

    /// Converts only the collection/refinement subset represented by Summary
    /// SQL.  Unsupported fields are returned together, so a caller can report
    /// the exact reason rather than silently dropping a filter.
    public nonisolated static func query(
        from filter: PromptFilter,
        pageSize: Int = LibraryQuerySQLBuilder.defaultPageSize,
        dataRevision: UInt64 = 0
    ) throws -> LibraryQuery {
        guard pageSize > 0 else { throw LibraryBrowserStateError.invalidPageSize(pageSize) }

        var unsupported: [LibraryBrowserUnsupportedFilterField] = []
        if !filter.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            unsupported.append(.freeText)
        }
        if filter.textFormat != nil { unsupported.append(.textFormat) }
        if filter.assetKindFilter != nil { unsupported.append(.assetKind) }
        if filter.requiredTag != nil { unsupported.append(.requiredTag) }
        if filter.hasPromptOnly { unsupported.append(.hasPrompt) }
        if filter.hasReferenceOnly { unsupported.append(.hasReferences) }
        if !unsupported.isEmpty {
            throw LibraryBrowserStateError.unsupportedFilters(unsupported)
        }

        let collection: LibraryQueryCollection
        switch filter.collection {
        case .all:
            collection = .all
        case .imagePrompts:
            collection = .type(.image)
        case .videoPrompts:
            collection = .type(.video)
        case .favorites:
            collection = .favorite
        case .recent:
            collection = .recent
        case .trash:
            collection = .trash
        case .folder(let id):
            collection = .folder(id)
        case .tag(let name):
            collection = .tag(name)
        }

        return LibraryQuery(
            collection,
            pageSize: pageSize,
            dataRevision: dataRevision,
            type: filter.type,
            modelId: filter.modelId,
            favoriteOnly: filter.favoriteOnly
        )
    }

    public nonisolated static func query(
        for filter: PromptFilter,
        pageSize: Int = LibraryQuerySQLBuilder.defaultPageSize,
        dataRevision: UInt64 = 0
    ) throws -> LibraryQuery {
        try query(from: filter, pageSize: pageSize, dataRevision: dataRevision)
    }

    public func query(from filter: PromptFilter, pageSize: Int? = nil) throws -> LibraryQuery {
        try Self.query(
            from: filter,
            pageSize: pageSize ?? currentQuery.pageSize,
            dataRevision: dataRevision
        )
    }

    // MARK: Query lifecycle

    /// Starts an atomic first-page replacement and waits until the request has
    /// settled.  Failures are retained in `error` for debug overlays and retry.
    public func replace(query rawQuery: LibraryQuery) async {
        await replaceInternal(rawQuery)
    }

    public func setQuery(_ query: LibraryQuery) async {
        await replace(query: query)
    }

    public func query(_ query: LibraryQuery) async {
        await replace(query: query)
    }

    public func load(_ query: LibraryQuery) async {
        await replace(query: query)
    }

    public func replace(filter: PromptFilter, pageSize: Int? = nil) async {
        do {
            let query = try Self.query(
                from: filter,
                pageSize: pageSize ?? currentQuery.pageSize,
                dataRevision: service.dataRevision.current
            )
            await replaceInternal(query)
        } catch let caughtError {
            await rejectReplacement(caughtError)
        }
    }

    /// Throwing companion useful to test harnesses that prefer assertions over
    /// observing the published `error` value.
    public func replace(throwing query: LibraryQuery) async throws {
        await replaceInternal(query)
        if let error { throw error }
    }

    public func replace(throwing filter: PromptFilter, pageSize: Int? = nil) async throws {
        let query: LibraryQuery
        do {
            query = try Self.query(
                from: filter,
                pageSize: pageSize ?? currentQuery.pageSize,
                dataRevision: service.dataRevision.current
            )
        } catch {
            await rejectReplacement(error)
            throw error
        }
        try await replace(throwing: query)
    }

    /// Loads one keyset page. Calls while the same `(fingerprint, cursor)` is
    /// already in flight coalesce onto that task instead of opening another
    /// SQLite read connection.
    public func loadNextPage() async {
        guard !initial else { return }
        guard !loadingNext, hasMore, let cursor = nextCursor else {
            if loadingNext, let activeTask { await activeTask.value }
            return
        }

        let currentRevision = service.dataRevision.current
        guard currentRevision == dataRevision else {
            let cancellationTask = activeTask
            let invalidationGeneration = invalidateForRevisionChange(currentRevision)
            if let cancellationTask { await cancellationTask.value }
            guard generation == invalidationGeneration else { return }
            return
        }

        var query = currentQuery
        query.cursor = cursor
        query.dataRevision = dataRevision
        do {
            let firstPage = try LibraryQuerySQLBuilder.build(
                LibraryQuery(
                    query.collection,
                    pageSize: query.pageSize,
                    dataRevision: dataRevision,
                    type: query.type,
                    modelId: query.modelId,
                    favoriteOnly: query.favoriteOnly
                ),
                capabilities: service.capabilities
            )
            guard firstPage.queryFingerprint == cursor.queryFingerprint else {
                throw LibraryBrowserStateError.cursorQueryFingerprintMismatch
            }
        } catch {
            self.error = error
            return
        }

        let token = RequestToken(
            queryRevision: queryRevision,
            generation: generation,
            dataRevision: dataRevision,
            kind: .append,
            cursor: cursor
        )
        if activeToken == token, let activeTask {
            await activeTask.value
            return
        }

        error = nil
        loadingNext = true
        activeToken = token
        let task = makeRequestTask(query: query, token: token)
        activeTask = task
        await task.value
    }

    public func appendNextPage() async {
        await loadNextPage()
    }

    public func retry() async {
        switch lastFailedRequestKind {
        case .initial:
            await replaceInternal(lastFailedQuery ?? pendingQuery ?? currentQuery)
        case .append:
            await loadNextPage()
        case nil:
            if hasMore, nextCursor != nil {
                await loadNextPage()
            } else {
                await replaceInternal(currentQuery)
            }
        }
    }

    /// Cancels both the current SQLite request and the local stale-result
    /// token.  This synchronous form is convenient for SwiftUI `.onDisappear`.
    public func cancel() {
        generation &+= 1
        shadowGeneration &+= 1
        activeTask?.cancel()
        activeToken = nil
        initial = false
        loadingNext = false
        shadowLoading = false
        nextCursor = nil
        hasMore = false
        pendingQuery = nil
        lastFailedRequestKind = nil
        lastFailedQuery = nil
    }

    public func cancelAndWait() async {
        generation &+= 1
        shadowGeneration &+= 1
        let cancellationGeneration = generation
        let task = activeTask
        task?.cancel()
        activeToken = nil
        if let task { await task.value }
        guard generation == cancellationGeneration else { return }
        activeTask = nil
        initial = false
        loadingNext = false
        shadowLoading = false
        nextCursor = nil
        hasMore = false
        pendingQuery = nil
        lastFailedRequestKind = nil
        lastFailedQuery = nil
    }

    /// Synchronizes the published revision after a repository mutation.  Any
    /// old cursor is invalidated rather than being reused against new data.
    public func synchronizeDataRevision() {
        let current = service.dataRevision.current
        guard current != dataRevision else { return }
        invalidateForRevisionChange(current)
    }

    public func invalidateForDataRevisionChange() {
        synchronizeDataRevision()
    }

    /// Awaited variant for mutation handlers that need the old SQLite read to
    /// be interrupted before they begin another ordered operation.
    public func synchronizeDataRevisionAndWait() async {
        let current = service.dataRevision.current
        guard current != dataRevision else { return }
        let task = activeTask
        let invalidationGeneration = invalidateForRevisionChange(current)
        if let task { await task.value }
        guard generation == invalidationGeneration else { return }
        activeTask = nil
    }

    // MARK: Shadow validation

    /// Walks every Summary page and compares IDs/order/count with the legacy
    /// filter snapshot.  Only IDs and counts leave the snapshot; PromptItem
    /// payloads are never copied into browser state or the report.
    public func validateShadow(
        filter: PromptFilter,
        snapshot: LibraryFilterSnapshot,
        pageSize: Int? = nil
    ) async -> LibraryBrowserShadowValidationReport {
        shadowGeneration &+= 1
        let validationGeneration = shadowGeneration
        shadowLoading = true
        defer {
            if shadowGeneration == validationGeneration {
                shadowLoading = false
            }
        }

        let query: LibraryQuery
        do {
            query = try Self.query(
                from: filter,
                pageSize: pageSize ?? currentQuery.pageSize,
                dataRevision: service.dataRevision.current
            )
        } catch LibraryBrowserStateError.unsupportedFilters(let fields) {
            let report = LibraryBrowserShadowValidationReport(
                filter: filter,
                query: nil,
                expectedIDs: [],
                actualIDs: [],
                expectedCount: 0,
                actualCount: 0,
                mismatch: .unsupportedFilters(fields)
            )
            error = LibraryBrowserStateError.unsupportedFilters(fields)
            return report
        } catch {
            return failedReport(filter: filter, mismatch: .queryFailed(error.localizedDescription))
        }

        let expected: LibraryFilterResult
        do {
            expected = try await snapshot.filter(filter)
        } catch is CancellationError {
            return cancelledReport(filter: filter, query: query)
        } catch {
            return failedReport(filter: filter, query: query, mismatch: .queryFailed(error.localizedDescription))
        }
        let expectedIDs = expected.ids

        var actualIDs: [String] = []
        var cursor: LibraryQueryCursor?
        var reportedCount: Int?
        var pages = 0
        var seenCursors = Set<String>()
        do {
            while true {
                var pageQuery = query
                pageQuery.cursor = cursor
                guard !Task.isCancelled, shadowGeneration == validationGeneration else {
                    return cancelledReport(
                        filter: filter,
                        query: query,
                        expectedIDs: expectedIDs,
                        actualIDs: actualIDs,
                        expectedCount: expectedIDs.count,
                        actualCount: reportedCount ?? actualIDs.count
                    )
                }
                let page = try await service.query(pageQuery)
                if let reportedCount, page.totalCount != reportedCount {
                    actualIDs.append(contentsOf: page.items.map(\.id))
                    return failedReport(
                        filter: filter,
                        query: query,
                        expectedIDs: expectedIDs,
                        actualIDs: actualIDs,
                        expectedCount: expectedIDs.count,
                        actualCount: page.totalCount,
                        mismatch: .count(expected: reportedCount, actual: page.totalCount)
                    )
                }
                if reportedCount == nil { reportedCount = page.totalCount }
                actualIDs.append(contentsOf: page.items.map(\.id))
                pages += 1
                guard pages < 100_000 else {
                    return failedReport(filter: filter, query: query, expectedIDs: expectedIDs, actualIDs: actualIDs, expectedCount: expectedIDs.count, actualCount: reportedCount ?? actualIDs.count, mismatch: .queryFailed("shadow page walk exceeded safety bound"))
                }
                guard page.hasMore else { break }
                guard let next = page.nextCursor else {
                    return failedReport(filter: filter, query: query, expectedIDs: expectedIDs, actualIDs: actualIDs, expectedCount: expectedIDs.count, actualCount: reportedCount ?? actualIDs.count, mismatch: .queryFailed("page reported hasMore without a cursor"))
                }
                let key = "\(next.queryFingerprint):\(next.id):\(next.createdAtSortKey):\(next.sortOrder.map(String.init) ?? ""):\(next.lastUsedAtSortKey ?? "")"
                guard seenCursors.insert(key).inserted else {
                    return failedReport(filter: filter, query: query, expectedIDs: expectedIDs, actualIDs: actualIDs, expectedCount: expectedIDs.count, actualCount: reportedCount ?? actualIDs.count, mismatch: .queryFailed("cursor repeated during shadow walk"))
                }
                cursor = next
            }
        } catch is CancellationError {
            return cancelledReport(filter: filter, query: query, expectedIDs: expectedIDs, actualIDs: actualIDs, expectedCount: expectedIDs.count, actualCount: reportedCount ?? actualIDs.count)
        } catch {
            return failedReport(filter: filter, query: query, expectedIDs: expectedIDs, actualIDs: actualIDs, expectedCount: expectedIDs.count, actualCount: reportedCount ?? actualIDs.count, mismatch: .queryFailed(error.localizedDescription))
        }

        let actualCount = reportedCount ?? actualIDs.count
        if actualIDs != expectedIDs {
            let report = LibraryBrowserShadowValidationReport(
                filter: filter,
                query: query,
                expectedIDs: expectedIDs,
                actualIDs: actualIDs,
                expectedCount: expectedIDs.count,
                actualCount: actualCount,
                mismatch: .ids(expected: expectedIDs, actual: actualIDs)
            )
            return report
        }
        if actualCount != expectedIDs.count {
            return LibraryBrowserShadowValidationReport(
                filter: filter,
                query: query,
                expectedIDs: expectedIDs,
                actualIDs: actualIDs,
                expectedCount: expectedIDs.count,
                actualCount: actualCount,
                mismatch: .count(expected: expectedIDs.count, actual: actualCount)
            )
        }
        return LibraryBrowserShadowValidationReport(
            filter: filter,
            query: query,
            expectedIDs: expectedIDs,
            actualIDs: actualIDs,
            expectedCount: expectedIDs.count,
            actualCount: actualCount,
            mismatch: nil
        )
    }

    public func shadowValidate(
        filter: PromptFilter,
        snapshot: LibraryFilterSnapshot,
        pageSize: Int? = nil
    ) async -> LibraryBrowserShadowValidationReport {
        await validateShadow(filter: filter, snapshot: snapshot, pageSize: pageSize)
    }

    // MARK: Internal request machinery

    private func rejectReplacement(_ replacementError: Error) async {
        generation &+= 1
        queryRevision &+= 1
        let operationGeneration = generation
        let previousTask = activeTask
        previousTask?.cancel()
        activeToken = nil
        initial = false
        loadingNext = false
        nextCursor = nil
        hasMore = false
        pendingQuery = nil
        lastFailedRequestKind = nil
        lastFailedQuery = nil
        error = replacementError
        if let previousTask { await previousTask.value }
        guard generation == operationGeneration else { return }
        activeTask = nil
    }

    private func replaceInternal(_ rawQuery: LibraryQuery) async {
        guard rawQuery.pageSize > 0 else {
            await rejectReplacement(LibraryBrowserStateError.invalidPageSize(rawQuery.pageSize))
            return
        }

        let requestedRevision = service.dataRevision.current
        var query = rawQuery
        query.cursor = nil
        query.dataRevision = requestedRevision
        if let pendingQuery,
           pendingQuery == query,
           initial,
           let activeTask,
           activeToken?.kind == .initial {
            await activeTask.value
            return
        }

        generation &+= 1
        queryRevision &+= 1
        let operationGeneration = generation
        let previousTask = activeTask
        previousTask?.cancel()
        activeToken = nil

        // Invalidate pagination and publish the pending/display split before
        // the first suspension. Old summaries may stay visible, but they can
        // no longer be paged as though they belonged to the new query.
        initial = true
        loadingNext = false
        nextCursor = nil
        hasMore = false
        error = nil
        pendingQuery = query
        dataRevision = requestedRevision
        lastFailedRequestKind = nil
        lastFailedQuery = nil

        // Cancelling the exact outer request task propagates to the session's
        // unstructured child through its cancellation handler. Avoid a global
        // session cancellation here: this operation can suspend and a newer
        // replacement must never be cancelled by an older continuation.
        guard generation == operationGeneration, pendingQuery == query else { return }

        // Keep the exact cancelled task as a physical replacement barrier.
        // Actor reentrancy may enqueue another replacement while this await is
        // suspended; generation/pending guards prevent this older operation
        // from starting a new child after it has been superseded.
        if let previousTask {
            await previousTask.value
        }
        guard generation == operationGeneration, pendingQuery == query else { return }
        activeTask = nil

        let token = RequestToken(
            queryRevision: queryRevision,
            generation: operationGeneration,
            dataRevision: requestedRevision,
            kind: .initial,
            cursor: nil
        )
        activeToken = token
        let task = makeRequestTask(query: query, token: token)
        activeTask = task
        await task.value
    }

    private func makeRequestTask(query: LibraryQuery, token: RequestToken) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            var observedStaleRevision: UInt64?
            do {
                try Task.checkCancellation()
                let page = try await self.session.query(query)
                try Task.checkCancellation()
                guard self.isCurrent(token) else { return }
                let observedRevision = self.service.dataRevision.current
                guard observedRevision == token.dataRevision else {
                    throw LibraryBrowserStateError.staleDataRevision(
                        requested: token.dataRevision,
                        current: observedRevision
                    )
                }
                if token.kind == .initial {
                    self.commitInitial(page, query: query)
                } else {
                    self.commitAppend(page)
                }
                self.error = nil
                self.lastFailedRequestKind = nil
                self.lastFailedQuery = nil
            } catch is CancellationError {
                // Cancellation is expected during rapid query replacement.
            } catch {
                guard self.isCurrent(token) else { return }
                observedStaleRevision = self.staleRevision(from: error)
                if observedStaleRevision != nil {
                    self.nextCursor = nil
                    self.hasMore = false
                }
                if token.kind == .initial {
                    self.nextCursor = nil
                    self.hasMore = false
                    self.pendingQuery = query
                    self.lastFailedRequestKind = .initial
                    self.lastFailedQuery = query
                } else {
                    if observedStaleRevision != nil {
                        // A stale cursor cannot be retried. Restart the
                        // displayed query after the caller observes the
                        // revision error instead of issuing another append.
                        self.lastFailedRequestKind = .initial
                        self.lastFailedQuery = self.currentQuery
                    } else {
                        self.lastFailedRequestKind = .append
                        self.lastFailedQuery = self.currentQuery
                    }
                }
                if let observedStaleRevision {
                    self.error = LibraryBrowserStateError.staleDataRevision(
                        requested: token.dataRevision,
                        current: observedStaleRevision
                    )
                } else {
                    self.error = error
                }
            }
            guard self.isCurrent(token) else { return }
            if let observedStaleRevision {
                self.dataRevision = observedStaleRevision
            }
            self.activeTask = nil
            self.activeToken = nil
            if token.kind == .initial {
                self.initial = false
            } else {
                self.loadingNext = false
            }
        }
    }

    private func isCurrent(_ token: RequestToken) -> Bool {
        activeToken == token &&
            token.queryRevision == queryRevision &&
            token.generation == generation &&
            token.dataRevision == dataRevision
    }

    private func commitInitial(_ page: LibraryItemPage, query: LibraryQuery) {
        var seen = Set<String>()
        let pageItems = page.items.filter { seen.insert($0.id).inserted }
        currentQuery = query
        pendingQuery = nil
        summaries = pageItems
        summaryIDs = Set(pageItems.map(\.id))
        totalCount = page.totalCount
        nextCursor = page.nextCursor
        hasMore = page.hasMore && page.nextCursor != nil
    }

    private func commitAppend(_ page: LibraryItemPage) {
        var merged = summaries
        merged.reserveCapacity(summaries.count + page.items.count)
        for item in page.items where summaryIDs.insert(item.id).inserted {
            merged.append(item)
        }
        summaries = merged
        totalCount = page.totalCount
        nextCursor = page.nextCursor
        hasMore = page.hasMore && page.nextCursor != nil
    }

    @discardableResult
    private func invalidateForRevisionChange(_ current: UInt64) -> UInt64 {
        let requested = dataRevision
        generation &+= 1
        activeTask?.cancel()
        activeToken = nil
        initial = false
        nextCursor = nil
        hasMore = false
        pendingQuery = nil
        dataRevision = current
        loadingNext = false
        lastFailedRequestKind = nil
        lastFailedQuery = nil
        error = LibraryBrowserStateError.staleDataRevision(requested: requested, current: current)
        return generation
    }

    private func staleRevision(from error: Error) -> UInt64? {
        if case LibraryBrowserStateError.staleDataRevision(_, let current) = error {
            return current
        }
        if case LibraryQueryError.staleDataRevision(_, let current) = error {
            return current
        }
        return nil
    }

    private func cancelledReport(
        filter: PromptFilter,
        query: LibraryQuery? = nil,
        expectedIDs: [String] = [],
        actualIDs: [String] = [],
        expectedCount: Int = 0,
        actualCount: Int = 0
    ) -> LibraryBrowserShadowValidationReport {
        LibraryBrowserShadowValidationReport(
            filter: filter,
            query: query,
            expectedIDs: expectedIDs,
            actualIDs: actualIDs,
            expectedCount: expectedCount,
            actualCount: actualCount,
            mismatch: .cancelled
        )
    }

    private func failedReport(
        filter: PromptFilter,
        query: LibraryQuery? = nil,
        expectedIDs: [String] = [],
        actualIDs: [String] = [],
        expectedCount: Int = 0,
        actualCount: Int = 0,
        mismatch: LibraryBrowserShadowValidationMismatch
    ) -> LibraryBrowserShadowValidationReport {
        LibraryBrowserShadowValidationReport(
            filter: filter,
            query: query,
            expectedIDs: expectedIDs,
            actualIDs: actualIDs,
            expectedCount: expectedCount,
            actualCount: actualCount,
            mismatch: mismatch
        )
    }
}
