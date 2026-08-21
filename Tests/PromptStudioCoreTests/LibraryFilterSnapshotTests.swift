import Foundation
@testable import PromptStudioCore

#if canImport(Testing)
import Testing
#endif

#if canImport(Testing)
@Test("library filter snapshot remains equivalent through incremental updates")
func libraryFilterSnapshotRemainsEquivalent() async throws {
    try await LibraryFilterSnapshotTests.run()
}
#endif

/// Executable assertions for `LibraryFilterSnapshot`.
///
/// The repository's Core test target intentionally avoids XCTest on the
/// current Command Line Tools image. The suite is therefore exposed as one
/// async entry point so the existing Core unit-test runner or a future XCTest
/// target can invoke it without changing the production API.
public enum LibraryFilterSnapshotTests {
    public static func run() async throws {
        try await testFullBuildMatchesPromptFiltering()
        try await testIncrementalUpdatesMatchPromptFiltering()
        try await testStableDefaultAndRecentTieOrdering()
        try await testCancellation()
    }

    private static func testFullBuildMatchesPromptFiltering() async throws {
        let items = fixtures()
        let snapshot = LibraryFilterSnapshot(items: items)
        let filters = [
            PromptFilter(),
            PromptFilter(query: "FOREST"),
            PromptFilter(collection: .trash),
            PromptFilter(collection: .recent),
            PromptFilter(collection: .favorites),
            PromptFilter(collection: .folder("folder-a")),
            PromptFilter(collection: .tag("travel")),
            PromptFilter(collection: .imagePrompts),
            PromptFilter(collection: .videoPrompts),
            PromptFilter(modelId: "model-b"),
            PromptFilter(type: .text),
            PromptFilter(textFormat: .markdown),
            PromptFilter(assetKindFilter: .image),
            PromptFilter(requiredTag: "travel"),
            PromptFilter(favoriteOnly: true),
            PromptFilter(hasPromptOnly: true),
            PromptFilter(hasReferenceOnly: true),
            PromptFilter(collection: .trash, favoriteOnly: true, hasPromptOnly: true)
        ]

        for filter in filters {
            let expected = PromptFiltering.apply(items, filter: filter).map(\.id)
            let actual = try await snapshot.filter(filter).ids
            try expect(actual == expected, "full snapshot result should match PromptFiltering for \(filter)")
        }
    }

    private static func testIncrementalUpdatesMatchPromptFiltering() async throws {
        let initial = fixtures()
        let snapshot = LibraryFilterSnapshot(items: initial)
        let replacement = makeItem(
            id: "image-a",
            title: "Updated forest card",
            type: .image,
            modelID: "model-c",
            folderID: "folder-c",
            tags: ["updated"],
            prompt: "a forest after rain",
            sortOrder: -4,
            createdAt: Date(timeIntervalSince1970: 90)
        )
        snapshot.upsert(replacement)
        _ = snapshot.remove(id: "video-a")
        let expectedItems = initial.filter { $0.id != "video-a" }.map { $0.id == replacement.id ? replacement : $0 }

        let filters = [
            PromptFilter(),
            PromptFilter(query: "updated"),
            PromptFilter(collection: .folder("folder-c")),
            PromptFilter(modelId: "model-c"),
            PromptFilter(requiredTag: "updated")
        ]
        for filter in filters {
            let expected = PromptFiltering.apply(expectedItems, filter: filter).map(\.id)
            let actual = try await snapshot.filter(filter).ids
            try expect(actual == expected, "incremental result should match PromptFiltering for \(filter)")
        }
        try expect(snapshot.count == expectedItems.count, "remove and upsert should preserve the indexed count")
    }

    private static func testCancellation() async throws {
        let snapshot = LibraryFilterSnapshot(items: (0..<20_000).map { index in
            makeItem(
                id: "cancel-\(index)",
                title: "Prompt \(index)",
                type: .image,
                modelID: "model-cancel",
                folderID: "folder-cancel",
                tags: ["cancel"],
                prompt: "body \(index)",
                sortOrder: index
            )
        })
        let task = Task {
            try await snapshot.filter(PromptFilter(query: "not-present"))
        }
        task.cancel()
        do {
            _ = try await task.value
            throw SnapshotTestError.failure("cancelled filter should throw CancellationError")
        } catch is CancellationError {
            // Expected.
        }
    }

    private static func testStableDefaultAndRecentTieOrdering() async throws {
        let createdAt = Date(timeIntervalSince1970: 100)
        let first = makeItem(
            id: "tie-first",
            title: "First",
            type: .image,
            modelID: "tie-model",
            folderID: "tie-folder",
            tags: [],
            prompt: "first",
            sortOrder: 1,
            createdAt: createdAt,
            lastUsedAt: Date(timeIntervalSince1970: 200)
        )
        let second = makeItem(
            id: "tie-second",
            title: "Second",
            type: .image,
            modelID: "tie-model",
            folderID: "tie-folder",
            tags: [],
            prompt: "second",
            sortOrder: 1,
            createdAt: createdAt,
            lastUsedAt: Date(timeIntervalSince1970: 200)
        )
        let snapshot = LibraryFilterSnapshot(items: [first, second])
        let initialDefaultIDs = try await snapshot.filter(PromptFilter()).ids
        try expect(
            initialDefaultIDs == [first.id, second.id],
            "default sorting should preserve insertion order for equal keys"
        )
        let initialRecentIDs = try await snapshot.filter(PromptFilter(collection: .recent)).ids
        try expect(
            initialRecentIDs == [first.id, second.id],
            "recent sorting should preserve insertion order for equal keys"
        )

        var updatedFirst = first
        updatedFirst.title = "First updated"
        snapshot.upsert(updatedFirst)
        let updatedDefaultIDs = try await snapshot.filter(PromptFilter()).ids
        try expect(
            updatedDefaultIDs == [first.id, second.id],
            "upserting an existing item should preserve its tie-break sequence"
        )
    }

    private static func fixtures() -> [PromptItem] {
        let image = makeItem(
            id: "image-a",
            title: "Forest image",
            type: .image,
            modelID: "model-a",
            folderID: "folder-a",
            tags: ["travel", "forest"],
            prompt: "green forest",
            sortOrder: 4,
            createdAt: Date(timeIntervalSince1970: 10),
            lastUsedAt: Date(timeIntervalSince1970: 200),
            favorite: true,
            referenceAssets: [ReferenceAsset(type: "image", path: "/tmp/ref.png", label: "forest reference")]
        )
        let video = makeItem(
            id: "video-a",
            title: "City video",
            type: .video,
            modelID: "model-b",
            folderID: "folder-b",
            tags: ["city"],
            prompt: "city timelapse",
            sortOrder: 2,
            createdAt: Date(timeIntervalSince1970: 20),
            lastUsedAt: Date(timeIntervalSince1970: 100)
        )
        let markdown = makeItem(
            id: "markdown-a",
            title: "Notes",
            type: .text,
            assetKind: .markdown,
            modelID: "model-b",
            folderID: "folder-a",
            tags: ["travel"],
            prompt: "",
            sortOrder: 3,
            createdAt: Date(timeIntervalSince1970: 30),
            format: "MD"
        )
        var deleted = makeItem(
            id: "deleted-a",
            title: "Deleted forest",
            type: .image,
            modelID: "model-a",
            folderID: "folder-a",
            tags: ["forest"],
            prompt: "deleted",
            sortOrder: 1,
            createdAt: Date(timeIntervalSince1970: 40),
            lastUsedAt: Date(timeIntervalSince1970: 300),
            favorite: true
        )
        deleted.deletedAt = Date(timeIntervalSince1970: 400)
        return [image, video, markdown, deleted]
    }

    private static func makeItem(
        id: String,
        title: String,
        type: PromptType,
        assetKind: AssetKind? = nil,
        modelID: String,
        folderID: String,
        tags: [String],
        prompt: String,
        sortOrder: Int,
        createdAt: Date = Date(timeIntervalSince1970: 1),
        lastUsedAt: Date = Date(timeIntervalSince1970: 0),
        favorite: Bool = false,
        referenceAssets: [ReferenceAsset] = [],
        format: String = "PNG"
    ) -> PromptItem {
        var item = PromptItem(
            id: id,
            title: title,
            type: type,
            assetKind: assetKind,
            modelId: modelID,
            modelName: modelID,
            folderId: folderID,
            folderName: folderID,
            category: type.rawValue,
            assetPath: "/tmp/\(id).asset",
            aspectRatio: "16:9",
            width: 16,
            height: 9,
            format: format,
            fileSize: 1,
            favorite: favorite,
            createdAt: createdAt,
            updatedAt: createdAt,
            lastUsedAt: lastUsedAt,
            sortOrder: sortOrder,
            tags: tags,
            referenceAssets: referenceAssets
        )
        item.versions = [
            PromptVersion(promptItemId: id, version: "V1", prompt: prompt, createdAt: createdAt)
        ]
        return item
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SnapshotTestError.failure(message) }
    }

}

private enum SnapshotTestError: Error, LocalizedError {
    case failure(String)

    var errorDescription: String? {
        switch self {
        case .failure(let message): message
        }
    }
}
