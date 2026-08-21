import Foundation
import PromptStudioCore

private final class DetailStepCancellationBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldBlock = true
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func onStep() {
        lock.lock()
        let block = shouldBlock
        shouldBlock = false
        lock.unlock()
        entered.signal()
        if block {
            _ = release.wait(timeout: .now() + 5)
        }
    }
}

private func detailFixtureDate(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_700_000_000 + seconds)
}

private func detailFixtureItem(
    id: String,
    kind: AssetKind,
    versionCount: Int,
    referenceCount: Int,
    tags: [String],
    favorite: Bool,
    deletedAt: Date?,
    captureID: String?
) -> PromptItem {
    let createdAt = detailFixtureDate(Double(id.count))
    let versions = (0..<versionCount).map { index in
        PromptVersion(
            id: "\(id)-version-\(String(format: "%03d", index))",
            promptItemId: id,
            version: "V\(index + 1)",
            prompt: "prompt \(index) for \(id)",
            negativePrompt: index.isMultiple(of: 2) ? "negative \(index)" : "",
            parameters: ["seed": "\(index)", "ratio": "16:9"],
            note: "version note \(index)",
            // Deliberate ties exercise the createdAt + id ordering contract.
            createdAt: detailFixtureDate(Double(index / 2))
        )
    }
    let references = (0..<referenceCount).map { index in
        ReferenceAsset(
            id: "\(id)-reference-\(index)",
            type: index.isMultiple(of: 2) ? "image" : "document",
            path: "/references/\(id)-\(index).asset",
            label: "reference \(index)"
        )
    }
    var item = PromptItem(
        id: id,
        title: "Detail \(id)",
        type: kind.promptType,
        assetKind: kind,
        modelId: "model-\(id)",
        modelName: "Model \(id)",
        folderId: "folder-moved",
        folderName: "Moved Folder",
        category: kind.displayName,
        assetPath: "/assets/\(id).\(kind == .video ? "mp4" : kind == .document ? "docx" : "png")",
        thumbnailPath: "/thumbnails/\(id).jpg",
        aspectRatio: "3:2",
        width: 3000,
        height: 2000,
        format: kind == .video ? "MP4" : kind == .document ? "DOCX" : "PNG",
        fileSize: 9_876_543,
        favorite: favorite,
        pinnedAt: detailFixtureDate(10),
        deletedAt: deletedAt,
        createdAt: createdAt,
        updatedAt: detailFixtureDate(20),
        lastUsedAt: detailFixtureDate(30),
        sortOrder: 42,
        tags: tags,
        referenceAssets: references,
        versions: versions,
        description: "edited description for \(id)",
        captureID: captureID,
        capturedSource: captureID.map {
            CapturedSource(
                pageTitle: "Captured page",
                pageURL: "https://example.com/\($0)",
                siteName: "Example",
                capturedAt: detailFixtureDate(40),
                resourceURL: "https://example.com/asset.png",
                imageDOMSourceKind: .picture,
                imageAcquisitionMethod: .loadedBytes,
                isScreenshotCapture: false
            )
        }
    )
    item.category = "edited category"
    return item
}

private func expectDetailFields(_ actual: PromptItem, _ expected: PromptItem) throws {
    try expect(actual.id == expected.id, "detail id should match")
    try expect(actual.title == expected.title, "detail title should match")
    try expect(actual.type == expected.type, "detail prompt type should match")
    try expect(actual.assetKind == expected.assetKind, "detail asset kind should match")
    try expect(actual.modelId == expected.modelId && actual.modelName == expected.modelName, "detail model fields should match")
    try expect(actual.folderId == expected.folderId && actual.folderName == expected.folderName, "detail folder fields should match")
    try expect(actual.category == expected.category, "detail category should match")
    try expect(actual.assetPath == expected.assetPath && actual.thumbnailPath == expected.thumbnailPath, "detail paths should match")
    try expect(actual.aspectRatio == expected.aspectRatio, "detail aspect ratio should match")
    try expect(actual.width == expected.width && actual.height == expected.height, "detail dimensions should match")
    try expect(actual.format == expected.format && actual.fileSize == expected.fileSize, "detail format and size should match")
    try expect(actual.favorite == expected.favorite, "detail favorite should match")
    try expect(actual.pinnedAt == expected.pinnedAt && actual.deletedAt == expected.deletedAt, "detail pin/trash state should match")
    try expect(actual.createdAt == expected.createdAt && actual.updatedAt == expected.updatedAt, "detail edited timestamps should match")
    try expect(actual.lastUsedAt == expected.lastUsedAt && actual.sortOrder == expected.sortOrder, "detail usage/order fields should match")
    try expect(actual.tags == expected.tags, "detail tags should match")
    try expect(actual.referenceAssets == expected.referenceAssets, "detail references should match")
    try expect(actual.description == expected.description, "detail description should match")
    try expect(actual.captureID == expected.captureID && actual.capturedSource == expected.capturedSource, "detail capture fields should match")
    try expect(actual.versions == expected.versions, "detail versions should match")
}

func testPromptItemDetailMatchesLoadItemsAcrossMetadataAndCardinality() async throws {
    let libraryURL = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: libraryURL)
    var reverseTieItem = detailFixtureItem(id: "reverse-ties", kind: .image, versionCount: 3, referenceCount: 0, tags: [], favorite: false, deletedAt: nil, captureID: nil)
    let tiedDate = detailFixtureDate(700)
    reverseTieItem.versions = [
        PromptVersion(id: "z-version", promptItemId: reverseTieItem.id, version: "VZ", prompt: "z", createdAt: tiedDate),
        PromptVersion(id: "a-version", promptItemId: reverseTieItem.id, version: "VA", prompt: "a", createdAt: tiedDate),
        PromptVersion(id: "m-version", promptItemId: reverseTieItem.id, version: "VM", prompt: "m", createdAt: tiedDate)
    ]
    let expectedItems = [
        detailFixtureItem(id: "image", kind: .image, versionCount: 1, referenceCount: 0, tags: ["image", "shared"], favorite: true, deletedAt: nil, captureID: nil),
        detailFixtureItem(id: "video", kind: .video, versionCount: 10, referenceCount: 1, tags: ["video"], favorite: false, deletedAt: nil, captureID: nil),
        detailFixtureItem(id: "text", kind: .markdown, versionCount: 100, referenceCount: 20, tags: ["text", "shared"], favorite: true, deletedAt: detailFixtureDate(50), captureID: "capture-text"),
        detailFixtureItem(id: "document", kind: .document, versionCount: 500, referenceCount: 100, tags: [], favorite: false, deletedAt: nil, captureID: "capture-document"),
        detailFixtureItem(id: "empty", kind: .text, versionCount: 0, referenceCount: 0, tags: [], favorite: false, deletedAt: nil, captureID: nil),
        reverseTieItem
    ]
    try repository.saveItems(expectedItems)

    let loaded = try repository.loadItems()
    try expect(loaded.count == expectedItems.count, "fixture should persist all detail items")
    for expected in expectedItems {
        guard let shadow = loaded.first(where: { $0.id == expected.id }) else {
            throw CoreUnitTestError.failure("loadItems should contain detail fixture \(expected.id)")
        }
        let detail = try await repository.itemDetail(id: expected.id)
        guard let detail else {
            throw CoreUnitTestError.failure("itemDetail should return fixture \(expected.id)")
        }
        try expectDetailFields(detail, expected)
        try expectDetailFields(detail, shadow)
    }
    let missingDetail = try await repository.itemDetail(id: "missing-detail-item")
    try expect(missingDetail == nil, "missing detail should return nil")
}

func testPromptItemDetailSupportsCancellationToken() async throws {
    let libraryURL = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: libraryURL)
    let item = detailFixtureItem(id: "cancel", kind: .image, versionCount: 500, referenceCount: 100, tags: ["cancel"], favorite: false, deletedAt: nil, captureID: nil)
    try repository.saveItem(item)
    let token = SQLiteQueryCancellation()
    token.cancel()
    do {
        _ = try await repository.itemDetail(id: item.id, cancellationToken: token)
        throw CoreUnitTestError.failure("cancelled detail token should stop before query")
    } catch is CancellationError {
        // Expected.
    }
}

func testPromptItemDetailCancelsAfterSQLiteStep() async throws {
    let libraryURL = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: libraryURL)
    let item = detailFixtureItem(id: "cancel-after-step", kind: .image, versionCount: 500, referenceCount: 100, tags: ["cancel"], favorite: false, deletedAt: nil, captureID: nil)
    try repository.saveItem(item)
    let barrier = DetailStepCancellationBarrier()
    let readConnection = try SQLiteReadConnection(
        url: repository.databaseURL,
        queryStartHook: { barrier.onStep() }
    )
    let service = try PromptItemDetailService(
        databaseURL: repository.databaseURL,
        readConnection: readConnection
    )
    let task = Task { try await service.itemDetail(id: item.id) }
    try expect(
        barrier.entered.wait(timeout: .now() + 5) == .success,
        "detail cancellation fixture should enter sqlite3_step"
    )
    task.cancel()
    barrier.release.signal()

    do {
        _ = try await task.value
        throw CoreUnitTestError.failure("detail task cancellation after sqlite3_step should throw")
    } catch is CancellationError {
        // Expected.
    }
}

func testPromptItemDetailMatchesLegacyFallbacksAndOptionals() async throws {
    let libraryURL = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: libraryURL)
    let item = detailFixtureItem(id: "legacy-fallbacks", kind: .image, versionCount: 1, referenceCount: 1, tags: ["valid"], favorite: false, deletedAt: nil, captureID: "capture-fallback")
    try repository.saveItem(item)
    let database = try SQLiteDatabase(path: repository.databaseURL.path)
    try database.run(
        """
        UPDATE prompt_items
        SET type = ?, assetKind = ?, tagsJSON = ?, referencesJSON = ?,
            captureId = NULL, captureSourceJSON = ?, pinnedAt = ?, deletedAt = ?,
            lastUsedAt = ?, thumbnailPath = ?
        WHERE id = ?;
        """,
        values: [
            .text("future-type"),
            .text("future-asset-kind"),
            .text("malformed-tags"),
            .text("malformed-references"),
            .text("malformed-capture-source"),
            .text("malformed-pinned"),
            .text("malformed-deleted"),
            .text("malformed-last-used"),
            .text(""),
            .text(item.id)
        ]
    )
    try database.run(
        "UPDATE prompt_versions SET parametersJSON = ? WHERE promptItemId = ?;",
        values: [.text("malformed-parameters"), .text(item.id)]
    )

    guard let shadow = try repository.loadItems().first(where: { $0.id == item.id }) else {
        throw CoreUnitTestError.failure("legacy fallback fixture should load")
    }
    guard let detail = try await repository.itemDetail(id: item.id) else {
        throw CoreUnitTestError.failure("legacy fallback fixture should detail-load")
    }
    try expectDetailFields(detail, shadow)
    try expect(detail.type == .image && detail.assetKind == .unknown, "unknown enum values should preserve legacy enum fallbacks")
    try expect(detail.tags.isEmpty && detail.referenceAssets.isEmpty, "malformed tags/references should preserve empty-array fallbacks")
    try expect(detail.versions.first?.parameters.isEmpty == true, "malformed version parameters should preserve empty-dictionary fallback")
    try expect(detail.pinnedAt == nil && detail.deletedAt == nil, "invalid optional dates should preserve nil fallback")
    try expect(detail.lastUsedAt == Date(timeIntervalSince1970: 0), "invalid last-used date should preserve epoch fallback")
    try expect(detail.thumbnailPath == detail.assetPath, "empty thumbnail path should use PromptItem initializer fallback")
    try expect(detail.captureID == nil && detail.capturedSource == nil, "nil/malformed capture fields should preserve legacy optional fallback")
}

func runItemDetailServiceTests() async throws {
    try await testPromptItemDetailMatchesLoadItemsAcrossMetadataAndCardinality()
    try await testPromptItemDetailSupportsCancellationToken()
    try await testPromptItemDetailCancelsAfterSQLiteStep()
    try await testPromptItemDetailMatchesLegacyFallbacksAndOptionals()
}
