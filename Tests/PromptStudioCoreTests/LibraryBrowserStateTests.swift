import Foundation
@testable import PromptStudioCore

#if canImport(Testing)
import Testing

@Test("library browser shadow converts only supported filters")
@MainActor
func libraryBrowserShadowConvertsOnlySupportedFilters() throws {
    let query = try LibraryBrowserState.query(
        from: PromptFilter(modelId: "model-a", collection: .folder("folder-a"), favoriteOnly: true),
        pageSize: 25
    )
    #expect(query.collection == LibraryQueryCollection.folder("folder-a"))
    #expect(query.modelId == "model-a")
    #expect(query.favoriteOnly)

    do {
        _ = try LibraryBrowserState.query(from: PromptFilter(query: "needle"))
        Issue.record("free-text search must fail closed")
    } catch LibraryBrowserStateError.unsupportedFilters(let fields) {
        #expect(fields.contains(.freeText))
    }
}

@Test("library browser state appends pages without duplicate IDs")
@MainActor
func libraryBrowserStateAppendsPagesWithoutDuplicateIDs() async throws {
    actor Executor: LibraryQueryRowExecutor {
        private var page = 0

        func query(sql: String, values: [SQLiteValue]) async throws -> [[String : String?]] {
            []
        }

        func queryPageAndCount(
            pageSQL: String,
            pageValues: [SQLiteValue],
            countSQL: String,
            countValues: [SQLiteValue]
        ) async throws -> LibraryQueryReadBatch {
            let rows = page == 0
                ? [browserSummaryRow(id: "a", sortOrder: 0), browserSummaryRow(id: "b", sortOrder: 1), browserSummaryRow(id: "c", sortOrder: 2)]
                : [browserSummaryRow(id: "b", sortOrder: 1), browserSummaryRow(id: "c", sortOrder: 2)]
            page += 1
            return LibraryQueryReadBatch(pageRows: rows, countRows: [["totalCount": "3"]])
        }
    }

    let service = LibraryQueryService(
        executor: Executor(),
        capabilities: .itemSequence
    )
    let state = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 2))
    await state.replace(query: LibraryQuery(pageSize: 2))
    #expect(state.summaries.map(\.id) == ["a", "b"])
    #expect(state.hasMore)
    await state.loadNextPage()
    #expect(state.summaries.map(\.id) == ["a", "b", "c"])
    #expect(state.totalCount == 3)
}

@Test("library browser state ignores a cancelled stale replacement")
@MainActor
func libraryBrowserStateIgnoresCancelledStaleReplacement() async throws {
    actor SlowExecutor: LibraryQueryRowExecutor {
        private var calls = 0

        func query(sql: String, values: [SQLiteValue]) async throws -> [[String : String?]] { [] }

        func queryPageAndCount(
            pageSQL: String,
            pageValues: [SQLiteValue],
            countSQL: String,
            countValues: [SQLiteValue]
        ) async throws -> LibraryQueryReadBatch {
            calls += 1
            try await Task.sleep(for: .milliseconds(calls == 1 ? 250 : 1))
            let id = calls == 1 ? "old" : "new"
            return LibraryQueryReadBatch(
                pageRows: [browserSummaryRow(id: id, sortOrder: 0)],
                countRows: [["totalCount": "1"]]
            )
        }
    }

    let service = LibraryQueryService(executor: SlowExecutor(), capabilities: .itemSequence)
    let state = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 1))
    let first = Task { @MainActor in await state.replace(query: LibraryQuery(.folder("old"), pageSize: 1)) }
    try await Task.sleep(for: .milliseconds(20))
    let second = Task { @MainActor in await state.replace(query: LibraryQuery(.folder("new"), pageSize: 1)) }
    await first.value
    await second.value
    #expect(state.currentQuery.collection == .folder("new"))
    #expect(state.summaries.map(\.id) == ["new"])
    #expect(state.error == nil)
}

@Test("library browser shadow reports IDs-only parity and unsupported fields")
@MainActor
func libraryBrowserShadowReportsIDsOnlyParityAndUnsupportedFields() async throws {
    actor Executor: LibraryQueryRowExecutor {
        private var page = 0

        func query(sql: String, values: [SQLiteValue]) async throws -> [[String : String?]] { [] }

        func queryPageAndCount(
            pageSQL: String,
            pageValues: [SQLiteValue],
            countSQL: String,
            countValues: [SQLiteValue]
        ) async throws -> LibraryQueryReadBatch {
            defer { page += 1 }
            let rows = page == 0
                ? [browserSummaryRow(id: "a", sortOrder: 0), browserSummaryRow(id: "b", sortOrder: 1), browserSummaryRow(id: "c", sortOrder: 2)]
                : [browserSummaryRow(id: "c", sortOrder: 2)]
            return LibraryQueryReadBatch(pageRows: rows, countRows: [["totalCount": "3"]])
        }
    }

    var items: [PromptItem] = []
    for (index, id) in ["a", "b", "c"].enumerated() {
        let item = PromptItem(
            id: id,
            title: id,
            type: .image,
            assetKind: .image,
            modelId: "model",
            modelName: "Model",
            folderId: "folder",
            folderName: "Folder",
            category: "image",
            assetPath: "",
            aspectRatio: "16:9",
            width: 1,
            height: 1,
            format: "PNG",
            fileSize: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(index)),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(index)),
            lastUsedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(index)),
            sortOrder: index,
            tags: [],
            referenceAssets: [],
            versions: []
        )
        items.append(item)
    }

    let service = LibraryQueryService(executor: Executor(), capabilities: .itemSequence)
    let state = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 2))
    let report = await state.validateShadow(
        filter: PromptFilter(),
        snapshot: LibraryFilterSnapshot(items: items),
        pageSize: 2
    )
    #expect(report.matches)
    #expect(report.expectedIDs == ["a", "b", "c"])
    #expect(report.actualIDs == report.expectedIDs)

    let unsupported = await state.validateShadow(
        filter: PromptFilter(query: "needle"),
        snapshot: LibraryFilterSnapshot(items: items),
        pageSize: 2
    )
    #expect(!unsupported.matches)
    if case .unsupportedFilters(let fields) = unsupported.mismatch {
        #expect(fields == [.freeText])
    } else {
        Issue.record("unsupported shadow filter should be reported explicitly")
    }
}

private func browserSummaryRow(id: String, sortOrder: Int) -> [String: String?] {
    let dateValue = Date(timeIntervalSince1970: 1_700_000_000 - Double(sortOrder))
    let date = ISO8601DateFormatter().string(from: dateValue)
    let itemCreatedAtSortKey = Int64((dateValue.timeIntervalSince1970 * 1_000_000).rounded())
    let itemLastUsedAtSortKey: Int64 = 0
    let itemSequence = Int64(max(1, sortOrder + 1))
    return [
        "id": id, "title": id, "type": PromptType.image.rawValue, "assetKind": AssetKind.image.rawValue,
        "modelId": "model", "modelName": "Model", "folderId": "folder", "folderName": "Folder", "category": "image",
        "assetPath": "", "thumbnailPath": "", "aspectRatio": "16:9", "width": "1", "height": "1", "format": "PNG", "fileSize": "1",
        "favorite": "0", "pinnedAt": nil, "deletedAt": nil, "createdAt": date, "updatedAt": date, "lastUsedAt": date,
        "sortOrder": "\(sortOrder)",
        "itemCreatedAtSortKey": "\(itemCreatedAtSortKey)",
        "itemLastUsedAtSortKey": "\(itemLastUsedAtSortKey)",
        "itemSequence": "\(itemSequence)",
        "hasPrompt": "1", "hasReferences": "0"
    ]
}
#endif
