import Foundation
import Combine

/// The UI-facing pagination contract for the Summary surface.
///
/// `LibraryBrowserState` owns the SQLite request lifecycle. This façade keeps
/// the UI contract intentionally smaller and freezes the 2A.4 page size at
/// 300 rows so a caller cannot accidentally switch the waterfall to an
/// offset-sized or full-library request.
@MainActor
public final class LibrarySummaryPaginator: ObservableObject {
    public static let pageSize = 300

    public enum RequestKind: Equatable, Sendable {
        case initial
        case replacement
        case append
    }

    public enum ErrorPhase: Equatable, Sendable {
        case initial
        case replacement
        case append
    }

    public struct ErrorState: Equatable, Sendable {
        public let phase: ErrorPhase
        public let message: String
        public let requestKind: RequestKind

        public init(phase: ErrorPhase, message: String, requestKind: RequestKind) {
            self.phase = phase
            self.message = message
            self.requestKind = requestKind
        }
    }

    @Published public private(set) var summaries: [LibraryItemSummary]
    @Published public private(set) var folders: [LibraryFolder] = []
    @Published public private(set) var totalCount = 0
    @Published public private(set) var hasMore = false
    @Published public private(set) var initialLoading = false
    @Published public private(set) var appendLoading = false
    @Published public private(set) var error: ErrorState?
    @Published public private(set) var generation: UInt64 = 0

    public let browser: LibraryBrowserState

    private var operationTask: Task<Void, Never>?
    private var operationKind: RequestKind?
    private var lastFailedQuery: LibraryQuery?
    private var lastFailedFilter: PromptFilter?
    private var lastFailedFilterGeneration: UInt64?
    private var lastFailedKind: RequestKind?
    private var committedQuery: LibraryQuery?
    private struct FailedReplacementIdentity: Equatable {
        let generation: UInt64
        let filter: PromptFilter
    }
    private var pendingFailedReplacement: FailedReplacementIdentity?

    public init(browser: LibraryBrowserState, folders: [LibraryFolder] = []) {
        self.browser = browser
        summaries = browser.summaries
        self.folders = folders
        totalCount = browser.totalCount
        hasMore = browser.hasMore
    }

    public convenience init(repository: PromptRepository, folders: [LibraryFolder] = []) throws {
        let browser = try LibraryBrowserState(repository: repository, pageSize: Self.pageSize)
        self.init(browser: browser, folders: folders)
    }

    public var items: [LibraryItemSummary] { summaries }
    public var isLoading: Bool { initialLoading || appendLoading }
    public var nextCursor: LibraryQueryCursor? { browser.nextCursor }
    public var currentQuery: LibraryQuery { committedQuery ?? browser.currentQuery }
    public var hasCommittedQuery: Bool { committedQuery != nil }

#if DEBUG
    var retryFilterForTesting: PromptFilter? {
        guard lastFailedFilterGeneration == generation else { return nil }
        return lastFailedFilter
    }
#endif

    /// Replaces the visible query. Replacement is atomic at the UI boundary:
    /// the old rows are hidden while the first new page is pending, then the
    /// new page commits in one publication. A failed replacement leaves the
    /// display empty alongside its retryable error state.
    public func replace(query rawQuery: LibraryQuery) async {
        await replace(query: rawQuery, originatingFilter: nil)
    }

    private func replace(query rawQuery: LibraryQuery, originatingFilter: PromptFilter?) async {
        var query = rawQuery
        query.pageSize = Self.pageSize
        query.cursor = nil

        let kind: RequestKind = committedQuery == nil ? .initial : .replacement
        let operationGeneration = begin(kind: kind, query: query)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.browser.replace(query: query)
            guard self.generation == operationGeneration else { return }
            self.finish(
                kind: kind,
                query: query,
                originatingFilter: originatingFilter,
                generation: operationGeneration
            )
        }
        operationTask = task
        await task.value
    }

    public func replace(filter: PromptFilter) async {
        do {
            let query = try LibraryBrowserState.query(
                from: filter,
                pageSize: Self.pageSize,
                dataRevision: browser.dataRevision
            )
            await replace(query: query, originatingFilter: filter)
        } catch {
            await publishFailedReplacementAfterCancellation(
                error: error,
                phase: committedQuery == nil ? .initial : .replacement,
                kind: committedQuery == nil ? .initial : .replacement,
                originatingFilter: filter
            )
        }
    }

    /// Coalesces callers while one continuation is in flight. The underlying
    /// BrowserState applies a cursor/generation guard and deduplicates IDs.
    public func loadNextPage() async {
        guard !initialLoading, hasMore else {
            if let operationTask { await operationTask.value }
            return
        }
        guard operationTask == nil else {
            await operationTask?.value
            return
        }

        let operationGeneration = begin(kind: .append, query: committedQuery)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.browser.loadNextPage()
            guard self.generation == operationGeneration else { return }
            self.finish(
                kind: .append,
                query: self.committedQuery,
                originatingFilter: nil,
                generation: operationGeneration
            )
        }
        operationTask = task
        await task.value
    }

    public func appendNextPage() async { await loadNextPage() }

    public func retry() async {
        guard let lastFailedKind else {
            await loadNextPage()
            return
        }
        switch lastFailedKind {
        case .append:
            await loadNextPage()
        case .initial, .replacement:
            if let lastFailedFilter, lastFailedFilterGeneration == generation {
                await replace(filter: lastFailedFilter)
            } else {
                await replace(query: lastFailedQuery ?? committedQuery ?? browser.currentQuery)
            }
        }
    }

    /// The two-viewport rule is a prefetch trigger only. Loaded Summary pages
    /// remain resident; no active-window eviction is performed in 2A.4.
    public func prefetchIfNeeded(visibleRect: CGRect, contentHeight: CGFloat) async {
        guard hasMore, !initialLoading, !appendLoading else { return }
        let distanceToEnd = max(0, contentHeight - visibleRect.maxY)
        guard distanceToEnd <= visibleRect.height * 2 else { return }
        await loadNextPage()
    }

    public static func shouldPrefetch(visibleRect: CGRect, contentHeight: CGFloat) -> Bool {
        guard !visibleRect.isNull, !visibleRect.isEmpty else { return false }
        return max(0, contentHeight - visibleRect.maxY) <= visibleRect.height * 2
    }

    public func setFolders(_ folders: [LibraryFolder]) {
        self.folders = folders
    }

    /// Rebinds the resident Summary page to the repository revision after a
    /// committed item mutation. Cursor state is invalidated before the new
    /// first page starts, so an append can never continue an old revision.
    public func refreshAfterMutation() async {
        guard let committedQuery else {
            browser.synchronizeDataRevision()
            return
        }
        browser.synchronizeDataRevision()
        var query = committedQuery
        query.cursor = nil
        query.dataRevision = browser.dataRevision
        await replace(query: query)
    }

    /// Applies an ID-targeted Summary update without replacing the page or
    /// resetting selection/scroll. The returned kind tells the collection
    /// coordinator whether to reload content only or recompute geometry.
    @discardableResult
    public func applyTargetedUpdate(_ summary: LibraryItemSummary) -> SummaryTargetedUpdateKind? {
        guard let index = summaries.firstIndex(where: { $0.id == summary.id }) else { return nil }
        let old = summaries[index]
        summaries[index] = summary
        return SummaryTargetedUpdateKind(
            id: summary.id,
            contentChanged: old != summary,
            geometryChanged: old.geometryKey != summary.geometryKey,
            folderChanged: old.folderKey != summary.folderKey
        )
    }

    @discardableResult
    public func removeSummary(id: String) -> Bool {
        guard summaries.contains(where: { $0.id == id }) else { return false }
        summaries.removeAll { $0.id == id }
        totalCount = max(0, totalCount - 1)
        return true
    }

    public func cancel() {
        generation &+= 1
        pendingFailedReplacement = nil
        operationTask?.cancel()
        operationTask = nil
        operationKind = nil
        browser.cancel()
        initialLoading = false
        appendLoading = false
    }

    /// Awaited teardown barrier for AppState context replacement. The logical
    /// paginator task and the BrowserState's physical provider task are both
    /// settled before the caller drops the paginator reference.
    public func cancelAndWait() async {
        generation &+= 1
        pendingFailedReplacement = nil
        let operationTask = operationTask
        operationTask?.cancel()
        self.operationTask = nil
        operationKind = nil
        await browser.cancelAndWait()
        if let operationTask {
            await operationTask.value
        }
        initialLoading = false
        appendLoading = false
    }

    private func begin(kind: RequestKind, query: LibraryQuery?) -> UInt64 {
        generation &+= 1
        pendingFailedReplacement = nil
        operationTask?.cancel()
        operationKind = kind
        initialLoading = kind != .append
        appendLoading = kind == .append
        error = nil
        lastFailedKind = nil
        lastFailedQuery = nil
        lastFailedFilter = nil
        lastFailedFilterGeneration = nil
        if kind != .append {
            summaries = []
        }
        let token = generation
        // Keep the query for an exact retry even if BrowserState preserves its
        // old display while a replacement is waiting.
        if let query { lastFailedQuery = query }
        return token
    }

    private func finish(
        kind: RequestKind,
        query: LibraryQuery?,
        originatingFilter: PromptFilter?,
        generation operationGeneration: UInt64
    ) {
        guard generation == operationGeneration else { return }
        if browser.error == nil {
            syncFromBrowser()
        } else if kind != .append {
            // BrowserState intentionally keeps its last committed display for
            // detail/navigation continuity, but Summary replacement has an
            // atomic empty/loading/error boundary. Never copy those old rows
            // back into the replacement surface after failure.
            summaries = []
            totalCount = 0
            hasMore = false
        } else {
            syncFromBrowser()
        }
        operationTask = nil
        operationKind = nil
        initialLoading = false
        appendLoading = false
        if browser.error == nil {
            error = nil
            lastFailedKind = nil
            lastFailedQuery = nil
            lastFailedFilter = nil
            lastFailedFilterGeneration = nil
            if kind != .append, browser.pendingQuery == nil {
                committedQuery = query
            }
        } else {
            let phase: ErrorPhase = kind == .append ? .append : (kind == .initial ? .initial : .replacement)
            let browserError = browser.error?.localizedDescription ?? "Library Summary request failed"
            error = ErrorState(phase: phase, message: browserError, requestKind: kind)
            lastFailedKind = kind
            lastFailedQuery = query
            lastFailedFilter = originatingFilter
            lastFailedFilterGeneration = originatingFilter == nil ? nil : operationGeneration
            if kind != .append {
                // Keep the failed replacement query for an explicit retry;
                // only the rows are cleared at this boundary.
            }

            if kind == .append, isStaleRevisionError(browser.error) {
                let replacementQuery = committedQuery ?? browser.currentQuery
                error = ErrorState(
                    phase: .replacement,
                    message: browserError,
                    requestKind: .replacement
                )
                lastFailedKind = .replacement
                lastFailedQuery = replacementQuery
            }
        }
    }

    private func isStaleRevisionError(_ error: Error?) -> Bool {
        guard let error else { return false }
        if case LibraryBrowserStateError.staleDataRevision = error { return true }
        if case LibraryQueryError.staleDataRevision = error { return true }
        return false
    }

    private func publish(
        error: Error,
        phase: ErrorPhase,
        kind: RequestKind,
        originatingFilter: PromptFilter? = nil
    ) {
        generation &+= 1
        pendingFailedReplacement = nil
        operationTask?.cancel()
        operationTask = nil
        operationKind = nil
        initialLoading = false
        appendLoading = false
        let requestKind: RequestKind = kind
        if kind != .append {
            summaries = []
            totalCount = 0
            hasMore = false
        }
        self.error = ErrorState(phase: phase, message: error.localizedDescription, requestKind: requestKind)
        lastFailedKind = requestKind
        lastFailedQuery = committedQuery
        lastFailedFilter = originatingFilter
        lastFailedFilterGeneration = originatingFilter == nil ? nil : generation
    }

    private func publishFailedReplacementAfterCancellation(
        error: Error,
        phase: ErrorPhase,
        kind: RequestKind,
        originatingFilter: PromptFilter
    ) async {
        generation &+= 1
        let identity = FailedReplacementIdentity(generation: generation, filter: originatingFilter)
        pendingFailedReplacement = identity

        let previousTask = operationTask
        previousTask?.cancel()
        operationTask = nil
        operationKind = kind
        initialLoading = kind != .append
        appendLoading = kind == .append
        self.error = nil
        lastFailedKind = nil
        lastFailedQuery = nil
        lastFailedFilter = nil
        lastFailedFilterGeneration = nil
        if kind != .append {
            summaries = []
            totalCount = 0
            hasMore = false
        }

        await browser.cancelAndWait()
        if let previousTask {
            await previousTask.value
        }

        guard generation == identity.generation,
              pendingFailedReplacement == identity else { return }
        pendingFailedReplacement = nil
        publish(
            error: error,
            phase: phase,
            kind: kind,
            originatingFilter: originatingFilter
        )
    }

    private func syncFromBrowser() {
        summaries = browser.summaries
        totalCount = browser.totalCount
        hasMore = browser.hasMore
    }
}

public struct SummaryTargetedUpdateKind: Equatable, Sendable {
    public let id: String
    public let contentChanged: Bool
    public let geometryChanged: Bool
    public let folderChanged: Bool

    public init(id: String, contentChanged: Bool, geometryChanged: Bool, folderChanged: Bool) {
        self.id = id
        self.contentChanged = contentChanged
        self.geometryChanged = geometryChanged
        self.folderChanged = folderChanged
    }
}

public extension LibraryItemSummary {
    var geometryKey: SummaryGeometryKey {
        SummaryGeometryKey(
            assetKind: assetKind,
            width: width,
            height: height,
            aspectRatio: aspectRatio,
            format: format
        )
    }

    var folderKey: SummaryFolderKey {
        SummaryFolderKey(folderID: folderId, folderName: folderName)
    }
}

public struct SummaryGeometryKey: Equatable, Sendable {
    public let assetKind: AssetKind
    public let width: Int
    public let height: Int
    public let aspectRatio: String
    public let format: String

    public init(assetKind: AssetKind, width: Int, height: Int, aspectRatio: String, format: String) {
        self.assetKind = assetKind
        self.width = width
        self.height = height
        self.aspectRatio = aspectRatio
        self.format = format
    }
}

public struct SummaryFolderKey: Equatable, Sendable {
    public let folderID: String
    public let folderName: String

    public init(folderID: String, folderName: String) {
        self.folderID = folderID
        self.folderName = folderName
    }
}
