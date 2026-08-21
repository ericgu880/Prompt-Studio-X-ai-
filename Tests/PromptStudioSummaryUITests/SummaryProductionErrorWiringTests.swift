import Foundation
import Testing
import PromptStudioCore
@testable import PromptStudio

@MainActor
@Test("Production Summary retry action preserves the rejected filter identity")
func productionSummaryErrorRetryUsesRejectedFilter() async {
    let executor = ProductionRetryExecutor()
    let service = LibraryQueryService(
        executor: { sql, values in try await executor.call(sql, values) },
        capabilities: .itemSequence
    )
    let browser = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 300))
    let paginator = LibrarySummaryPaginator(browser: browser)
    await paginator.replace(query: LibraryQuery(pageSize: 300))
    let callsBeforeRejectedFilter = executor.pageCallCount

    await paginator.replace(filter: PromptFilter(query: "unsupported-search"))
    #expect(paginator.error?.phase == .replacement)
    #expect(paginator.summaries.isEmpty)

    let state = AppState(
        libraryURL: URL(fileURLWithPath: "/tmp/PromptStudio-SummaryRetry-\(UUID().uuidString)")
    )
    state.installSummaryPaginatorForTesting(paginator)
    SummaryRetryAction(state: state).perform()
    await state.waitForSummaryRetryForTesting()

    #expect(paginator.error?.phase == .replacement)
    #expect(paginator.summaries.isEmpty)
    #expect(executor.pageCallCount == callsBeforeRejectedFilter)
}

private final class ProductionRetryExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var pageCalls = 0

    var pageCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pageCalls
    }

    func call(_ sql: String, _ values: [SQLiteValue]) async throws -> [[String: String?]] {
        if sql.contains("COUNT") {
            return [["totalCount": "1"]]
        }
        withLock { pageCalls += 1 }
        return [productionRetryRow()]
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private func productionRetryRow() -> [String: String?] {
    [
        "id": "supported-row",
        "title": "Supported",
        "type": "image",
        "assetKind": "image",
        "modelId": "model",
        "modelName": "Model",
        "folderId": "folder",
        "folderName": "Folder",
        "category": "image",
        "assetPath": "/tmp/supported.png",
        "thumbnailPath": "/tmp/supported.png",
        "aspectRatio": "1:1",
        "width": "100",
        "height": "100",
        "format": "PNG",
        "fileSize": "1",
        "favorite": "0",
        "createdAt": "2023-11-14T22:13:20Z",
        "updatedAt": "2023-11-14T22:13:20Z",
        "lastUsedAt": "1970-01-01T00:00:00Z",
        "sortOrder": "0",
        "hasPrompt": "1",
        "hasReferences": "0",
        "itemSequence": "1",
        "itemCreatedAtSortKey": "1700000000000000",
        "itemLastUsedAtSortKey": "0"
    ]
}

@Test("Production Summary error state retains its phase and retry identity")
func productionSummaryErrorWiringRetainsPhase() {
    let error = LibrarySummaryPaginator.ErrorState(
        phase: .append,
        message: "append failed",
        requestKind: .append
    )
    #expect(error.phase == .append)
    #expect(error.requestKind == .append)
    #expect(error.message == "append failed")
}
