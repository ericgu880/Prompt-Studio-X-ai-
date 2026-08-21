import Foundation
import PromptStudioCore

private func tagRelationTemporaryLibraryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("PromptStudio-TagRelation-\(UUID().uuidString)", isDirectory: true)
}

private func tagRelationItem(
    id: String,
    tags: [String],
    sortOrder: Int,
    deletedAt: Date? = nil,
    favorite: Bool = false
) -> PromptItem {
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000 - Double(sortOrder))
    return PromptItem(
        id: id,
        title: "Tag item \(id)",
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
        favorite: favorite,
        deletedAt: deletedAt,
        createdAt: createdAt,
        updatedAt: createdAt,
        lastUsedAt: createdAt,
        sortOrder: sortOrder,
        tags: tags,
        referenceAssets: [],
        versions: [],
        description: ""
    )
}

func testReadOnlyOnlineBackupPreservesSourceBytesAndCopiesWALState() throws {
    let root = tagRelationTemporaryLibraryURL()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sourceURL = root.appendingPathComponent("source.sqlite")
    let backupURL = root.appendingPathComponent("backup.sqlite")
    let source = try SQLiteDatabase(path: sourceURL.path)
    try source.execute("CREATE TABLE sample(id TEXT PRIMARY KEY);")
    try source.run("INSERT INTO sample(id) VALUES (?);", values: [.text("wal-row")])
    let sourceBytesBefore = try Data(contentsOf: sourceURL)

    try SQLiteDatabase.backup(fromReadOnlyPath: sourceURL.path, to: backupURL.path)

    let sourceBytesAfter = try Data(contentsOf: sourceURL)
    try expect(sourceBytesAfter == sourceBytesBefore, "read-only online backup must not rewrite the source database file")
    let copied = try SQLiteDatabase.validateBackup(
        at: backupURL.path,
        expectedTableRowCounts: ["sample": 1]
    )
    try expect(copied.integrityOK, "read-only online backup should include committed WAL state")
}

func testTagRelationMigrationResumesAndPreservesExactNameIdentity() throws {
    let libraryURL = tagRelationTemporaryLibraryURL()
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    let repository = try PromptRepository(libraryURL: libraryURL)
    try repository.saveItems([
        tagRelationItem(id: "a", tags: ["Foo", "foo", "重复", "重复", ""], sortOrder: 0),
        tagRelationItem(id: "b", tags: ["特/殊", "空 格"], sortOrder: 1),
        tagRelationItem(id: "c", tags: ["trash-tag"], sortOrder: 2, deletedAt: Date())
    ])

    let prepared = try repository.prepareTagRelationMigration()
    try expect(prepared.phase == .backfilling, "preparation should create a resumable backfill state")
    try expect(!prepared.backupPath.isEmpty, "preparation must create a consistent database backup")
    try expect(FileManager.default.fileExists(atPath: prepared.backupPath), "migration backup should exist")
    let backupValidation = try SQLiteDatabase.validateBackup(
        at: prepared.backupPath,
        expectedTableRowCounts: ["prompt_items": 3]
    )
    try expect(backupValidation.integrityOK, "migration backup should pass integrity_check before DDL")
    try expect(backupValidation.foreignKeyViolationCount == 0, "migration backup should pass foreign_key_check")
    try expect(backupValidation.tableRowCounts["prompt_items"] == 3, "migration backup should contain every source item")

    let partial = try repository.runTagRelationBackfill(batchSize: 1, maxBatches: 1)
    try expect(!partial.completed && partial.processedCount == 1, "one batch should persist partial progress")

    let reopened = try PromptRepository(libraryURL: libraryURL)
    let resumed = try reopened.runTagRelationBackfill(batchSize: 1)
    try expect(resumed.completed && resumed.processedCount == 3, "a reopened repository should resume from durable progress")

    let idempotent = try reopened.runTagRelationBackfill(batchSize: 500)
    try expect(idempotent.completed && idempotent.processedCount == 3, "completed migration should be idempotent")
    let consistency = try reopened.validateTagRelationConsistency()
    try expect(consistency.isConsistent, "JSON membership and relation membership should match item by item")
    try expect(consistency.duplicateJSONEntryCount == 1, "duplicate legacy tag entries should be reported without duplicating relations")
    try expect(consistency.emptyTagCount == 1, "empty legacy names must be audited rather than silently normalized")
    try expect(consistency.distinctRelationTagNames.contains("Foo"), "uppercase tag identity should be preserved")
    try expect(consistency.distinctRelationTagNames.contains("foo"), "lowercase tag identity should remain distinct")
    try expect(consistency.deletedItemRelationCount == 1, "trash items should keep tag membership for restoration")
    try expect(reopened.tagRelationsReady, "feature gate should open only after consistency validation completes")

    let integrity = try SQLiteDatabase(path: reopened.databaseURL.path, mode: .existingReadWrite)
    try expect(integrity.query("PRAGMA integrity_check;").first?["integrity_check"]! == "ok", "migration database should pass integrity_check")
    try expect(integrity.query("PRAGMA foreign_key_check;").isEmpty, "migration database should pass foreign_key_check")
}

func testTagRelationMigrationRejectsNegativeMaxBatches() throws {
    let libraryURL = tagRelationTemporaryLibraryURL()
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    let repository = try PromptRepository(libraryURL: libraryURL)
    try repository.saveItem(tagRelationItem(id: "negative-max", tags: ["tag"], sortOrder: 0))
    _ = try repository.prepareTagRelationMigration()
    do {
        _ = try repository.runTagRelationBackfill(batchSize: 1, maxBatches: -1)
        throw CoreUnitTestError.failure("negative tag maxBatches must be rejected")
    } catch TagRelationMigrationError.invalidMaxBatches {
        // Expected.
    }
}

func testTagRelationDualWriteCoversSaveDeleteRestoreRenameAndTagDelete() throws {
    let libraryURL = tagRelationTemporaryLibraryURL()
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    let repository = try PromptRepository(libraryURL: libraryURL)
    try repository.saveItem(tagRelationItem(id: "dual", tags: ["Alpha", "alpha"], sortOrder: 0))
    _ = try repository.prepareTagRelationMigration()
    _ = try repository.runTagRelationBackfill()

    var item = try repository.loadItems().first(where: { $0.id == "dual" })!
    item.tags = ["Alpha", "新增", "新增"]
    try repository.saveItem(item)
    try expect(try repository.validateTagRelationConsistency().isConsistent, "saveItem should dual-write exact set membership")

    try repository.markDeleted(itemID: item.id, deletedAt: Date())
    var report = try repository.validateTagRelationConsistency()
    try expect(report.isConsistent && report.deletedItemRelationCount == 2, "soft delete should preserve and mark relations")

    try repository.markDeleted(itemID: item.id, deletedAt: nil)
    report = try repository.validateTagRelationConsistency()
    try expect(report.isConsistent && report.deletedItemRelationCount == 0, "restore should reactivate relation rows")

    try repository.renameTag(from: "新增", to: "重命名")
    item = try repository.loadItems().first(where: { $0.id == "dual" })!
    try expect(item.tags == ["Alpha", "重命名", "重命名"], "rename should preserve JSON order and duplicate multiplicity")
    try expect(try repository.validateTagRelationConsistency().isConsistent, "rename should update relation in the same transaction")

    try repository.deleteTag(named: "Alpha")
    item = try repository.loadItems().first(where: { $0.id == "dual" })!
    try expect(item.tags == ["重命名", "重命名"], "tag deletion should remove every exact JSON occurrence")
    try expect(try repository.validateTagRelationConsistency().isConsistent, "tag deletion should remove relation membership")

    try repository.permanentlyDelete(itemID: item.id)
    report = try repository.validateTagRelationConsistency()
    try expect(report.isConsistent && report.relationCount == 0, "hard deletion should cascade relation rows")
}

func testTagRelationMigrationFailureKeepsLegacyJSONAndGateClosed() throws {
    let libraryURL = tagRelationTemporaryLibraryURL()
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    let repository = try PromptRepository(libraryURL: libraryURL)
    try repository.saveItem(tagRelationItem(id: "failure", tags: ["keep-me"], sortOrder: 0))
    let beforeJSON = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
        .query("SELECT tagsJSON FROM prompt_items WHERE id = 'failure';").first?["tagsJSON"]!
    _ = try repository.prepareTagRelationMigration()

    let sabotage = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    try sabotage.execute(
        """
        CREATE TRIGGER fail_tag_relation_insert
        BEFORE INSERT ON prompt_item_tags
        BEGIN SELECT RAISE(ABORT, 'injected tag relation failure'); END;
        """
    )
    do {
        _ = try repository.runTagRelationBackfill(batchSize: 1)
        throw CoreUnitTestError.failure("injected backfill failure should throw")
    } catch let failure as CoreUnitTestError {
        throw failure
    } catch {
        // Expected: the repository records the failure and leaves the old source intact.
    }

    let afterJSON = try sabotage.query("SELECT tagsJSON FROM prompt_items WHERE id = 'failure';").first?["tagsJSON"]!
    try expect(beforeJSON == afterJSON, "failed migration must never mutate tagsJSON")
    try expect(!repository.tagRelationsReady, "failed migration must keep the SQL tag feature disabled")
    try expect(try repository.tagRelationMigrationState().phase == .failed, "failure state must be durable")
}

func testTagRelationMigrationRejectsMalformedJSONAndKeepsSourceUntouched() throws {
    let libraryURL = tagRelationTemporaryLibraryURL()
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    let repository = try PromptRepository(libraryURL: libraryURL)
    try repository.saveItem(tagRelationItem(id: "malformed", tags: ["keep-me"], sortOrder: 0))
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    try database.run(
        "UPDATE prompt_items SET tagsJSON = ? WHERE id = ?;",
        values: [.text(#"{"not":"an array"}"#), .text("malformed")]
    )
    let before = try database.query("SELECT tagsJSON FROM prompt_items WHERE id = 'malformed';").first?[
        "tagsJSON"
    ]!
    _ = try repository.prepareTagRelationMigration()
    do {
        _ = try repository.runTagRelationBackfill(batchSize: 1)
        throw CoreUnitTestError.failure("malformed tagsJSON should fail the migration")
    } catch let failure as CoreUnitTestError {
        throw failure
    } catch {
        // Expected: malformed JSON is durable migration failure.
    }
    try expect(!repository.tagRelationsReady, "malformed JSON must keep the relation gate closed")
    try expect(try repository.tagRelationMigrationState().phase == .failed, "malformed JSON must persist failed state")
    let after = try database.query("SELECT tagsJSON FROM prompt_items WHERE id = 'malformed';").first?["tagsJSON"]!
    try expect(before == after, "malformed migration must never rewrite the legacy JSON source")
}

func testTagRelationMigrationHandles15959KeysetRows() throws {
    let libraryURL = tagRelationTemporaryLibraryURL()
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    let repository = try PromptRepository(libraryURL: libraryURL)
    let items = (0..<15_959).map { index in
        tagRelationItem(
            id: String(format: "item-%05d", index),
            tags: ["tag-\(index % 7)", index.isMultiple(of: 11) ? "重复" : ""],
            sortOrder: index
        )
    }
    try repository.saveItems(items)
    let prepared = try repository.prepareTagRelationMigration()
    try expect(prepared.totalCount == 15_959, "migration metadata should snapshot every legacy item")
    let first = try repository.runTagRelationBackfill(batchSize: 500, maxBatches: 1)
    try expect(!first.completed && first.processedCount == 500, "bounded keyset backfill should checkpoint one batch")
    let resumed = try repository.runTagRelationBackfill(batchSize: 500)
    try expect(resumed.completed && resumed.processedCount == 15_959, "keyset resume should process all 15,959 rows")
    try expect(try repository.validateTagRelationConsistency().isConsistent, "large keyset migration should remain exact")
}
