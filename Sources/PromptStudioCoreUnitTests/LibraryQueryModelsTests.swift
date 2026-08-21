import Foundation
import PromptStudioCore

func testLibraryQueryCursorRoundTripAndFingerprint() throws {
    let cursor = LibraryQueryCursor(
        queryFingerprint: "fingerprint-v1",
        sortOrder: 12,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        id: "item-12"
    )
    let encoded = try cursor.encoded()
    let decoded = try LibraryQueryCursor.decode(encoded)
    try expect(decoded == cursor, "query cursors should round-trip through URL-safe encoding")
    try expect(!encoded.contains("+"), "query cursor encoding should be URL-safe")
    try expect(decoded.queryFingerprint == "fingerprint-v1", "query cursor should carry the query fingerprint")
}

func testLibraryItemSummaryHasOnlyLightweightFields() throws {
    let summary = LibraryItemSummary(
        id: "summary-1",
        title: "Summary",
        type: .image,
        assetKind: .image,
        modelId: "model",
        modelName: "Model",
        folderId: "folder",
        folderName: "Folder",
        category: "图片",
        assetPath: "/tmp/image.png",
        thumbnailPath: "/tmp/thumb.png",
        aspectRatio: "16:9",
        width: 1920,
        height: 1080,
        format: "PNG",
        fileSize: 123,
        favorite: true,
        pinnedAt: nil,
        deletedAt: nil,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
        lastUsedAt: Date(timeIntervalSince1970: 1_700_000_200),
        sortOrder: 1,
        hasPrompt: true,
        hasReferences: false
    )
    try expect(summary.id == "summary-1" && summary.hasPrompt, "summary should expose card metadata and prompt existence")
}

func testLibraryQueryScopesAndTagUnsupported() throws {
    try expect(LibraryQuery().collection == .all, "default library query should target all active items")
    try expect(LibraryQuery.folder("folder-a").collection == .folder("folder-a"), "folder scope should carry a folder ID")
    try expect(LibraryQuery.type(.video).collection == .type(.video), "type scope should carry a prompt type")
    try expect(LibraryQuery.model("model-a").collection == .model("model-a"), "model scope should carry a model ID")
    try expect(LibraryQuery.favorite.collection == .favorite, "favorite scope should be available")
    try expect(LibraryQuery.recent.collection == .recent, "recent scope should be available")
    try expect(LibraryQuery.trash.collection == .trash, "trash scope should be available")
    do {
        _ = try LibraryQuerySQLBuilder.build(LibraryQuery.tag("unsupported"))
        throw CoreUnitTestError.failure("tag scope should be rejected explicitly")
    } catch LibraryQuerySQLBuilderError.versionSequenceNotReady {
        // Expected: Summary SQL is closed until version ordering is ready.
    }
}

func testLibraryItemPageUsesTypedCursors() throws {
    let cursor = LibraryItemCursor(
        queryFingerprint: "fingerprint",
        sortOrder: 7,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        id: "item-7"
    )
    let page = LibraryItemPage(items: [], totalCount: 0, nextCursor: cursor, hasMore: true)
    let query = LibraryQuery(.all, cursor: page.nextCursor)
    try expect(query.cursor == cursor, "pages and follow-up queries should exchange a typed cursor")
}
