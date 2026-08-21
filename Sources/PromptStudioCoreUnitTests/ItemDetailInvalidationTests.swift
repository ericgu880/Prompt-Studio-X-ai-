import Foundation
import PromptStudioCore

private final class ItemDetailEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [ItemDetailInvalidationEvent] = []

    func append(_ event: ItemDetailInvalidationEvent) {
        lock.withLock { storedEvents.append(event) }
    }

    var events: [ItemDetailInvalidationEvent] {
        lock.withLock { storedEvents }
    }
}

private final class ReentrantCaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var hasReentered = false
    private var storedErrors: [String] = []

    func beginReentry() -> Bool {
        lock.withLock {
            guard !hasReentered else { return false }
            hasReentered = true
            return true
        }
    }

    func append(error: Error) {
        lock.withLock { storedErrors.append(error.localizedDescription) }
    }

    var errors: [String] {
        lock.withLock { storedErrors }
    }
}

private func invalidationTemporaryLibraryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("PromptStudio-ItemDetailInvalidation-\(UUID().uuidString)", isDirectory: true)
}

private func invalidationTagItem(
    id: String,
    tags: [String],
    sortOrder: Int,
    deletedAt: Date? = nil
) -> PromptItem {
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000 - Double(sortOrder))
    return PromptItem(
        id: id,
        title: "Invalidation item \(id)",
        type: .image,
        assetKind: .image,
        modelId: "model-a",
        modelName: "Model A",
        folderId: "folder-a",
        folderName: "Folder A",
        category: "image",
        assetPath: "",
        thumbnailPath: "",
        aspectRatio: "1:1",
        width: 100,
        height: 100,
        format: "PNG",
        fileSize: 1,
        deletedAt: deletedAt,
        createdAt: createdAt,
        updatedAt: createdAt,
        lastUsedAt: createdAt,
        sortOrder: sortOrder,
        tags: tags,
        versions: [
            PromptVersion(
                promptItemId: id,
                version: "V1",
                prompt: "Prompt \(id)",
                createdAt: createdAt
            )
        ]
    )
}

private func relationRows(for repository: PromptRepository, itemID: String) throws -> [[String: String?]] {
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    return try database.query(
        """
        SELECT isDeleted, sortOrder, createdAt, lastUsedAt
        FROM prompt_item_tags
        WHERE promptItemId = ?
        ORDER BY ordinal ASC;
        """,
        values: [.text(itemID)]
    )
}

private func relationValue(_ row: [String: String?], _ key: String) -> String {
    guard let value = row[key] else { return "" }
    return value ?? ""
}

private func assertRelationMirror(
    _ repository: PromptRepository,
    itemID: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard let item = try repository.loadItems().first(where: { $0.id == itemID }) else {
        throw CoreUnitTestError.failure("mirror check item missing at \(file):\(line)")
    }
    let rows = try relationRows(for: repository, itemID: itemID)
    try expect(!rows.isEmpty, "relation mirror should retain every tag occurrence")
    for row in rows {
        try expect(
            relationValue(row, "isDeleted") == (item.deletedAt == nil ? "0" : "1"),
            "relation isDeleted should mirror prompt_items.deletedAt"
        )
        try expect(relationValue(row, "sortOrder") == String(item.sortOrder), "relation sortOrder should mirror item")
        try expect(
            relationValue(row, "createdAt") == ISO8601DateFormatter().string(from: item.createdAt),
            "relation createdAt should mirror item"
        )
        try expect(
            relationValue(row, "lastUsedAt") == ISO8601DateFormatter().string(from: item.lastUsedAt),
            "relation lastUsedAt should mirror item"
        )
    }
}

func testItemDetailInvalidationHubSharesByCanonicalLibraryAndCancels() throws {
    let libraryURL = invalidationTemporaryLibraryURL()
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    let alternateURL = libraryURL.appendingPathComponent("nested/../")

    let first = ItemDetailInvalidationHub.shared(for: libraryURL)
    let second = ItemDetailInvalidationHub.shared(for: alternateURL)
    try expect(first === second, "canonical database URLs should share one invalidation hub")

    let recorder = ItemDetailEventRecorder()
    let subscription = first.subscribe { recorder.append($0) }
    _ = first.publish(changedItemIDs: ["one", "one"], removedItemIDs: ["gone"])
    try expect(recorder.events.count == 1, "subscribers should receive one merged mutation event")
    try expect(recorder.events[0].changedItemIDs == ["one"], "changed IDs should be deduplicated")
    try expect(recorder.events[0].removedItemIDs == ["gone"], "removed IDs should be preserved")
    try expect(recorder.events[0].itemRevisions["one"] == 1, "first item revision should start at one")
    subscription.cancel()
    _ = first.publish(changedItemIDs: ["one"])
    try expect(recorder.events.count == 1, "cancelled subscribers should not receive later events")
}

func testItemDetailInvalidationHubRevisionIsMonotonicAndLibrariesAreIsolated() throws {
    let firstURL = invalidationTemporaryLibraryURL()
    let secondURL = invalidationTemporaryLibraryURL()
    defer {
        try? FileManager.default.removeItem(at: firstURL)
        try? FileManager.default.removeItem(at: secondURL)
    }

    let first = ItemDetailInvalidationHub.shared(for: firstURL)
    let second = ItemDetailInvalidationHub.shared(for: secondURL)
    try expect(first !== second, "different libraries must not share a mutation hub")
    let firstEvent = first.publish(changedItemIDs: ["same-id"])!
    let secondEvent = first.publish(removedItemIDs: ["same-id"])!
    try expect(secondEvent.revision > firstEvent.revision, "global revisions should be monotonic")
    try expect(first.itemRevision(for: "same-id") == 2, "per-item revisions should be monotonic")
    try expect(second.currentRevision == 0, "different libraries should have independent revisions")
}

func testPromptRepositoryPublishesCommittedItemDetailInvalidations() throws {
    let libraryURL = invalidationTemporaryLibraryURL()
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    let repository = try PromptRepository(libraryURL: libraryURL)
    let secondRepository = try PromptRepository(libraryURL: libraryURL)
    try expect(
        repository.itemDetailInvalidationHub === secondRepository.itemDetailInvalidationHub,
        "repositories for one library should expose the shared invalidation hub"
    )

    let recorder = ItemDetailEventRecorder()
    let subscription = secondRepository.itemDetailInvalidationHub.subscribe { recorder.append($0) }
    defer { subscription.cancel() }

    var item = invalidationTagItem(id: "changed", tags: ["one"], sortOrder: 1)
    try repository.saveItem(item)
    try expect(recorder.events.last?.changedItemIDs == [item.id], "insert should publish changed item ID")
    let firstRevision = recorder.events.last!.revision

    item.captureID = "capture"
    try repository.saveItem(item)
    _ = try repository.saveCapturedItem(item)
    try expect(recorder.events.count == 2, "duplicate capture insert should not publish a second event")

    item.folderId = "folder-b"
    item.folderName = "Folder B"
    item.updatedAt = Date(timeIntervalSince1970: 1_700_000_010)
    try repository.updateItemFolders([item])
    try repository.markDeleted(itemID: item.id, deletedAt: Date(timeIntervalSince1970: 1_700_000_011))
    try repository.markDeleted(itemID: item.id, deletedAt: nil)
    try repository.updateLastUsed(itemID: item.id, at: Date(timeIntervalSince1970: 1_700_000_012))
    try repository.updateThumbnailPath(itemID: item.id, thumbnailPath: "thumb-a")
    try repository.updateThumbnailPaths([item.id: "thumb-b"])
    try repository.updateSortOrders([(id: item.id, sortOrder: 9)])

    let changedEvents = recorder.events.dropFirst(2)
    try expect(changedEvents.allSatisfy { $0.changedItemIDs == [item.id] }, "item writes should publish changed IDs")
    try expect(recorder.events.last!.revision > firstRevision, "repository events should advance the shared revision")

    var duplicateA = invalidationTagItem(id: "rollback-a", tags: ["a"], sortOrder: 2)
    var duplicateB = invalidationTagItem(id: "rollback-b", tags: ["b"], sortOrder: 3)
    duplicateA.captureID = "duplicate-capture"
    duplicateB.captureID = "duplicate-capture"
    let eventCountBeforeRollback = recorder.events.count
    do {
        try repository.saveItems([duplicateA, duplicateB])
        throw CoreUnitTestError.failure("duplicate capture IDs should rollback the batch")
    } catch let error as CoreUnitTestError {
        throw error
    } catch {
        // Expected constraint failure; the observer must remain unchanged.
    }
    try expect(recorder.events.count == eventCountBeforeRollback, "failed transactions must not publish events")
    try expect(try repository.loadItems().allSatisfy { !$0.id.hasPrefix("rollback-") }, "failed batch must rollback rows")

    try repository.permanentlyDelete(itemID: item.id)
    try expect(recorder.events.last?.removedItemIDs == [item.id], "permanent delete should publish removed ID")
}

func testPromptRepositoryFolderMutationsAdvanceSharedRevisionAndPublishRenameIDs() throws {
    let libraryURL = invalidationTemporaryLibraryURL()
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    let repository = try PromptRepository(libraryURL: libraryURL)
    let folder = LibraryFolder(id: "folder-revision", name: "Before")
    try repository.saveFolder(folder)

    var item = invalidationTagItem(id: "folder-revision-item", tags: [], sortOrder: 0)
    item.folderId = folder.id
    item.folderName = folder.name
    try repository.saveItem(item)

    let recorder = ItemDetailEventRecorder()
    let subscription = repository.itemDetailInvalidationHub.subscribe { recorder.append($0) }
    defer { subscription.cancel() }

    let beforeRename = repository.libraryDataRevision.current
    try repository.renameFolder(id: folder.id, name: "After")
    try expect(repository.libraryDataRevision.current > beforeRename, "folder rename should advance the shared revision")
    try expect(recorder.events.count == 1, "folder rename should publish one post-commit event")
    try expect(
        recorder.events[0].changedItemIDs == [item.id],
        "folder rename should publish every affected prompt item ID"
    )
    try expect(
        recorder.events[0].revision == repository.libraryDataRevision.current,
        "folder rename event should carry the shared committed revision"
    )

    let folderOnly = LibraryFolder(id: "folder-only", name: "Folder only")
    let beforeSaveFolder = repository.libraryDataRevision.current
    try repository.saveFolder(folderOnly)
    try expect(repository.libraryDataRevision.current > beforeSaveFolder, "saveFolder should advance the shared revision")
    try expect(recorder.events.count == 1, "folder-only save should not publish an item event")

    let beforeParentUpdate = repository.libraryDataRevision.current
    try repository.updateFolderParentsAndSort([
        FolderParentSortUpdate(folderID: folderOnly.id, parentID: folder.id, sortOrder: 4)
    ])
    try expect(
        repository.libraryDataRevision.current > beforeParentUpdate,
        "folder parent and sort updates should advance the shared revision"
    )
    try expect(recorder.events.count == 1, "folder-only parent update should not publish an item event")

    let beforeDelete = repository.libraryDataRevision.current
    try repository.deleteFolder(id: folderOnly.id)
    try expect(repository.libraryDataRevision.current > beforeDelete, "folder delete should advance the shared revision")
    try expect(recorder.events.count == 1, "folder-only delete should not publish an item event")
}

func testPromptRepositoryMissingFolderMutationsDoNotAdvanceSharedRevision() throws {
    let libraryURL = invalidationTemporaryLibraryURL()
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    let repository = try PromptRepository(libraryURL: libraryURL)
    let beforeRename = repository.libraryDataRevision.current

    do {
        try repository.renameFolder(id: "missing-folder", name: "Renamed")
        throw CoreUnitTestError.failure("missing folder rename should fail")
    } catch let error as PromptRepositoryFolderMutationError {
        try expect(error == .folderNotFound("missing-folder"), "missing folder rename should report folderNotFound")
    } catch let error as CoreUnitTestError {
        throw error
    }
    try expect(
        repository.libraryDataRevision.current == beforeRename,
        "missing folder rename must not advance the shared revision"
    )

    do {
        try repository.deleteFolder(id: "missing-folder")
        throw CoreUnitTestError.failure("missing folder delete should fail")
    } catch let error as PromptRepositoryFolderMutationError {
        try expect(error == .folderNotFound("missing-folder"), "missing folder delete should report folderNotFound")
    } catch let error as CoreUnitTestError {
        throw error
    }
    try expect(
        repository.libraryDataRevision.current == beforeRename,
        "missing folder delete must not advance the shared revision"
    )
}

func testPromptRepositoryBatchFolderOrderAdvancesOneSharedRevision() throws {
    let libraryURL = invalidationTemporaryLibraryURL()
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    let repository = try PromptRepository(libraryURL: libraryURL)
    let folders = [
        LibraryFolder(id: "order-a", name: "A", sortOrder: 0),
        LibraryFolder(id: "order-b", name: "B", sortOrder: 1),
        LibraryFolder(id: "order-c", name: "C", sortOrder: 2)
    ]
    for folder in folders { try repository.saveFolder(folder) }

    let before = repository.libraryDataRevision.current
    try repository.updateFolderParentsAndSort([
        FolderParentSortUpdate(folderID: "order-c", parentID: nil, sortOrder: 0),
        FolderParentSortUpdate(folderID: "order-a", parentID: nil, sortOrder: 1),
        FolderParentSortUpdate(folderID: "order-b", parentID: nil, sortOrder: 2)
    ])
    try expect(
        repository.libraryDataRevision.current == before + 1,
        "one batch folder order update must advance exactly one shared revision"
    )
    try expect(
        try repository.loadFolders().map(\.id) == ["order-c", "order-a", "order-b"],
        "one batch folder order update must persist every sibling order"
    )
}

func testPromptRepositoryNoOpFolderMutationsDoNotAdvanceSharedRevision() throws {
    let libraryURL = invalidationTemporaryLibraryURL()
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    let repository = try PromptRepository(libraryURL: libraryURL)
    let folder = LibraryFolder(id: "noop-folder", name: "No-op", sortOrder: 7)
    try repository.saveFolder(folder)
    var item = invalidationTagItem(id: "noop-item", tags: ["noop"], sortOrder: 0)
    item.folderId = folder.id
    item.folderName = folder.name
    try repository.saveItem(item)

    let recorder = ItemDetailEventRecorder()
    let subscription = repository.itemDetailInvalidationHub.subscribe { recorder.append($0) }
    defer { subscription.cancel() }
    let before = repository.libraryDataRevision.current

    try repository.saveFolder(folder)
    try repository.renameFolder(id: folder.id, name: folder.name)
    try repository.updateFolderParentsAndSort([
        FolderParentSortUpdate(folderID: folder.id, parentID: folder.parentId, sortOrder: folder.sortOrder)
    ])

    try expect(repository.libraryDataRevision.current == before, "same-value folder mutations must not advance the shared revision")
    try expect(recorder.events.isEmpty, "same-name folder rename must not publish an item invalidation")
}

func testSaveCapturedItemPublishesAfterUnlockAndSupportsReentrantObserver() throws {
    let libraryURL = invalidationTemporaryLibraryURL()
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    let repository = try PromptRepository(libraryURL: libraryURL)
    let recorder = ItemDetailEventRecorder()
    let state = ReentrantCaptureState()
    var outerValue = invalidationTagItem(id: "capture-outer", tags: ["outer"], sortOrder: 0)
    var innerValue = invalidationTagItem(id: "capture-inner", tags: ["inner"], sortOrder: 1)
    outerValue.captureID = "capture-outer"
    innerValue.captureID = "capture-inner"
    let outer = outerValue
    let inner = innerValue

    let subscription = repository.itemDetailInvalidationHub.subscribe { event in
        recorder.append(event)
        guard event.changedItemIDs.contains(outer.id), state.beginReentry() else { return }
        do {
            _ = try repository.saveCapturedItem(inner)
        } catch {
            state.append(error: error)
        }
    }
    defer { subscription.cancel() }

    let completion = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        do {
            _ = try repository.saveCapturedItem(outer)
        } catch {
            state.append(error: error)
        }
        completion.signal()
    }
    try expect(
        completion.wait(timeout: .now() + 3) == .success,
        "saveCapturedItem observer reentry must not deadlock on captureInsertLock"
    )
    try expect(state.errors.isEmpty, "reentrant capture should complete without errors")
    try expect(recorder.events.count == 2, "outer and reentrant inner inserts should each publish once")
    try expect(
        recorder.events.flatMap { $0.changedItemIDs } == [outer.id, inner.id],
        "reentrant capture events should preserve insert/no-op IDs"
    )

    _ = try repository.saveCapturedItem(outer)
    try expect(recorder.events.count == 2, "duplicate capture retry should be a no-op event")
}

func testPromptRepositoryPlaceholderMigrationPublishesOnlySuccessfulIDs() throws {
    let libraryURL = invalidationTemporaryLibraryURL()
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    let repository = try PromptRepository(libraryURL: libraryURL)
    var placeholder = invalidationTagItem(id: "placeholder", tags: ["text"], sortOrder: 0)
    placeholder.assetPath = ""
    placeholder.thumbnailPath = ""
    placeholder.format = "PROMPT"
    placeholder.type = .text
    placeholder.assetKind = .text
    try repository.saveItem(placeholder)
    let recorder = ItemDetailEventRecorder()
    let subscription = repository.itemDetailInvalidationHub.subscribe { recorder.append($0) }
    defer { subscription.cancel() }
    let result = try repository.migratePromptPlaceholders()
    try expect(result.migratedItemIDs == [placeholder.id], "placeholder migration should report the successful item")
    try expect(recorder.events.last?.changedItemIDs == [placeholder.id], "placeholder migration should invalidate migrated details")
}

func testTagRelationMirrorSurvivesAllPromptItemMutationPaths() throws {
    let libraryURL = invalidationTemporaryLibraryURL()
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    let repository = try PromptRepository(libraryURL: libraryURL)
    try repository.saveItems([
        invalidationTagItem(id: "mirror-a", tags: ["Alpha", "Beta"], sortOrder: 0),
        invalidationTagItem(id: "mirror-b", tags: ["Gamma"], sortOrder: 1)
    ])
    _ = try repository.prepareTagRelationMigration()
    _ = try repository.runTagRelationBackfill()
    _ = try repository.validateTagRelationConsistency()
    try expect(repository.tagRelationsReady, "validated relation schema should open the lightweight gate")

    var item = try repository.loadItems().first(where: { $0.id == "mirror-a" })!
    item.sortOrder = 7
    item.createdAt = Date(timeIntervalSince1970: 1_700_001_000)
    item.lastUsedAt = Date(timeIntervalSince1970: 1_700_001_001)
    try repository.saveItem(item)
    try assertRelationMirror(repository, itemID: item.id)

    try repository.markDeleted(itemID: item.id, deletedAt: Date(timeIntervalSince1970: 1_700_001_002))
    try assertRelationMirror(repository, itemID: item.id)
    try repository.markDeleted(itemID: item.id, deletedAt: nil)
    try assertRelationMirror(repository, itemID: item.id)

    try repository.updateSortOrders([(id: item.id, sortOrder: 11)])
    try assertRelationMirror(repository, itemID: item.id)
    try repository.updateLastUsed(itemID: item.id, at: Date(timeIntervalSince1970: 1_700_001_003))
    try assertRelationMirror(repository, itemID: item.id)

    item.folderId = "folder-b"
    item.folderName = "Folder B"
    item.updatedAt = Date(timeIntervalSince1970: 1_700_001_004)
    try repository.updateItemFolders([item])
    try assertRelationMirror(repository, itemID: item.id)

    var imported = invalidationTagItem(id: "mirror-import", tags: ["Import"], sortOrder: 3)
    imported.lastUsedAt = Date(timeIntervalSince1970: 1_700_001_005)
    try repository.saveItems([imported])
    try assertRelationMirror(repository, itemID: imported.id)

    try repository.markDeleted(itemIDs: [item.id, imported.id], deletedAt: Date(timeIntervalSince1970: 1_700_001_006))
    try assertRelationMirror(repository, itemID: item.id)
    try assertRelationMirror(repository, itemID: imported.id)
    try repository.markDeleted(itemIDs: [item.id, imported.id], deletedAt: nil)
    try assertRelationMirror(repository, itemID: item.id)
    try assertRelationMirror(repository, itemID: imported.id)

    try repository.renameTag(from: "Alpha", to: "Renamed")
    try assertRelationMirror(repository, itemID: item.id)
    try repository.deleteTag(named: "Renamed")
    try expect(try relationRows(for: repository, itemID: item.id).count == 1, "tag delete should remove relation occurrences")
    try repository.permanentlyDelete(itemID: imported.id)
    try expect(try relationRows(for: repository, itemID: imported.id).isEmpty, "permanent delete should cascade relation rows")
}
