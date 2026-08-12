import Foundation
import PromptStudioCore

@discardableResult
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws -> Bool {
    if try condition() {
        return true
    }
    throw CoreUnitTestError.failure(message)
}

enum CoreUnitTestError: Error, LocalizedError {
    case failure(String)

    var errorDescription: String? {
        switch self {
        case .failure(let message): message
        }
    }
}

final class CaptureRaceState: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var items: [PromptItem] = []
    private(set) var errors: [String] = []

    func append(item: PromptItem) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    func append(error: Error) {
        lock.lock()
        errors.append(error.localizedDescription)
        lock.unlock()
    }
}

func sampleItem(
    title: String,
    modelId: String = "nano_banana_2",
    assetKind: AssetKind = .image,
    tags: [String] = ["风景"],
    prompt: String,
    aspectRatio: String = "16:9",
    width: Int = 1920,
    height: Int = 1080,
    assetPath: String = "/tmp/mock.png",
    format: String = "PNG"
) -> PromptItem {
    let id = UUID().uuidString
    return PromptItem(
        id: id,
        title: title,
        type: assetKind.promptType,
        assetKind: assetKind,
        modelId: modelId,
        modelName: modelId,
        folderId: "folder-promptstudio",
        folderName: "PromptStudio",
        category: assetKind.displayName,
        assetPath: assetPath,
        aspectRatio: aspectRatio,
        width: width,
        height: height,
        format: format,
        fileSize: 1024,
        tags: tags,
        versions: [
            PromptVersion(promptItemId: id, version: "V1.0", prompt: prompt, parameters: ["比例": "16:9"])
        ]
    )
}

func temporaryLibraryURL() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PromptStudioCoreUnitTests")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func testLibraryURLResolution() throws {
    let defaultURL = PromptRepository.defaultLibraryURL()
    let spacedPath = "/tmp/promptstudio qa library"
    let equalsPath = "/tmp/promptstudio-equals-library"
    let envPath = "/tmp/promptstudio-env-library"
    let argPath = "/tmp/promptstudio-arg-wins"

    try expect(
        PromptRepository.resolvedLibraryURL(arguments: ["--library", spacedPath], environment: [:]).path == spacedPath,
        "--library PATH should resolve the following token as the library URL"
    )
    try expect(
        PromptRepository.resolvedLibraryURL(arguments: ["--library=\(equalsPath)"], environment: [:]).path == equalsPath,
        "--library=PATH should resolve the inline value as the library URL"
    )
    try expect(
        PromptRepository.resolvedLibraryURL(arguments: [], environment: ["PROMPTSTUDIO_LIBRARY_PATH": envPath]).path == envPath,
        "PROMPTSTUDIO_LIBRARY_PATH should resolve when no --library argument is present"
    )
    try expect(
        PromptRepository.resolvedLibraryURL(arguments: ["--library", argPath], environment: ["PROMPTSTUDIO_LIBRARY_PATH": envPath]).path == argPath,
        "--library should take priority over PROMPTSTUDIO_LIBRARY_PATH"
    )
    try expect(
        PromptRepository.resolvedLibraryURL(arguments: [], environment: [:]) == defaultURL,
        "missing overrides should fall back to the default library URL"
    )
}

func testExistingLibraryValidationDoesNotCreateDatabase() throws {
    let emptyDirectory = try temporaryLibraryURL()
    do {
        try PromptRepository.validateExistingLibrary(at: emptyDirectory)
        throw CoreUnitTestError.failure("existing library validation should reject an empty directory")
    } catch PromptRepositoryValidationError.missingDatabase {
        let databaseURL = emptyDirectory.appendingPathComponent("database/promptstudio.sqlite")
        try expect(
            !FileManager.default.fileExists(atPath: databaseURL.path),
            "existing library validation must not create database files"
        )
    }
}

@discardableResult
func measurePerformance(_ label: String, threshold: TimeInterval, operation: () throws -> Void) throws -> TimeInterval {
    let start = Date()
    try operation()
    let duration = Date().timeIntervalSince(start)
    try expect(duration < threshold, "\(label) should finish under \(threshold)s, got \(String(format: "%.3f", duration))s")
    return duration
}

func performanceItem(index: Int) -> PromptItem {
    let targetMarker = index == 760 ? " needle-forest-target" : ""
    var item = sampleItem(
        title: index == 760 ? "Forest Product Shot" : "Prompt \(index)",
        modelId: "model-\(index % 8)",
        assetKind: index.isMultiple(of: 3) ? .markdown : .image,
        tags: ["tag-\(index % 10)", index.isMultiple(of: 2) ? "even" : "odd"],
        prompt: "Prompt body \(index) for campaign\(targetMarker)",
        assetPath: "/tmp/promptstudio-performance-\(index).md",
        format: index.isMultiple(of: 3) ? "MD" : "PNG"
    )
    item.folderId = "folder-\(index % 20)"
    item.folderName = "Folder \(index % 20)"
    item.favorite = index.isMultiple(of: 5)
    item.lastUsedAt = Date(timeIntervalSince1970: TimeInterval(index))
    item.sortOrder = index
    item.description = "metadata bucket \(index % 13)"
    if index.isMultiple(of: 17) {
        item.deletedAt = Date()
    }
    if index.isMultiple(of: 11) {
        item.referenceAssets = [
            ReferenceAsset(type: "image", path: "/tmp/reference-\(index).png", label: "reference \(index)")
        ]
    }
    item.versions.append(
        PromptVersion(
            promptItemId: item.id,
            version: "V1.1",
            prompt: "Prompt body \(index) updated\(targetMarker)",
            negativePrompt: "watermark",
            parameters: ["ar": "16:9", "seed": "\(index)"],
            note: "performance fixture"
        )
    )
    return item
}

func makeDocxFixture(text: String) throws -> URL {
    let directory = try temporaryLibraryURL()
    let textURL = directory.appendingPathComponent("fixture.txt")
    let docxURL = directory.appendingPathComponent("fixture.docx")
    try text.write(to: textURL, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
    process.arguments = ["-convert", "docx", "-output", docxURL.path, textURL.path]
    let errorPipe = Pipe()
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    try expect(process.terminationStatus == 0, "textutil should create docx fixture: \(stderr)")
    return docxURL
}

func testSearchFiltering() throws {
    let item = sampleItem(title: "森林露营车", modelId: "midjourney", tags: ["风景", "插画"], prompt: "green camper in a lush forest")
    let other = sampleItem(title: "人物肖像", modelId: "seedream_7", tags: ["人物"], prompt: "editorial portrait")

    try expect(PromptFiltering.apply([item, other], filter: PromptFilter(query: "camper")).map(\.id) == [item.id], "query should match prompt body")
    try expect(PromptFiltering.apply([item, other], filter: PromptFilter(modelId: "seedream_7")).map(\.id) == [other.id], "model filter should isolate Seedream item")
    try expect(PromptFiltering.apply([item, other], filter: PromptFilter(collection: .tag("插画"))).map(\.id) == [item.id], "tag collection should isolate illustration item")
}

func testThumbnailDecodeSizing() throws {
    try expect(ThumbnailDecodeSizing.bucket(for: 1) == 256, "small thumbnails should use the 256px bucket")
    try expect(ThumbnailDecodeSizing.bucket(for: 256) == 256, "bucket boundaries should stay stable")
    try expect(ThumbnailDecodeSizing.bucket(for: 257) == 512, "medium thumbnails should use the 512px bucket")
    try expect(ThumbnailDecodeSizing.bucket(for: 900) == 1024, "large thumbnails should use the 1024px bucket")
    try expect(ThumbnailDecodeSizing.bucket(for: 4096) == 1024, "thumbnail decoding should cap at 1024px")
    try expect(
        ThumbnailDecodeSizing.reusableBuckets(for: 257) == [512, 1024],
        "a larger cached image should satisfy a smaller request"
    )
}

func testPromptSelectionResolver() throws {
    let first = sampleItem(title: "First", prompt: "first")
    let selected = sampleItem(title: "Selected", prompt: "selected")
    let items = [first, selected]
    try expect(
        PromptSelectionResolver.selectedID(preserving: selected.id, in: items, allowEmptySelection: false) == selected.id,
        "filtering should preserve a selection that remains visible"
    )
    try expect(
        PromptSelectionResolver.selectedID(preserving: "missing", in: items, allowEmptySelection: false) == first.id,
        "filtering should select the first result when the previous selection disappears"
    )
    try expect(
        PromptSelectionResolver.selectedID(preserving: "missing", in: items, allowEmptySelection: true) == nil,
        "filtering should allow an empty selection when requested"
    )
}

func testMarqueeSelectionResolver() throws {
    let selectionRect = MarqueeSelectionResolver.normalizedRect(
        from: CGPoint(x: 100, y: 80),
        to: CGPoint(x: 20, y: 10)
    )
    try expect(
        selectionRect == CGRect(x: 20, y: 10, width: 80, height: 70),
        "marquee selection should normalize its endpoints"
    )

    let itemFrames = [
        "image": CGRect(x: 0, y: 0, width: 40, height: 40),
        "markdown": CGRect(x: 39, y: 39, width: 40, height: 40),
        "outside": CGRect(x: 100, y: 100, width: 20, height: 20),
    ]
    let hitIDs = MarqueeSelectionResolver.hitIDs(
        in: CGRect(x: 20, y: 20, width: 20, height: 20),
        itemFrames: itemFrames
    )
    try expect(hitIDs == ["image", "markdown"], "marquee selection should include intersecting items")
    try expect(
        MarqueeSelectionResolver.hitIDs(in: selectionRect, itemFrames: [:]).isEmpty,
        "marquee selection should not hit when there are no item frames"
    )
    try expect(
        MarqueeSelectionResolver.hitIDs(in: CGRect(x: 20, y: 20, width: 0, height: 0), itemFrames: itemFrames).isEmpty,
        "zero-area marquee selection should not hit items"
    )
    try expect(
        MarqueeSelectionResolver.hitIDs(
            in: CGRect(x: 0, y: 0, width: 40, height: 40),
            itemFrames: ["edge": CGRect(x: 40, y: 0, width: 40, height: 40)]
        ).isEmpty,
        "edge-only contact should not count as an intersection"
    )

    let existing: Set<String> = ["existing"]
    try expect(
        MarqueeSelectionResolver.selection(base: existing, hits: hitIDs, additive: false) == hitIDs,
        "non-additive marquee selection should replace the base selection"
    )
    try expect(
        MarqueeSelectionResolver.selection(base: existing, hits: hitIDs, additive: true) == ["existing", "image", "markdown"],
        "additive marquee selection should union with the base selection"
    )
    try expect(
        MarqueeSelectionResolver.selection(base: existing, hits: [], additive: false).isEmpty,
        "non-additive marquee selection should replace the base selection with empty hits"
    )
    try expect(
        MarqueeSelectionResolver.selection(base: existing, hits: [], additive: true) == existing,
        "additive marquee selection should retain the base selection with empty hits"
    )
}

func testPromptItemDragPayload() throws {
    let a = "a"
    let b = "b"
    let c = "c"
    let payload = PromptItemDragPayload(itemIDs: [b, a, b, c])
    try expect(payload.itemIDs == [b, a, c], "drag payload should preserve the first occurrence of each item ID")
    try expect(
        PromptItemDragPayload(itemIDs: ["", "", ""]).itemIDs.isEmpty,
        "drag payload should discard empty item IDs"
    )

    let decoded = try PromptItemDragPayload.decode(payload.encoded())
    try expect(decoded == payload, "drag payload should round-trip through JSON")
    let normalizedJSON = Data(#"{"version":1,"itemIDs":["","a","a","b"]}"#.utf8)
    let directlyDecoded = try JSONDecoder().decode(PromptItemDragPayload.self, from: normalizedJSON)
    try expect(
        directlyDecoded.itemIDs == ["a", "b"],
        "direct JSON decoding should normalize item IDs"
    )

    let unsupportedVersionJSON = Data(#"{"version":2,"itemIDs":["a"]}"#.utf8)
    var staticDecodeRejected = false
    do {
        _ = try PromptItemDragPayload.decode(unsupportedVersionJSON)
    } catch {
        staticDecodeRejected = true
    }
    try expect(staticDecodeRejected, "static drag payload decoding should reject unsupported versions")

    var directDecodeRejected = false
    do {
        _ = try JSONDecoder().decode(PromptItemDragPayload.self, from: unsupportedVersionJSON)
    } catch {
        directDecodeRejected = true
    }
    try expect(directDecodeRejected, "direct JSON decoding should reject unsupported versions")
    try expect(
        PromptItemDragPayload.pasteboardTypeIdentifier == "com.promptstudio.internal.prompt-item-ids",
        "drag payload should expose the internal pasteboard type identifier"
    )
}

func testSelectionActionContextPreservesFinderStyleMultiSelection() throws {
    let visualIDs = ["image", "audio", "markdown", "video"]
    let selected = Set(["image", "audio", "markdown"])

    let selectedContext = PromptItemSelectionActionContext.resolve(
        clickedItemID: "audio",
        selectedItemIDs: selected,
        primaryID: "markdown",
        visualItemIDs: visualIDs
    )
    try expect(selectedContext.orderedItemIDs == ["image", "audio", "markdown"], "right-clicking a selected card should preserve the complete ordered selection")
    try expect(selectedContext.primaryID == "markdown", "right-clicking a selected card should preserve the primary item")

    let unselectedContext = PromptItemSelectionActionContext.resolve(
        clickedItemID: "video",
        selectedItemIDs: selected,
        primaryID: "markdown",
        visualItemIDs: visualIDs
    )
    try expect(unselectedContext.orderedItemIDs == ["video"], "right-clicking an unselected card should collapse to that card")
    try expect(unselectedContext.primaryID == "video", "the newly clicked card should become primary")
}

func testSelectionActionContextBuildsCompleteDragPayload() throws {
    let context = PromptItemSelectionActionContext.resolve(
        clickedItemID: "markdown",
        selectedItemIDs: Set(["image", "audio", "markdown"]),
        primaryID: "image",
        visualItemIDs: ["image", "audio", "markdown"]
    )
    let decoded = try PromptItemDragPayload.decode(context.dragPayload().encoded())
    try expect(decoded.itemIDs == ["image", "audio", "markdown"], "drag payload should retain every selected item in visual order")
}

func testMultiItemDragPreviewPlanKeepsDraggedItemOnTop() throws {
    let selection = (1...5).map { "item-\($0)" }
    let plan = PromptItemDragPreviewPlan(
        orderedItemIDs: selection,
        draggedItemID: "item-3"
    )
    try expect(plan.previewItemIDs == ["item-1", "item-2", "item-4", "item-5", "item-3"], "dragged item should be the topmost preview")
    try expect(plan.payloadOwnerID == "item-3", "only the dragged item should own the complete payload")
    try expect(plan.totalItemCount == 5, "preview plan should retain the real selection count")
}

func testMultiItemDragPreviewPlanCapsVisualsWithoutTruncatingPayload() throws {
    let selection = (1...13).map { "item-\($0)" }
    let plan = PromptItemDragPreviewPlan(
        orderedItemIDs: selection,
        draggedItemID: "item-13"
    )
    try expect(plan.previewItemIDs.count == 12, "drag preview should render at most twelve cards")
    try expect(plan.previewItemIDs.last == "item-13", "dragged item should remain visible and topmost beyond the cap")
    try expect(plan.completePayload.itemIDs == selection, "visual cap must not truncate the move payload")
    try expect(plan.totalItemCount == 13, "count badge should use the complete selection count")

    let single = PromptItemDragPreviewPlan(orderedItemIDs: ["only"], draggedItemID: "only")
    try expect(single.previewItemIDs == ["only"], "single selection should create exactly one preview")
}

func testFolderSelectionActionContextPreservesVisualOrderAndNormalizesNestedSelection() throws {
    let folders = [
        LibraryFolder(id: "folder-sibling", name: "Sibling", sortOrder: 0),
        LibraryFolder(id: "folder-parent", name: "Parent", sortOrder: 1),
        LibraryFolder(id: "folder-child", name: "Child", parentId: "folder-parent", sortOrder: 0)
    ]
    let selected = FolderSelectionActionContext.resolve(
        clickedFolderID: "folder-child",
        selectedFolderIDs: Set(["folder-parent", "folder-child", "folder-sibling"]),
        primaryID: "folder-child",
        visualFolderIDs: ["folder-sibling", "folder-parent", "folder-child"],
        folders: folders
    )
    try expect(selected.orderedFolderIDs == ["folder-sibling", "folder-parent"], "folder selection should preserve visual order while removing selected descendants")
    try expect(selected.primaryID == "folder-parent", "a primary child removed by parent normalization should resolve to the retained parent")

    let unselected = FolderSelectionActionContext.resolve(
        clickedFolderID: "folder-child",
        selectedFolderIDs: Set(["folder-parent", "folder-sibling"]),
        primaryID: "folder-parent",
        visualFolderIDs: folders.map(\.id),
        folders: folders
    )
    try expect(unselected.orderedFolderIDs == ["folder-child"], "clicking an unselected folder should collapse to one folder")
    try expect(unselected.primaryID == "folder-child", "an unselected clicked folder should become primary")
}

func testFolderDragPayloadRoundTripAndPreviewCap() throws {
    let payload = FolderDragPayload(folderIDs: ["folder-b", "folder-a", "folder-b", ""])
    try expect(payload.folderIDs == ["folder-b", "folder-a"], "folder drag payload should remove empty and duplicate IDs")
    try expect(FolderDragPayload.pasteboardTypeIdentifier == "com.promptstudio.internal.folder-ids", "folder drag payload should use its dedicated pasteboard type")
    try expect(FolderDragPayload.decode(payload.encoded()) == payload, "folder drag payload should round-trip through JSON")

    let unsupportedVersion = Data(#"{"version":2,"folderIDs":["folder-a"]}"#.utf8)
    do {
        _ = try FolderDragPayload.decode(unsupportedVersion)
        throw CoreUnitTestError.failure("folder drag payload should reject unsupported versions")
    } catch {
        // Expected.
    }

    let two = FolderDragPreviewPlan(orderedFolderIDs: ["folder-a", "folder-b"], draggedFolderID: "folder-b")
    try expect(two.previewFolderIDs == ["folder-a", "folder-b"] && two.totalFolderCount == 2, "two-folder preview should show both folders and the real count")

    let twelveIDs = (1...12).map { "folder-\($0)" }
    let twelve = FolderDragPreviewPlan(orderedFolderIDs: twelveIDs, draggedFolderID: "folder-6")
    try expect(twelve.previewFolderIDs.count == 12 && twelve.completePayload.folderIDs == twelveIDs, "twelve-folder preview should cap visuals without truncating payload")

    let thirteenIDs = (1...13).map { "folder-\($0)" }
    let thirteen = FolderDragPreviewPlan(orderedFolderIDs: thirteenIDs, draggedFolderID: "folder-13")
    try expect(thirteen.previewFolderIDs.count == 12 && thirteen.previewFolderIDs.last == "folder-13", "thirteen-folder preview should keep the dragged owner visible at the visual cap")
    try expect(thirteen.totalFolderCount == 13 && thirteen.payloadOwnerID == "folder-13", "folder preview count and payload owner should describe the complete drag")
}

func folderMoveFixtures() -> [LibraryFolder] {
    [
        LibraryFolder(id: "move-root", name: "Root", sortOrder: 0),
        LibraryFolder(id: "move-source", name: "Source", parentId: "move-root", sortOrder: 0),
        LibraryFolder(id: "move-source-child", name: "Child", parentId: "move-source", sortOrder: 0),
        LibraryFolder(id: "move-target", name: "Target", parentId: "move-root", sortOrder: 1),
        LibraryFolder(id: "move-existing", name: "Existing", parentId: "move-target", sortOrder: 4),
        LibraryFolder(id: "move-second", name: "Second", parentId: "move-root", sortOrder: 2)
    ]
}

func testFolderBatchMovePlannerRejectsInvalidGroupsAndPreservesLegalOrder() throws {
    let fixtures = folderMoveFixtures()
    let normalized = try FolderBatchMovePlanner.plan(
        allFolders: fixtures,
        sourceFolderIDs: ["move-source", "move-source-child"],
        targetParentID: "move-target"
    )
    try expect(normalized.sourceFolderIDs == ["move-source"], "batch planner should normalize selected parent/child overlap")
    try expect(normalized.updates.map(\.folderID) == ["move-source"], "normalized move should update only the retained top-level source")
    try expect(normalized.updates[0].parentID == "move-target" && normalized.updates[0].sortOrder == 5, "legal move should append after the target's existing child sort order")

    let legal = try FolderBatchMovePlanner.plan(
        allFolders: fixtures,
        sourceFolderIDs: ["move-second", "move-source"],
        targetParentID: "move-target"
    )
    try expect(legal.updates.map(\.folderID) == ["move-second", "move-source"], "legal batch move should keep visual source order")
    try expect(legal.updates.map(\.sortOrder) == [5, 6], "legal batch move should append each source in visual order")

    let invalidCases: [(String, [String], String?)] = [
        ("missing", ["missing-source"], "move-target"),
        ("self", ["move-source"], "move-source"),
        ("descendant", ["move-source"], "move-source-child"),
        ("already", ["move-existing"], "move-target")
    ]
    for (_, sourceIDs, targetID) in invalidCases {
        do {
            _ = try FolderBatchMovePlanner.plan(allFolders: fixtures, sourceFolderIDs: sourceIDs, targetParentID: targetID)
            throw CoreUnitTestError.failure("batch planner should reject (label) move")
        } catch is FolderBatchMoveError {
            // Expected.
        }
    }

    var duplicateFixtures = fixtures
    duplicateFixtures.append(LibraryFolder(id: "move-duplicate", name: "Source", parentId: "move-target", sortOrder: 7))
    do {
        _ = try FolderBatchMovePlanner.plan(allFolders: duplicateFixtures, sourceFolderIDs: ["move-second", "move-source"], targetParentID: "move-target")
        throw CoreUnitTestError.failure("batch planner should reject target name collisions")
    } catch FolderBatchMoveError.targetContainsSameName {
        // Expected.
    }

    do {
        _ = try FolderBatchMovePlanner.plan(allFolders: fixtures, sourceFolderIDs: ["move-second", "move-source"], targetParentID: "move-source")
        throw CoreUnitTestError.failure("mixed valid/invalid source groups should be rejected atomically")
    } catch is FolderBatchMoveError {
        // Expected.
    }
}

func testPromptRepositoryBatchFolderMoveAndDeleteRollback() throws {
    let libraryURL = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: libraryURL)
    let root = LibraryFolder(id: "repo-root", name: "Root", sortOrder: 0)
    let source = LibraryFolder(id: "repo-source", name: "Source", parentId: root.id, sortOrder: 0)
    let sourceChild = LibraryFolder(id: "repo-source-child", name: "Child", parentId: source.id, sortOrder: 0)
    let target = LibraryFolder(id: "repo-target", name: "Target", parentId: root.id, sortOrder: 1)
    let first = LibraryFolder(id: "repo-first", name: "First", parentId: root.id, sortOrder: 2)
    let second = LibraryFolder(id: "repo-second", name: "Second", parentId: root.id, sortOrder: 3)
    try repository.seedFoldersIfNeeded([root, source, sourceChild, target, first, second])

    let updates = [
        FolderParentSortUpdate(folderID: first.id, parentID: target.id, sortOrder: 3),
        FolderParentSortUpdate(folderID: second.id, parentID: target.id, sortOrder: 4)
    ]
    try repository.updateFolderParentsAndSort(updates)
    let moved = Dictionary(uniqueKeysWithValues: try repository.loadFolders().map { ($0.id, $0) })
    try expect(moved[first.id]?.parentId == target.id && moved[first.id]?.sortOrder == 3, "batch folder move should persist parent and sort updates")
    try expect(moved[second.id]?.parentId == target.id && moved[second.id]?.sortOrder == 4, "batch folder move should persist every row")

    let db = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    try db.execute(
        """
        CREATE TRIGGER abort_batch_folder_parent_update
        BEFORE UPDATE OF parentId ON library_folders
        WHEN NEW.id = 'repo-second' AND NEW.parentId = 'repo-root'
        BEGIN SELECT RAISE(ABORT, 'forced folder parent rollback'); END;
        """
    )
    var caughtError: Error?
    do {
        try repository.updateFolderParentsAndSort([
            FolderParentSortUpdate(folderID: first.id, parentID: root.id, sortOrder: 8),
            FolderParentSortUpdate(folderID: second.id, parentID: root.id, sortOrder: 9)
        ])
    } catch {
        caughtError = error
    }
    try expect(caughtError?.localizedDescription.contains("forced folder parent rollback") == true, "batch folder move should expose trigger errors")
    let rolledBack = Dictionary(uniqueKeysWithValues: try repository.loadFolders().map { ($0.id, $0) })
    try expect(rolledBack[first.id]?.parentId == target.id && rolledBack[first.id]?.sortOrder == 3, "folder move rollback should restore earlier rows")
    try expect(rolledBack[second.id]?.parentId == target.id && rolledBack[second.id]?.sortOrder == 4, "folder move rollback should retain later rows")

    var firstItem = sampleItem(title: "Source prompt", prompt: "source")
    firstItem.id = "repo-delete-item-first"
    firstItem.versions = []
    firstItem.folderId = source.id
    var childItem = sampleItem(title: "Child prompt", prompt: "child")
    childItem.id = "repo-delete-item-child"
    childItem.versions = []
    childItem.folderId = sourceChild.id
    try repository.saveItems([firstItem, childItem])
    try expect(try repository.loadTags().contains { $0.name == "风景" && $0.count == 2 }, "folder subtree fixtures should contribute to tag counts")
    let deletedAt = Date(timeIntervalSince1970: 1_700_000_000)
    try repository.deleteFolderSubtrees(sourceFolderIDs: [source.id], deletedAt: deletedAt)
    let deletedItems = Dictionary(uniqueKeysWithValues: try repository.loadItems().map { ($0.id, $0) })
    try expect(deletedItems[firstItem.id]?.deletedAt == deletedAt && deletedItems[childItem.id]?.deletedAt == deletedAt, "folder subtree deletion should mark every internal live item with one timestamp")
    try expect(try repository.loadFolders().contains { $0.id == source.id || $0.id == sourceChild.id } == false, "folder subtree deletion should remove every descendant folder")
    try expect(try repository.loadTags().contains { $0.name == "风景" } == false, "folder subtree deletion should refresh tag counts in the same transaction")

    let rollbackURL = try temporaryLibraryURL()
    let rollbackRepository = try PromptRepository(libraryURL: rollbackURL)
    let rollbackSource = LibraryFolder(id: "rollback-source", name: "Rollback", sortOrder: 0)
    let rollbackChild = LibraryFolder(id: "rollback-child", name: "Rollback child", parentId: rollbackSource.id, sortOrder: 0)
    var rollbackItemOne = sampleItem(title: "Rollback one", prompt: "one")
    rollbackItemOne.id = "rollback-folder-item-one"
    rollbackItemOne.versions = []
    rollbackItemOne.folderId = rollbackSource.id
    var rollbackItemTwo = sampleItem(title: "Rollback two", prompt: "two")
    rollbackItemTwo.id = "rollback-folder-item-two"
    rollbackItemTwo.versions = []
    rollbackItemTwo.folderId = rollbackChild.id
    try rollbackRepository.seedFoldersIfNeeded([rollbackSource, rollbackChild])
    try rollbackRepository.saveItems([rollbackItemOne, rollbackItemTwo])
    let rollbackDB = try SQLiteDatabase(path: rollbackRepository.databaseURL.path, mode: .existingReadWrite)
    try rollbackDB.execute(
        """
        CREATE TRIGGER abort_folder_subtree_delete
        BEFORE DELETE ON library_folders
        WHEN OLD.id = 'rollback-child'
        BEGIN SELECT RAISE(ABORT, 'forced folder subtree rollback'); END;
        """
    )
    var deleteError: Error?
    do {
        try rollbackRepository.deleteFolderSubtrees(sourceFolderIDs: [rollbackSource.id], deletedAt: deletedAt)
    } catch {
        deleteError = error
    }
    try expect(deleteError?.localizedDescription.contains("forced folder subtree rollback") == true, "folder subtree deletion should expose trigger errors")
    try expect(try rollbackRepository.loadFolders().count == 2, "folder subtree deletion rollback should restore every folder")
    let restoredItems = Dictionary(uniqueKeysWithValues: try rollbackRepository.loadItems().map { ($0.id, $0) })
    try expect(restoredItems[rollbackItemOne.id]?.deletedAt == nil && restoredItems[rollbackItemTwo.id]?.deletedAt == nil, "folder subtree deletion rollback should restore item deletion state")
}

func testPromptItemBatchMovePlanner() throws {
    let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    var first = sampleItem(title: "First", assetKind: .image, prompt: "first")
    first.id = "first"
    first.folderId = "source"
    first.folderName = "Source"

    var second = sampleItem(title: "Second", assetKind: .markdown, prompt: "second")
    second.id = "second"
    second.folderId = "source"
    second.folderName = "Source"

    var already = sampleItem(title: "Already", assetKind: .video, prompt: "already")
    already.id = "already"
    already.folderId = "target"
    already.folderName = "Target"

    var deleted = sampleItem(title: "Deleted", assetKind: .audio, prompt: "deleted")
    deleted.id = "deleted"
    deleted.deletedAt = fixedDate

    let plan = PromptItemBatchMovePlanner.plan(
        items: [first, second, already, deleted],
        requestedIDs: ["missing", "second", "already", "first", "deleted", "second", "missing"],
        targetFolderID: "target",
        targetFolderName: "Target",
        updatedAt: fixedDate
    )

    try expect(plan.updatedItems.map(\.id) == ["second", "first"], "planner should deduplicate requests and preserve their requested order")
    try expect(plan.updatedItems[1].folderId == "target", "planner should assign the target folder ID")
    try expect(plan.updatedItems[1].folderName == "Target", "planner should assign the target folder name")
    try expect(plan.updatedItems[1].category == first.assetKind.displayName, "planner should derive category from asset kind")
    try expect(plan.updatedItems[1].updatedAt == fixedDate, "planner should use the supplied update date")
    try expect(plan.unchangedIDs == ["already"], "planner should report items already in the target")
    try expect(plan.ignoredIDs == ["missing", "deleted"], "planner should report ignored IDs in requested order")
}

func testPromptRepositoryBatchFolderUpdateRollsBack() throws {
    let libraryURL = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: libraryURL)
    var first = sampleItem(title: "First", prompt: "first")
    first.id = "rollback-first"
    first.folderId = "source"
    first.folderName = "Source"
    first.versions = []
    var second = sampleItem(title: "Second", prompt: "second")
    second.id = "rollback-second"
    second.folderId = "source"
    second.folderName = "Source"
    second.versions = []
    try repository.saveItems([first, second])

    let databaseURL = libraryURL.appendingPathComponent("database/promptstudio.sqlite")
    let database = try SQLiteDatabase(path: databaseURL.path, mode: .existingReadWrite)
    try database.execute(
        """
        CREATE TRIGGER abort_batch_folder_update
        BEFORE UPDATE OF folderId ON prompt_items
        WHEN NEW.id = 'rollback-second' AND NEW.folderId = 'target'
        BEGIN
            SELECT RAISE(ABORT, 'forced folder rollback');
        END;
        """
    )

    first.folderId = "target"
    first.folderName = "Target"
    second.folderId = "target"
    second.folderName = "Target"
    var caughtError: Error?
    do {
        try repository.updateItemFolders([first, second])
    } catch {
        caughtError = error
    }
    try expect(caughtError?.localizedDescription.contains("forced folder rollback") == true, "batch folder update should expose the trigger error")

    let reloaded = Dictionary(uniqueKeysWithValues: try repository.loadItems().map { ($0.id, $0) })
    try expect(reloaded["rollback-first"]?.folderId == "source", "batch rollback should restore the first item")
    try expect(reloaded["rollback-second"]?.folderId == "source", "batch rollback should retain the second item")
}

func testPromptRepositoryBatchDeletedStateRollsBack() throws {
    let libraryURL = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: libraryURL)
    var first = sampleItem(title: "First", prompt: "first")
    first.id = "delete-rollback-first"
    first.versions = []
    var second = sampleItem(title: "Second", prompt: "second")
    second.id = "delete-rollback-second"
    second.versions = []
    try repository.saveItems([first, second])

    let databaseURL = libraryURL.appendingPathComponent("database/promptstudio.sqlite")
    let database = try SQLiteDatabase(path: databaseURL.path, mode: .existingReadWrite)
    try database.execute(
        """
        CREATE TRIGGER abort_batch_delete_update
        BEFORE UPDATE OF deletedAt ON prompt_items
        WHEN NEW.id = 'delete-rollback-second' AND NEW.deletedAt IS NOT NULL
        BEGIN
            SELECT RAISE(ABORT, 'forced delete rollback');
        END;
        """
    )

    var caughtError: Error?
    do {
        try repository.markDeleted(itemIDs: [first.id, second.id], deletedAt: Date())
    } catch {
        caughtError = error
    }
    try expect(caughtError?.localizedDescription.contains("forced delete rollback") == true, "batch delete should expose the trigger error")

    let reloaded = Dictionary(uniqueKeysWithValues: try repository.loadItems().map { ($0.id, $0) })
    try expect(reloaded[first.id]?.deletedAt == nil, "batch rollback should restore the first deleted state")
    try expect(reloaded[second.id]?.deletedAt == nil, "batch rollback should retain the second deleted state")
}

func testPromptRepositoryBatchPermanentDeleteRollsBack() throws {
    let libraryURL = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: libraryURL)
    var first = sampleItem(title: "First", prompt: "first")
    first.id = "permanent-rollback-first"
    first.versions = []
    var second = sampleItem(title: "Second", prompt: "second")
    second.id = "permanent-rollback-second"
    second.versions = []
    try repository.saveItems([first, second])

    let databaseURL = libraryURL.appendingPathComponent("database/promptstudio.sqlite")
    let database = try SQLiteDatabase(path: databaseURL.path, mode: .existingReadWrite)
    try database.execute(
        """
        CREATE TRIGGER abort_batch_permanent_delete
        BEFORE DELETE ON prompt_items
        WHEN OLD.id = 'permanent-rollback-second'
        BEGIN
            SELECT RAISE(ABORT, 'forced permanent delete rollback');
        END;
        """
    )

    var caughtError: Error?
    do {
        try repository.permanentlyDelete(itemIDs: [first.id, second.id])
    } catch {
        caughtError = error
    }
    try expect(caughtError?.localizedDescription.contains("forced permanent delete rollback") == true, "batch permanent delete should expose the trigger error")

    let reloadedIDs = Set(try repository.loadItems().map(\.id))
    try expect(reloadedIDs.contains(first.id), "batch rollback should restore the first permanently deleted row")
    try expect(reloadedIDs.contains(second.id), "batch rollback should retain the second permanently deleted row")
}

func testPromptRepositoryFolderUpdatePreservesVersions() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    var first = sampleItem(title: "First", prompt: "first")
    first.id = "versions-first"
    first.versions = [PromptVersion(promptItemId: first.id, version: "V1.0", prompt: "first version")]
    var second = sampleItem(title: "Second", prompt: "second")
    second.id = "versions-second"
    second.versions = [
        PromptVersion(promptItemId: second.id, version: "V1.0", prompt: "second version"),
        PromptVersion(promptItemId: second.id, version: "V1.1", prompt: "second revised version")
    ]
    try repository.saveItems([first, second])
    let expectedVersions = Dictionary(uniqueKeysWithValues: try repository.loadItems().map { ($0.id, $0.versions) })

    first.folderId = "target"
    first.folderName = "Target"
    second.folderId = "target"
    second.folderName = "Target"
    try repository.updateItemFolders([first, second])

    let reloaded = Dictionary(uniqueKeysWithValues: try repository.loadItems().map { ($0.id, $0) })
    try expect(reloaded["versions-first"]?.versions == expectedVersions["versions-first"], "folder updates should preserve the first item's versions")
    try expect(reloaded["versions-second"]?.versions == expectedVersions["versions-second"], "folder updates should preserve the second item's versions")
}

func testPromptRepositoryBatchFolderUpdatePerformanceWith1000Items() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let items = (0..<1_000).map { index -> PromptItem in
        var item = performanceItem(index: index)
        item.deletedAt = nil
        return item
    }
    try repository.saveItems(items)
    let movedItems = items.map { item -> PromptItem in
        var moved = item
        moved.folderId = "target"
        moved.folderName = "Target"
        moved.category = moved.assetKind.displayName
        moved.updatedAt = Date()
        return moved
    }

    let duration = try measurePerformance("1000-item batch folder update", threshold: 1.5) {
        try repository.updateItemFolders(movedItems)
    }
    print("1000-item batch folder update: \(String(format: "%.3f", duration))s")

    let movedIDs = Set(try repository.loadItems().filter { $0.folderId == "target" }.map(\.id))
    try expect(movedIDs == Set(items.map(\.id)), "batch folder update should move every item")
}

func testFilteringPerformanceWith1000Items() throws {
    let items = (0..<1_000).map(performanceItem(index:))
    let target = try expect(items.first { $0.title == "Forest Product Shot" } != nil, "performance fixture should include target")

    var queryResults: [PromptItem] = []
    var tagResults: [PromptItem] = []
    var folderResults: [PromptItem] = []
    var modelResults: [PromptItem] = []
    var favoriteResults: [PromptItem] = []
    var combinedResults: [PromptItem] = []

    try measurePerformance("1000-item filtering smoke", threshold: 0.5) {
        queryResults = PromptFiltering.apply(items, filter: PromptFilter(query: "needle-forest-target"))
        tagResults = PromptFiltering.apply(items, filter: PromptFilter(collection: .tag("tag-7")))
        folderResults = PromptFiltering.apply(items, filter: PromptFilter(collection: .folder("folder-0")))
        modelResults = PromptFiltering.apply(items, filter: PromptFilter(modelId: "model-3"))
        favoriteResults = PromptFiltering.apply(items, filter: PromptFilter(favoriteOnly: true))
        combinedResults = PromptFiltering.apply(
            items,
            filter: PromptFilter(
                query: "needle-forest-target",
                modelId: "model-0",
                collection: .folder("folder-0"),
                requiredTag: "tag-0",
                favoriteOnly: true,
                hasPromptOnly: true
            )
        )
    }

    _ = target
    try expect(queryResults.map(\.title) == ["Forest Product Shot"], "query should find the unique target prompt")
    try expect(tagResults.allSatisfy { $0.tags.contains("tag-7") && !$0.isDeleted }, "tag filter should return live tag matches")
    try expect(folderResults.allSatisfy { $0.folderId == "folder-0" && !$0.isDeleted }, "folder filter should return live folder matches")
    try expect(modelResults.allSatisfy { $0.modelId == "model-3" && !$0.isDeleted }, "model filter should return live model matches")
    try expect(favoriteResults.allSatisfy { $0.favorite && !$0.isDeleted }, "favorite filter should return live favorites")
    try expect(combinedResults.map(\.title) == ["Forest Product Shot"], "combined filters should keep the target prompt")
}

func testTextFormatFiltering() throws {
    let markdown = sampleItem(title: "Markdown", assetKind: .markdown, prompt: "# doc", assetPath: "/tmp/mock.md", format: "MD")
    let json = sampleItem(title: "Json", assetKind: .json, prompt: "{}", assetPath: "/tmp/mock.json", format: "JSON")
    let text = sampleItem(title: "Text", assetKind: .text, prompt: "notes", assetPath: "/tmp/mock.txt", format: "TXT")
    let word = sampleItem(title: "Word", assetKind: .document, prompt: "doc", assetPath: "/tmp/mock.docx", format: "DOCX")
    let staleWord = sampleItem(title: "Old Word", assetKind: .unknown, prompt: "doc", assetPath: "/tmp/old.docx", format: "FILE")
    let pdf = sampleItem(title: "PDF", assetKind: .document, prompt: "pdf", assetPath: "/tmp/mock.pdf", format: "PDF")

    try expect(PromptFiltering.apply([markdown, json, text, word], filter: PromptFilter(type: .text, textFormat: .markdown)).map(\.id) == [markdown.id], "MD filter should isolate markdown assets")
    try expect(PromptFiltering.apply([markdown, json, text, word], filter: PromptFilter(type: .text, textFormat: .json)).map(\.id) == [json.id], "Json filter should isolate JSON assets")
    try expect(PromptFiltering.apply([markdown, json, text, word], filter: PromptFilter(type: .text, textFormat: .text)).map(\.id) == [text.id], "txt filter should isolate text assets")
    let wordMatches = Set(PromptFiltering.apply([markdown, json, text, word, staleWord], filter: PromptFilter(type: .text, textFormat: .word)).map(\.id))
    try expect(wordMatches == Set([word.id, staleWord.id]), "Word filter should isolate doc/docx assets")
    try expect(word.isTextDocumentLike, "Word documents should use text document presentation")
    try expect(staleWord.isTextDocumentLike, "Old docx items should use text document presentation by file extension")
    try expect(!pdf.isTextDocumentLike, "PDF documents should stay generic document assets")
}

func testPrimaryPromptAssetsAndAttachments() throws {
    let image = sampleItem(title: "Image", assetKind: .image, prompt: "image", assetPath: "/tmp/mock.png", format: "PNG")
    let video = sampleItem(title: "Video", assetKind: .video, prompt: "video", assetPath: "/tmp/mock.mp4", format: "MP4")
    let audio = sampleItem(title: "Audio", assetKind: .audio, prompt: "audio", assetPath: "/tmp/mock.mp3", format: "MP3")
    let markdown = sampleItem(title: "Markdown", assetKind: .markdown, prompt: "# doc", assetPath: "/tmp/mock.md", format: "MD")
    let word = sampleItem(title: "Word", assetKind: .document, prompt: "doc", assetPath: "/tmp/mock.docx", format: "DOCX")
    let source = sampleItem(title: "PSD", assetKind: .source, prompt: "", assetPath: "/tmp/mock.psd", format: "PSD")
    let web = sampleItem(title: "HTML", assetKind: .web, prompt: "", assetPath: "/tmp/mock.html", format: "HTML")
    let pdf = sampleItem(title: "PDF", assetKind: .document, prompt: "", assetPath: "/tmp/mock.pdf", format: "PDF")
    let raw = sampleItem(title: "RAW", assetKind: .raw, prompt: "", assetPath: "/tmp/mock.dng", format: "DNG")
    let font = sampleItem(title: "Font", assetKind: .font, prompt: "", assetPath: "/tmp/mock.otf", format: "OTF")
    let unknown = sampleItem(title: "Unknown", assetKind: .unknown, prompt: "", assetPath: "/tmp/mock.custom", format: "CUSTOM")

    try expect([image, video, audio, markdown, word].allSatisfy(\.isPromptPrimaryAsset), "image, video, audio, and text documents should be primary prompt assets")
    try expect([source, web, pdf, raw, font, unknown].allSatisfy(\.isAttachmentAsset), "non-primary formats should be attachments")

    let items = [image, video, audio, markdown, word, source, web, pdf, raw, font, unknown]
    let audioMatches = PromptFiltering.apply(items, filter: PromptFilter(assetKindFilter: .audio)).map(\.id)
    try expect(audioMatches == [audio.id], "audio filter should isolate audio prompt assets")
    let audioTypeMatches = PromptFiltering.apply(items, filter: PromptFilter(type: .audio)).map(\.id)
    try expect(audioTypeMatches == [audio.id], "audio prompt type should isolate imported audio assets")
    let documentMatches = Set(PromptFiltering.apply(items, filter: PromptFilter(assetKindFilter: .promptDocument)).map(\.id))
    try expect(documentMatches == Set([markdown.id, word.id]), "text filter should isolate text prompt documents")
    let attachmentMatches = Set(PromptFiltering.apply(items, filter: PromptFilter(assetKindFilter: .other)).map(\.id))
    try expect(attachmentMatches == Set([source.id, web.id, pdf.id, raw.id, font.id, unknown.id]), "attachment filter should include non-primary formats")
}

func testTextSyntaxModeInference() throws {
    let staleJson = sampleItem(title: "Old JSON", assetKind: .unknown, prompt: "{}", assetPath: "/tmp/handoff.json", format: "FILE")
    try expect(staleJson.isTextDocumentLike, "Old JSON items should use text document presentation by file extension")
    try expect(TextSyntaxMode.infer(for: staleJson) == .json, "JSON path should infer JSON syntax even when assetKind is stale")

    let expectations: [(String, TextSyntaxMode)] = [
        ("/tmp/mock.md", .markdown),
        ("/tmp/mock.yaml", .yamlToml),
        ("/tmp/mock.toml", .yamlToml),
        ("/tmp/mock.xml", .xml),
        ("/tmp/mock.log", .log),
        ("/tmp/mock.txt", .plain),
        ("/tmp/mock.swift", .source)
    ]
    for (path, mode) in expectations {
        try expect(TextSyntaxMode.infer(assetPath: path, format: "", assetKind: .unknown) == mode, "\(path) should infer \(mode.rawValue) syntax")
    }
}

func testTextSyntaxRulesDetectJSONTokens() throws {
    let json = #"{"name":"Ada","count":3,"enabled":true,"missing":null}"#
    let tokens = TextSyntaxRules.tokenKinds(in: json, mode: .json)
    try expect(tokens.contains(.jsonKey), "JSON highlighter should detect object keys")
    try expect(tokens.contains(.number), "JSON highlighter should detect numbers")
    try expect(tokens.contains(.literal), "JSON highlighter should detect booleans and null")
    try expect(tokens.contains(.punctuation), "JSON highlighter should detect punctuation")
    try expect(!tokens.contains(.string), "JSON highlighter should keep string values as base text to avoid large color blocks")
}

func testMarkdownHeadingRulesDetectCommonTitleShapes() throws {
    let headingSamples = [
        "# 标题",
        "## 标题",
        "Setext 标题\n---",
        "【基础设定】",
        "《角色设定》",
        "「镜头规则」",
        "一、测试目标",
        "1. 测试目标",
        "01. 开场成品",
        "Step 1: 准备",
        "测试目标：",
        "角色设定:",
        "质量检查",
        "成品主参照帧说明"
    ]

    for sample in headingSamples {
        let tokens = TextSyntaxRules.tokenKinds(in: sample, mode: .markdown)
        try expect(tokens.contains(.heading), "\(sample) should be highlighted as a markdown heading")
    }
}

func testMarkdownHeadingRulesAvoidBodyLikeLines() throws {
    let bodySamples = [
        "- 质量检查",
        "* 质量检查",
        "+ 质量检查",
        "> 质量检查",
        "| 项目 | 内容 |",
        "我希望画面不要出现水印。"
    ]

    for sample in bodySamples {
        let tokens = TextSyntaxRules.tokenKinds(in: sample, mode: .markdown)
        try expect(!tokens.contains(.heading), "\(sample) should not be highlighted as a markdown heading")
    }
}

func testLargeMarkdownKeepsHeadingHighlightRules() throws {
    let largeMarkdown = "【基础设定】\n" + String(repeating: "正文内容\n", count: TextSyntaxRules.largeTextLineLimit + 5)
    let tokens = TextSyntaxRules.tokenKinds(in: largeMarkdown, mode: .markdown)
    try expect(tokens.contains(.heading), "large markdown should still highlight headings")
}

func testMarkdownNegativeHighlightRequiresTitle() throws {
    let titleTokens = TextSyntaxRules.tokenKinds(in: "## 负面提示\n不要出现水印", mode: .markdown)
    try expect(titleTokens.contains(.negativeConstraint), "negative heading should be highlighted")
    try expect(titleTokens.contains(.heading), "negative markdown title can still match heading before red override")

    let suffixedTitleTokens = TextSyntaxRules.tokenKinds(in: "## 负面约束规则\n无字幕、无水印", mode: .markdown)
    try expect(suffixedTitleTokens.contains(.negativeConstraint), "negative heading with title suffix should be highlighted")

    let bodyTokens = TextSyntaxRules.tokenKinds(in: "画面不要出现水印，保持干净。", mode: .markdown)
    try expect(!bodyTokens.contains(.negativeConstraint), "body text containing 不要 should not be highlighted as negative")

    let bodyLabelTokens = TextSyntaxRules.tokenKinds(in: "这里是负面提示内容，不要大面积标红。", mode: .markdown)
    try expect(!bodyLabelTokens.contains(.negativeConstraint), "body text mentioning negative prompt should not be highlighted as a heading")

    let reverseTitleTokens = TextSyntaxRules.tokenKinds(in: "反向约束：", mode: .markdown)
    try expect(reverseTitleTokens.contains(.negativeConstraint), "reverse constraint title should be highlighted")
}

func testFolderFilteringUsesStableFolderID() throws {
    var first = sampleItem(title: "同名文件夹 A", prompt: "first")
    var second = sampleItem(title: "同名文件夹 B", prompt: "second")
    first.folderId = "folder-a"
    first.folderName = "同名文件夹"
    second.folderId = "folder-b"
    second.folderName = "同名文件夹"

    let filtered = PromptFiltering.apply([first, second], filter: PromptFilter(collection: .folder("folder-b")))
    try expect(filtered.map(\.id) == [second.id], "folder filtering should use folderId rather than folderName")
}

func testSQLiteRoundTrip() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let item = sampleItem(title: "版本测试", assetKind: .markdown, prompt: "initial prompt", width: 0, height: 0, assetPath: "/tmp/mock.md")

    try repository.saveItem(item)
    var loaded = try repository.loadItems()
    try expect(loaded.count == 1, "repository should load one saved item")
    try expect(loaded[0].versions.first?.prompt == "initial prompt", "initial version should persist")
    try expect(loaded[0].assetKind == .markdown, "assetKind should persist")
    try expect(loaded[0].folderId == "folder-promptstudio", "folderId should persist")

    loaded[0].versions.append(PromptVersion(promptItemId: loaded[0].id, version: "V1.1", prompt: "updated prompt", note: "edit"))
    try repository.saveItem(loaded[0])

    let reloaded = try repository.loadItems()
    try expect(reloaded[0].versions.count == 2, "new version should persist")
    try expect(reloaded[0].currentVersion?.prompt == "updated prompt", "current version should be latest")
}

func testRepositoryBulkSaveLoadPerformanceWith1000Items() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let items = (0..<1_000).map(performanceItem(index:))
    var loaded: [PromptItem] = []

    try measurePerformance("1000-item repository bulk save and load smoke", threshold: 5.0) {
        try repository.saveItems(items)
        loaded = try repository.loadItems()
    }

    try expect(loaded.count == 1_000, "repository should load every saved performance item")
    let target = try expect(loaded.first { $0.title == "Forest Product Shot" } != nil, "loaded repository should include target")
    _ = target
    let sample = try expect(loaded.first { $0.modelId == "model-3" && $0.tags.contains("tag-3") } != nil, "loaded repository should include sample metadata")
    _ = sample
    try expect(loaded.first { $0.title == "Forest Product Shot" }?.currentVersion?.prompt.contains("needle-forest-target") == true, "loaded target should keep prompt versions")
}

func testAssetKindInferenceAndPromptParsing() throws {
    try expect(AssetKind.infer(fileExtension: "mp3") == .audio, "mp3 should import as audio")
    try expect(AssetKind.infer(fileExtension: "mp3").promptType == .audio, "mp3 should import as audio prompt type")
    try expect(AssetKind.infer(fileExtension: "pdf") == .document, "pdf should import as document")
    let parsed = PromptImportParser.parse(
        text: "Prompt: forest portrait --no watermark --ar 3:4\nTags: 风景, 人物\n#写实",
        assetKind: .text
    )
    try expect(parsed.prompt == "forest portrait", "parser should remove Midjourney parameters from prompt")
    try expect(parsed.negativePrompt == "watermark", "parser should read --no as negative prompt")
    try expect(parsed.parameters["ar"] == "3:4", "parser should extract ar parameter")
    try expect(parsed.tags.contains("风景") && parsed.tags.contains("人物") && parsed.tags.contains("写实"), "parser should extract tags")
}

func testAssetFormatCatalogCoversEagleMacOSFormats() throws {
    for ext in AssetFormatCatalog.eagleMacOSExtensions {
        let support = AssetFormatCatalog.support(forFileExtension: ext)
        try expect(support.assetKind != .unknown, "Eagle macOS extension \(ext) should have asset kind support")
        try expect(support.previewMode != .generic, "Eagle macOS extension \(ext) should have a specific preview mode")
    }
}

func testAssetFormatCatalogRepresentativeMappings() throws {
    let expectations: [(String, AssetKind, AssetSupportTier, AssetPreviewMode)] = [
        ("png", .image, .p0Native, .image),
        ("mov", .video, .p0Native, .video),
        ("mp3", .audio, .p1System, .audio),
        ("md", .markdown, .p0Native, .textDocument),
        ("json", .json, .p0Native, .textDocument),
        ("yaml", .data, .p0Native, .textDocument),
        ("docx", .document, .p0Native, .textDocument),
        ("pdf", .document, .p0Native, .document),
        ("key", .document, .p1System, .document),
        ("html", .web, .p1System, .document),
        ("psd", .source, .p2Reference, .reference),
        ("raw", .raw, .p2Reference, .reference),
        ("glb", .threeD, .p2Reference, .reference),
        ("dds", .texture, .p2Reference, .reference),
        ("ttf", .font, .p2Reference, .reference)
    ]

    for (ext, kind, tier, previewMode) in expectations {
        let support = AssetFormatCatalog.support(forFileExtension: ext)
        try expect(support.assetKind == kind, "\(ext) should map to \(kind.rawValue)")
        try expect(support.supportTier == tier, "\(ext) should map to \(tier.rawValue)")
        try expect(support.previewMode == previewMode, "\(ext) should map to \(previewMode.rawValue)")
    }

    let unknown = AssetFormatCatalog.support(forFileExtension: "madeup")
    try expect(unknown.assetKind == .unknown, "unknown extension should keep unknown kind")
    try expect(unknown.previewMode == .generic, "unknown extension should use generic preview")
}

func testPromptDocumentFormatsExtractMetadata() throws {
    for ext in AssetFormatCatalog.promptDocumentExtensions {
        let support = AssetFormatCatalog.support(forFileExtension: ext)
        try expect(support.canExtractPrompt, "\(ext) should be marked for prompt extraction")
        let parsed = PromptImportParser.parse(
            text: "Prompt: product photo --no watermark --ar 1:1\nTags: 产品, 写实",
            assetKind: support.assetKind
        )
        try expect(parsed.prompt == "product photo", "\(ext) should parse prompt")
        try expect(parsed.negativePrompt == "watermark", "\(ext) should parse negative prompt")
        try expect(parsed.parameters["ar"] == "1:1", "\(ext) should parse parameters")
        try expect(parsed.tags.contains("产品") && parsed.tags.contains("写实"), "\(ext) should parse tags")
    }
}

func testAutomationServiceImportsAllKnownFormatFixtures() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let service = PromptStudioAutomationService(repository: repository)
    let fixtureRoot = try temporaryLibraryURL().appendingPathComponent("fixtures")
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)

    var paths: [String] = []
    for ext in AssetFormatCatalog.allKnownExtensions {
        let url = fixtureRoot.appendingPathComponent(UUID().uuidString + ".\(ext)")
        let support = AssetFormatCatalog.support(forFileExtension: ext)
        let text = support.canExtractPrompt
            ? "Prompt: fixture prompt --no bad\nTags: 测试\n"
            : "fixture"
        try Data(text.utf8).write(to: url)
        paths.append(url.path)
    }

    let imported = try service.importFiles(paths: paths)
    try expect(imported.count == paths.count, "all known fixture extensions should import")
    for item in imported {
        let support = AssetFormatCatalog.support(forFileExtension: (item.assetPath as NSString).pathExtension)
        try expect(item.assetKind == support.assetKind, "\(item.format) should persist catalog asset kind")
        if support.canExtractPrompt {
            try expect(item.currentVersion?.prompt == "fixture prompt", "\(item.format) should parse fixture prompt")
        }
    }

    let source = imported.first { $0.assetKind == .source }
    let raw = imported.first { $0.assetKind == .raw }
    let threeD = imported.first { $0.assetKind == .threeD }
    let texture = imported.first { $0.assetKind == .texture }
    let font = imported.first { $0.assetKind == .font }
    let web = imported.first { $0.assetKind == .web }
    try expect(source?.assetPath.contains("/assets/sources/") == true, "source files should archive under assets/sources")
    try expect(raw?.assetPath.contains("/assets/raw/") == true, "RAW files should archive under assets/raw")
    try expect(threeD?.assetPath.contains("/assets/three_d/") == true, "3D files should archive under assets/three_d")
    try expect(texture?.assetPath.contains("/assets/textures/") == true, "texture files should archive under assets/textures")
    try expect(font?.assetPath.contains("/assets/fonts/") == true, "font files should archive under assets/fonts")
    try expect(web?.assetPath.contains("/assets/web/") == true, "web files should archive under assets/web")
}

func testUnknownFormatImportsAsGenericFile() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let service = PromptStudioAutomationService(repository: repository)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".madeup")
    try Data("fixture".utf8).write(to: file)

    let imported = try service.importFiles(paths: [file.path])
    try expect(imported.count == 1, "unknown extension should still import")
    try expect(imported[0].assetKind == .unknown, "unknown extension should keep unknown asset kind")
    try expect(imported[0].previewMode == .generic, "unknown extension should use generic preview mode")
}

func testTagRefreshDeletesUnusedTags() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    var item = sampleItem(title: "标签同步", tags: ["旧标签"], prompt: "tag")
    try repository.saveItem(item)
    try expect(try repository.loadTags().map(\.name) == ["旧标签"], "initial tag should persist")
    item.tags = ["新标签"]
    try repository.saveItem(item)
    try expect(try repository.loadTags().map(\.name) == ["新标签"], "unused tag should be removed")
}

func testTrashAndRestore() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let item = sampleItem(title: "待删除", prompt: "delete me")
    try repository.saveItem(item)

    try repository.markDeleted(itemID: item.id, deletedAt: Date())
    try expect(try repository.loadItems()[0].isDeleted, "deleted item should enter trash")

    try repository.markDeleted(itemID: item.id, deletedAt: nil)
    try expect(try repository.loadItems()[0].isDeleted == false, "restored item should leave trash")
}

func testAspectRatioDisplayNormalizesImportedSizes() throws {
    let item = sampleItem(title: "方图", prompt: "square", aspectRatio: "2048:2048", width: 2048, height: 2048)
    try expect(item.displayAspectRatio == "1:1", "square imported dimensions should display as 1:1")
}

func testSeedAssetRepairKeepsExistingUserData() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let seedAsset = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    try Data([1, 2, 3]).write(to: seedAsset)

    let broken = sampleItem(title: "内置示例", modelId: "seedream_7", prompt: "broken", assetPath: "/missing/asset.png")
    let seed = sampleItem(title: "内置示例", modelId: "seedream_7", prompt: "seed", width: 1024, height: 1024, assetPath: seedAsset.path)
    let userItem = sampleItem(title: "用户导入", modelId: "seedream_7", prompt: "user", assetPath: "/missing/user.png")

    try repository.saveItem(broken)
    try repository.saveItem(userItem)
    try repository.repairSeedAssetPaths(from: [seed])

    let loaded = try repository.loadItems()
    try expect(loaded.first { $0.id == broken.id }?.assetPath == seedAsset.path, "seed item should be repaired")
    try expect(loaded.first { $0.id == userItem.id }?.assetPath == "/missing/user.png", "non-seed user item should not be rewritten")
}

func testThumbnailPathUpdatePersistsWithoutChangingOriginalAsset() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let item = sampleItem(title: "缩略图测试", prompt: "thumbnail", assetPath: "/tmp/original.png")
    let thumbnailPath = repository.libraryURL.appendingPathComponent("thumbnails").appendingPathComponent(item.id + ".jpg").path

    try repository.saveItem(item)
    try repository.updateThumbnailPath(itemID: item.id, thumbnailPath: thumbnailPath)

    let loaded = try repository.loadItems()[0]
    try expect(loaded.assetPath == "/tmp/original.png", "thumbnail update should not alter original asset path")
    try expect(loaded.thumbnailPath == thumbnailPath, "thumbnail path should persist")
}

func testLastUsedUpdatePersistsForRecentSorting() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let older = sampleItem(title: "较早", prompt: "older")
    let newer = sampleItem(title: "较新", prompt: "newer")
    try repository.saveItem(older)
    try repository.saveItem(newer)

    let date = Date().addingTimeInterval(3_600)
    try repository.updateLastUsed(itemID: older.id, at: date)

    let recent = PromptFiltering.apply(try repository.loadItems(), filter: PromptFilter(collection: .recent))
    try expect(recent.first?.id == older.id, "updated lastUsedAt should drive recent sorting")
}

func testPinnedAtDoesNotAffectNormalCollectionSorting() throws {
    var first = sampleItem(title: "普通靠前", assetKind: .markdown, tags: ["置顶测试"], prompt: "first")
    var pinned = sampleItem(title: "置顶靠后", assetKind: .markdown, tags: ["置顶测试"], prompt: "pinned")
    first.sortOrder = 0
    pinned.sortOrder = 20
    pinned.pinnedAt = Date()

    let all = PromptFiltering.apply([first, pinned], filter: PromptFilter())
    try expect(all.map(\.id) == [first.id, pinned.id], "pinnedAt should not affect all item sorting while pinning is disabled")

    let text = PromptFiltering.apply([first, pinned], filter: PromptFilter(assetKindFilter: .promptDocument))
    try expect(text.map(\.id) == [first.id, pinned.id], "pinnedAt should not affect text filter sorting while pinning is disabled")

    let tag = PromptFiltering.apply([first, pinned], filter: PromptFilter(collection: .tag("置顶测试")))
    try expect(tag.map(\.id) == [first.id, pinned.id], "pinnedAt should not affect tag sorting while pinning is disabled")
}

func testPinnedAtDoesNotAffectRecentOrTrashSorting() throws {
    var pinnedOlder = sampleItem(title: "置顶较早", prompt: "pinned")
    var normalNewer = sampleItem(title: "普通较新", prompt: "newer")
    pinnedOlder.pinnedAt = Date()
    pinnedOlder.lastUsedAt = Date(timeIntervalSince1970: 100)
    normalNewer.lastUsedAt = Date(timeIntervalSince1970: 200)

    let recent = PromptFiltering.apply([normalNewer, pinnedOlder], filter: PromptFilter(collection: .recent))
    try expect(recent.map(\.id) == [normalNewer.id, pinnedOlder.id], "pinnedAt should not override recent sorting while pinning is disabled")

    pinnedOlder.deletedAt = Date()
    normalNewer.deletedAt = Date()
    pinnedOlder.sortOrder = 20
    normalNewer.sortOrder = 0
    let trash = PromptFiltering.apply([pinnedOlder, normalNewer], filter: PromptFilter(collection: .trash))
    try expect(trash.map(\.id) == [normalNewer.id, pinnedOlder.id], "trash sorting should ignore pinned state")
}

func testPinnedAtPersistsAndMigratesFromOldSchema() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    var item = sampleItem(title: "置顶持久化", prompt: "pin")
    let pinnedAt = Date(timeIntervalSince1970: 1_700_000_000)
    item.pinnedAt = pinnedAt
    try repository.saveItem(item)
    try expect(try repository.loadItems()[0].pinnedAt != nil, "pinnedAt should persist through repository save/load")

    let oldLibraryURL = try temporaryLibraryURL()
    try PromptRepository.createLibraryDirectories(at: oldLibraryURL)
    let databaseURL = oldLibraryURL.appendingPathComponent("database/promptstudio.sqlite")
    let database = try SQLiteDatabase(path: databaseURL.path)
    try database.execute(
        """
        CREATE TABLE prompt_items (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            type TEXT NOT NULL,
            assetKind TEXT NOT NULL DEFAULT 'image',
            modelId TEXT NOT NULL,
            modelName TEXT NOT NULL,
            folderId TEXT NOT NULL DEFAULT '',
            folderName TEXT NOT NULL,
            category TEXT NOT NULL,
            assetPath TEXT NOT NULL,
            thumbnailPath TEXT NOT NULL,
            aspectRatio TEXT NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            format TEXT NOT NULL,
            fileSize INTEGER NOT NULL,
            favorite INTEGER NOT NULL,
            deletedAt TEXT,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL,
            lastUsedAt TEXT NOT NULL,
            sortOrder INTEGER NOT NULL DEFAULT 0,
            tagsJSON TEXT NOT NULL,
            referencesJSON TEXT NOT NULL,
            description TEXT NOT NULL
        );
        CREATE TABLE prompt_versions (
            id TEXT PRIMARY KEY,
            promptItemId TEXT NOT NULL,
            version TEXT NOT NULL,
            prompt TEXT NOT NULL,
            negativePrompt TEXT NOT NULL,
            parametersJSON TEXT NOT NULL,
            note TEXT NOT NULL,
            createdAt TEXT NOT NULL
        );
        """
    )

    let migratedRepository = try PromptRepository(libraryURL: oldLibraryURL)
    let columns = try SQLiteDatabase(path: databaseURL.path).query("PRAGMA table_info(prompt_items);")
    let columnNames = Set(columns.compactMap { $0["name"] ?? nil })
    try expect(columnNames.contains("pinnedAt"), "migration should add pinnedAt column to old prompt_items table")
    try expect(try migratedRepository.loadItems().isEmpty, "old empty database should still load after pinnedAt migration")
}

func testWebCaptureCoreContracts() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let service = PromptStudioAutomationService(repository: repository)
    let candidate = WebCaptureCandidate(
        captureID: "capture-contract-1",
        selectedText: "   🌲   Forest   prompt   \nsecond line",
        pageTitle: "Example page",
        pageURL: "https://example.test/articles/forest",
        siteName: "Example",
        clickScreenPoint: WebCapturePoint(x: 120.5, y: 88.25),
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let isoEncoder = JSONEncoder()
    isoEncoder.dateEncodingStrategy = .iso8601
    let isoDecoder = JSONDecoder()
    isoDecoder.dateDecodingStrategy = .iso8601
    let encoded = try isoEncoder.encode(candidate)
    let decoded = try isoDecoder.decode(WebCaptureCandidate.self, from: encoded)
    try expect(decoded == candidate, "web capture candidates should round-trip through Codable")
    try expect(String(data: encoded, encoding: .utf8)?.contains("2023-11-14") == true, "capture timestamps should use ISO-8601 on the browser wire")

    let item = try service.createCapturedPrompt(candidate)
    try expect(item.type == .image && item.assetKind == .image, "unresolved captured prompts should use the image fallback type")
    try expect(item.modelId == "unspecified_image" && item.modelName == "未指定模型", "capture service should ensure the unspecified image model")
    try expect(item.folderId == "folder-capture-inbox" && item.folderName == "待整理", "capture service should use the top-level capture inbox")
    try expect(item.tags == ["网页采集", "待整理"], "capture service should apply the capture inbox tags")
    try expect(item.captureID == candidate.captureID, "capture ID should persist on the prompt")
    try expect(item.capturedSource?.pageURL == candidate.pageURL, "captured source metadata should persist on the prompt")
    try expect(item.title == "🌲 Forest prompt", "capture titles should use the first non-empty line with compressed whitespace")

    let loaded = try repository.findItem(captureID: candidate.captureID)
    try expect(loaded?.id == item.id, "repository should find a prompt by capture ID")
    let retried = try service.createCapturedPrompt(candidate)
    try expect(retried.id == item.id, "retries with the same capture ID should return the original prompt")
    try expect(try repository.loadItems().count == 1, "capture retries should not create duplicate prompts")
}

func testWebCaptureEventsUseDiscriminatedProtocolPayloads() throws {
    let events: [WebCaptureEvent] = [
        .presented(captureID: "capture-events"),
        .cancelled(captureID: "capture-events"),
        .animate(captureID: "capture-events", mouthScreenPoint: WebCapturePoint(x: 10.5, y: 20.25)),
        .saved(captureID: "capture-events", itemID: "item-events"),
        .failed(captureID: "capture-events", code: "app-unavailable", retryable: true)
    ]
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    for event in events {
        let data = try encoder.encode(event)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        try expect(object?["type"] is String, "web capture events should include a discriminating type field")
        try expect(object?["captureID"] as? String == "capture-events", "every capture event should include captureID")
        try expect(try decoder.decode(WebCaptureEvent.self, from: data) == event, "web capture events should round-trip through Codable")
    }

    let animate = try JSONSerialization.jsonObject(with: encoder.encode(events[2])) as? [String: Any]
    let mouth = animate?["mouthScreenPoint"] as? [String: Any]
    try expect(mouth?["x"] as? Double == 10.5 && mouth?["y"] as? Double == 20.25, "animate events should carry the mouth screen point")
    let saved = try JSONSerialization.jsonObject(with: encoder.encode(events[3])) as? [String: Any]
    try expect(saved?["itemID"] as? String == "item-events", "saved events should carry the item ID")
    let failed = try JSONSerialization.jsonObject(with: encoder.encode(events[4])) as? [String: Any]
    try expect(failed?["code"] as? String == "app-unavailable" && failed?["retryable"] as? Bool == true, "failed events should carry code and retryability")
}

func testCapturedInsertIsAtomicAndNeverReplacesExistingVersions() throws {
    let libraryURL = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: libraryURL)
    let service = PromptStudioAutomationService(repository: repository)
    let candidate = WebCaptureCandidate(captureID: "atomic-capture", selectedText: "original prompt")
    let original = try service.createCapturedPrompt(candidate)
    let originalVersionIDs = original.versions.map(\.id)

    var conflicting = sampleItem(title: "conflicting", prompt: "replacement prompt")
    conflicting.captureID = candidate.captureID
    conflicting.capturedSource = candidate.capturedSource
    let returned = try repository.saveCapturedItem(conflicting)
    try expect(returned.id == original.id, "capture insert-or-return-existing should return the original row")
    let loaded = try repository.findItem(captureID: candidate.captureID)
    try expect(loaded?.id == original.id, "a different item ID must not replace an existing capture")
    try expect(loaded?.versions.map(\.id) == originalVersionIDs, "an idempotent retry must preserve original versions")
    try expect(loaded?.currentVersion?.prompt == "original prompt", "an idempotent retry must preserve original content")

    do {
        try repository.saveItem(conflicting)
        throw CoreUnitTestError.failure("the partial unique capture index should reject a direct duplicate save")
    } catch SQLiteError.stepFailed {
        // Expected: the generic save path must not replace a capture row.
    }
    let afterRejected = try repository.findItem(captureID: candidate.captureID)
    try expect(afterRejected?.id == original.id && afterRejected?.versions.map(\.id) == originalVersionIDs, "a rejected duplicate save must preserve the original row and versions")

    var nullCaptureA = sampleItem(title: "null-a", prompt: "a")
    var nullCaptureB = sampleItem(title: "null-b", prompt: "b")
    nullCaptureA.captureID = nil
    nullCaptureB.captureID = nil
    try repository.saveItem(nullCaptureA)
    try repository.saveItem(nullCaptureB)
    try expect(try repository.loadItems().count == 3, "the partial unique index should allow multiple NULL capture IDs")
}

func testCapturedInsertSerializesAcrossRepositoryConnections() throws {
    let libraryURL = try temporaryLibraryURL()
    let firstRepository = try PromptRepository(libraryURL: libraryURL)
    let secondRepository = try PromptRepository(libraryURL: libraryURL)
    let services = [
        PromptStudioAutomationService(repository: firstRepository),
        PromptStudioAutomationService(repository: secondRepository)
    ]
    let candidate = WebCaptureCandidate(captureID: "concurrent-capture", selectedText: "concurrent prompt")
    let group = DispatchGroup()
    let state = CaptureRaceState()
    for service in services {
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                state.append(item: try service.createCapturedPrompt(candidate))
            } catch {
                state.append(error: error)
            }
        }
    }
    group.wait()
    try expect(state.errors.isEmpty, "concurrent capture retries should not fail with SQLite busy/constraint errors")
    try expect(state.items.count == 2 && state.items[0].id == state.items[1].id, "concurrent capture retries should return one winning item")
    try expect(try firstRepository.loadItems().count == 1, "concurrent capture retries should persist one item")
}

func testCaptureDefaultsRepairExistingResources() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    try repository.saveModelProfile(ModelProfile(id: "unspecified_image", name: "Wrong", type: .text, parameters: ["bad"]))
    try repository.saveFolder(LibraryFolder(id: "folder-capture-inbox", name: "Wrong", parentId: "parent", type: .image, sortOrder: 2))

    let item = try PromptStudioAutomationService(repository: repository).createCapturedPrompt(
        WebCaptureCandidate(captureID: "default-repair", selectedText: "captured")
    )
    let model = try repository.loadModelProfiles().first { $0.id == "unspecified_image" }
    let folder = try repository.loadFolders().first { $0.id == "folder-capture-inbox" }
    try expect(item.modelId == "unspecified_image" && item.modelName == "未指定模型", "capture creation should repair the canonical model")
    try expect(model?.name == "未指定模型" && model?.type == .image && model?.parameters.isEmpty == true, "capture model repair should canonicalize all model fields")
    try expect(item.folderId == "folder-capture-inbox" && item.folderName == "待整理", "capture creation should repair the canonical folder")
    try expect(folder?.name == "待整理" && folder?.type == .text && folder?.parentId == nil, "capture folder repair should restore a top-level text inbox")
}

func testWebCaptureValidationAndTitleLimit() throws {
    let service = try PromptStudioAutomationService(repository: PromptRepository(libraryURL: temporaryLibraryURL()))

    do {
        _ = try service.createCapturedPrompt(WebCaptureCandidate(captureID: "empty", selectedText: " \n\t"))
        throw CoreUnitTestError.failure("empty capture text should be rejected")
    } catch AutomationServiceError.invalidInput {
        // Expected.
    }

    do {
        _ = try service.createCapturedPrompt(
            WebCaptureCandidate(captureID: "oversized", selectedText: String(repeating: "a", count: 50_001))
        )
        throw CoreUnitTestError.failure("oversized capture text should be rejected")
    } catch AutomationServiceError.invalidInput {
        // Expected.
    }

    let longTitle = String(repeating: "界", count: 39) + "😀😀"
    let item = try service.createCapturedPrompt(
        WebCaptureCandidate(captureID: "title-limit", selectedText: "  \(longTitle)  \nbody")
    )
    try expect(item.title.count == 40, "capture title limit should count Swift Characters")
    try expect(item.title == String(longTitle.prefix(40)), "capture title should truncate by Character, not UTF-16 units")
}

func testWebCaptureSchemaMigrationAddsColumnsAndIndex() throws {
    let oldLibraryURL = try temporaryLibraryURL()
    try PromptRepository.createLibraryDirectories(at: oldLibraryURL)
    let databaseURL = oldLibraryURL.appendingPathComponent("database/promptstudio.sqlite")
    let database = try SQLiteDatabase(path: databaseURL.path)
    try database.execute(
        """
        CREATE TABLE prompt_items (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            type TEXT NOT NULL,
            assetKind TEXT NOT NULL DEFAULT 'image',
            modelId TEXT NOT NULL,
            modelName TEXT NOT NULL,
            folderId TEXT NOT NULL DEFAULT '',
            folderName TEXT NOT NULL,
            category TEXT NOT NULL,
            assetPath TEXT NOT NULL,
            thumbnailPath TEXT NOT NULL,
            aspectRatio TEXT NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            format TEXT NOT NULL,
            fileSize INTEGER NOT NULL,
            favorite INTEGER NOT NULL,
            deletedAt TEXT,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL,
            lastUsedAt TEXT NOT NULL,
            sortOrder INTEGER NOT NULL DEFAULT 0,
            tagsJSON TEXT NOT NULL,
            referencesJSON TEXT NOT NULL,
            description TEXT NOT NULL
        );
        """
    )

    let legacyID = "legacy-row"
    let legacyVersionID = "legacy-version"
    let legacyDate = "2026-08-12T00:00:00Z"
    try database.execute(
        """
        CREATE TABLE prompt_versions (
            id TEXT PRIMARY KEY,
            promptItemId TEXT NOT NULL,
            version TEXT NOT NULL,
            prompt TEXT NOT NULL,
            negativePrompt TEXT NOT NULL,
            parametersJSON TEXT NOT NULL,
            note TEXT NOT NULL,
            createdAt TEXT NOT NULL
        );
        INSERT INTO prompt_items VALUES ('\(legacyID)', 'Legacy', 'text', 'text', 'legacy-model', 'Legacy model', '', '未分类', '文本', '', '', '', 0, 0, 'TEXT', 0, 0, NULL, '\(legacyDate)', '\(legacyDate)', '\(legacyDate)', 7, '[]', '[]', 'legacy description');
        INSERT INTO prompt_versions VALUES ('\(legacyVersionID)', '\(legacyID)', 'V1.0', 'legacy body', '', '{}', 'legacy note', '\(legacyDate)');
        """
    )

    let migratedRepository = try PromptRepository(libraryURL: oldLibraryURL)
    let migrated = try SQLiteDatabase(path: databaseURL.path)
    let columns = try migrated.query("PRAGMA table_info(prompt_items);")
    let names = Set(columns.compactMap { $0["name"] ?? nil })
    try expect(names.contains("captureId"), "migration should add captureId to old prompt_items tables")
    try expect(names.contains("captureSourceJSON"), "migration should add captureSourceJSON to old prompt_items tables")
    try expect(names.count == 28, "migrated prompt_items schema should have 28 columns")
    let legacy = try migratedRepository.loadItems().first { $0.id == legacyID }
    try expect(legacy?.currentVersion?.id == legacyVersionID && legacy?.currentVersion?.prompt == "legacy body", "migration must preserve legacy prompt rows and versions")
    let reopenedRepository = try PromptRepository(libraryURL: oldLibraryURL)
    try expect(try reopenedRepository.loadItems().first { $0.id == legacyID }?.currentVersion?.id == legacyVersionID, "migration should be safe to run repeatedly")
    let indexes = try migrated.query(
        "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'idx_prompt_items_capture_id';"
    )
    try expect(indexes.count == 1, "migration should add the partial unique capture ID index")

    let exactLimit = try PromptStudioAutomationService(repository: migratedRepository).createCapturedPrompt(
        WebCaptureCandidate(captureID: "exact-limit", selectedText: String(repeating: "x", count: 50_000))
    )
    try expect(exactLimit.currentVersion?.prompt.count == 50_000, "exactly 50,000 capture characters should be accepted")

    do {
        _ = try PromptStudioAutomationService(repository: migratedRepository).createCapturedPrompt(
            WebCaptureCandidate(captureID: "over-limit", selectedText: String(repeating: "x", count: 50_001))
        )
        throw CoreUnitTestError.failure("50,001 capture characters should be rejected")
    } catch AutomationServiceError.invalidInput {
        // Expected.
    }

    let current = sampleItem(title: "legacy-json", prompt: "json")
    let currentData = try JSONEncoder().encode(current)
    var oldObject = try JSONSerialization.jsonObject(with: currentData) as! [String: Any]
    oldObject.removeValue(forKey: "captureID")
    oldObject.removeValue(forKey: "capturedSource")
    let oldJSON = try JSONSerialization.data(withJSONObject: oldObject)
    let decodedOld = try JSONDecoder().decode(PromptItem.self, from: oldJSON)
    try expect(decodedOld.captureID == nil && decodedOld.capturedSource == nil, "PromptItem JSON without new capture fields should remain decodable")
}

func testFolderSeedIsIdempotent() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let folders = [
        LibraryFolder(id: "image-a", name: "图片 A", type: .image, sortOrder: 0),
        LibraryFolder(id: "video-a", name: "视频 A", type: .video, sortOrder: 0)
    ]

    try repository.seedFoldersIfNeeded(folders)
    try repository.seedFoldersIfNeeded(folders)

    let loaded = try repository.loadFolders()
    try expect(loaded.count == 2, "folder seed should not duplicate rows")
    try expect(loaded.map(\.name).contains("图片 A"), "seeded image folder should load")
    try expect(loaded.map(\.name).contains("视频 A"), "seeded video folder should load")
}

func testFolderCRUDRoundTrip() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let parent = LibraryFolder(id: "folder-parent", name: "父文件夹", sortOrder: 1)
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let folder = LibraryFolder(id: "folder-1", name: "旧文件夹", parentId: parent.id, type: .image, sortOrder: 3, createdAt: createdAt)

    try repository.saveFolder(parent)
    try repository.saveFolder(folder)
    try expect(try repository.loadFolders().contains { $0.parentId == parent.id && $0.name == "旧文件夹" }, "saved child folder should load with parent")
    try expect(try repository.loadFolders().first { $0.id == folder.id }?.createdAt == createdAt, "folder creation date should persist across reloads")

    try repository.renameFolder(id: folder.id, name: "新文件夹")
    try expect(try repository.loadFolders().first { $0.id == folder.id }?.name == "新文件夹", "renamed folder should persist")

    try repository.deleteFolder(id: folder.id)
    try expect(try repository.loadFolders().contains { $0.id == folder.id } == false, "deleted folder should be removed")
}

func testFolderCreatedAtMigratesFromLegacySchema() throws {
    let libraryURL = try temporaryLibraryURL()
    try PromptRepository.createLibraryDirectories(at: libraryURL)
    let databaseURL = libraryURL.appendingPathComponent("database/promptstudio.sqlite")
    do {
        let database = try SQLiteDatabase(path: databaseURL.path)
        try database.execute(
            """
            CREATE TABLE library_folders (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                parentId TEXT,
                type TEXT,
                count INTEGER NOT NULL,
                sortOrder INTEGER NOT NULL
            );
            """
        )
        try database.run(
            "INSERT INTO library_folders (id, name, parentId, type, count, sortOrder) VALUES (?, ?, ?, ?, ?, ?);",
            values: [.text("legacy-folder"), .text("旧资料夹"), .null, .null, .int(0), .int(0)]
        )
    }

    let migrationStartedAt = Date().addingTimeInterval(-1)
    let repository = try PromptRepository(libraryURL: libraryURL)
    guard let migrated = try repository.loadFolders().first(where: { $0.id == "legacy-folder" }) else {
        throw CoreUnitTestError.failure("legacy folder should remain after schema migration")
    }
    try expect(migrated.createdAt >= migrationStartedAt, "legacy folder should receive a stable creation date")
}

func testAutomationServiceCreatesAndUpdatesPrompts() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let service = PromptStudioAutomationService(repository: repository)
    let folder = try service.createFolder(name: "Agent Folder")
    let created = try service.createPrompt(
        AutomationCreatePromptInput(
            title: "Agent Prompt",
            prompt: "cinematic product photo",
            negativePrompt: "watermark",
            tags: ["产品", "写实"],
            model: "Image 2",
            folderID: folder.id
        )
    )

    try expect(created.folderId == folder.id, "agent-created prompt should attach to folder")
    try expect(created.currentVersion?.prompt == "cinematic product photo", "agent-created prompt should persist prompt")

    let updated = try service.updatePrompt(id: created.id, input: AutomationUpdatePromptInput(prompt: "updated prompt", tags: ["更新"]))
    try expect(updated.versions.count == 2, "agent prompt update should append a version")
    try expect(updated.currentVersion?.prompt == "updated prompt", "agent prompt update should become current version")
    try expect(updated.tags == ["更新"], "agent prompt update should replace tags")
}

func testAutomationServiceCreatesTypedPromptPlaceholdersAndMarkdown() throws {
    let libraryURL = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: libraryURL)
    try repository.saveModelProfile(ModelProfile(id: "image-model", name: "Image Model", type: .image, parameters: []))
    try repository.saveModelProfile(ModelProfile(id: "video-model", name: "Video Model", type: .video, parameters: []))
    let service = PromptStudioAutomationService(repository: repository)

    let explicitImage = try service.createPrompt(
        AutomationCreatePromptInput(title: "Image", prompt: "write anything", model: "Image Model")
    )
    try expect(explicitImage.type == .image && explicitImage.assetKind == .image, "a valid image model should force an image prompt")
    try expect(explicitImage.assetPath.isEmpty && explicitImage.format.isEmpty && explicitImage.isMediaPromptPlaceholder, "media prompt should be a file-less placeholder")

    let vague = try service.createPrompt(
        AutomationCreatePromptInput(title: "Vague", prompt: "something unclassified")
    )
    try expect(vague.type == .image && vague.modelId == "unspecified_image", "an unspecified model should follow the image fallback type")
    try expect(vague.assetKind == .image && vague.assetPath.isEmpty, "an unspecified media prompt should remain file-less")

    let unknownModel = try service.createPrompt(
        AutomationCreatePromptInput(title: "Unknown model", prompt: "生成 5 秒视频", model: "Not Installed")
    )
    try expect(unknownModel.type == .video && unknownModel.modelId == "unspecified_video", "an unknown model should use the final type's unspecified model")

    let text = try service.createPrompt(
        AutomationCreatePromptInput(title: "Writing", prompt: "写一篇关于森林的文章")
    )
    try expect(text.type == .text && text.assetKind == .markdown && text.format == "MD", "explicit writing intent should create a Markdown prompt")
    try expect(!text.assetPath.isEmpty && FileManager.default.fileExists(atPath: text.assetPath), "created Markdown prompt should have a real file")
    try expect(text.primaryAssetState == .available, "created Markdown prompt should be available")

    let failedURL = try temporaryLibraryURL()
    let failedRepository = try PromptRepository(libraryURL: failedURL)
    try SQLiteDatabase(path: failedRepository.databaseURL.path).execute("CREATE TRIGGER fail_create_prompt BEFORE INSERT ON prompt_items WHEN NEW.title = 'DB failure' BEGIN SELECT RAISE(ABORT, 'create failure'); END;")
    let failedService = PromptStudioAutomationService(repository: failedRepository)
    do {
        _ = try failedService.createPrompt(AutomationCreatePromptInput(title: "DB failure", prompt: "写一篇文章"))
        throw CoreUnitTestError.failure("createPrompt should surface DB failures")
    } catch SQLiteError.stepFailed {
        // Expected: the newly generated Markdown file must be cleaned up.
    }
    let failedDocuments = try FileManager.default.contentsOfDirectory(
        at: failedURL.appendingPathComponent("assets/documents"),
        includingPropertiesForKeys: nil
    )
    try expect(failedDocuments.isEmpty, "failed createPrompt should not leave an orphan Markdown file")

    let firstMarkdown = try repository.writeMarkdownPromptAsset(promptID: "collision", title: "First", prompt: "first")
    let secondMarkdown = try repository.writeMarkdownPromptAsset(promptID: "collision", title: "Second", prompt: "second")
    try expect(firstMarkdown != secondMarkdown, "Markdown asset names should remain unique")
    try expect(FileManager.default.fileExists(atPath: firstMarkdown.path), "writing a second Markdown asset must not delete the first")
}

func testAutomationServiceImportsTextMetadata() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let service = PromptStudioAutomationService(repository: repository)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
    try "Prompt: forest fashion portrait --no logo\nTags: 风景, 人物".write(to: file, atomically: true, encoding: .utf8)

    let imported = try service.importFiles(paths: [file.path])
    try expect(imported.count == 1, "agent import should create one item")
    try expect(imported[0].assetKind == .markdown, "markdown import should keep asset kind")
    try expect(imported[0].currentVersion?.prompt == "forest fashion portrait", "markdown import should parse prompt")
    try expect(imported[0].currentVersion?.negativePrompt == "logo", "markdown import should parse negative prompt")
    try expect(imported[0].tags.contains("风景") && imported[0].tags.contains("人物"), "markdown import should parse tags")
}

func testDocumentTextExtractorReadsRealDocx() throws {
    let docx = try makeDocxFixture(text: "Prompt: real docx forest --no logo\nTags: 文档, 测试\n")
    guard let text = DocumentTextExtractor.readText(from: docx) else {
        throw CoreUnitTestError.failure("docx text should be readable")
    }
    try expect(text.contains("real docx forest"), "real docx text should include source prompt")
    let parsed = PromptImportParser.parse(text: text, assetKind: .document)
    try expect(parsed.prompt == "real docx forest", "real docx text should parse prompt")
    try expect(parsed.negativePrompt == "logo", "real docx text should parse negative prompt")
    try expect(parsed.tags.contains("文档") && parsed.tags.contains("测试"), "real docx text should parse tags")
}

func testAutomationServiceImportsRealDocxMetadata() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let service = PromptStudioAutomationService(repository: repository)
    let docx = try makeDocxFixture(text: "Prompt: agent docx prompt --no watermark\nTags: Agent, DOCX\n")

    let imported = try service.importFiles(paths: [docx.path])
    try expect(imported.count == 1, "agent docx import should create one item")
    try expect(imported[0].assetKind == .document, "agent docx import should keep document asset kind")
    try expect(imported[0].type == .text, "agent docx import should stay in text prompt flow")
    try expect(imported[0].currentVersion?.prompt == "agent docx prompt", "agent docx import should parse prompt")
    try expect(imported[0].currentVersion?.negativePrompt == "watermark", "agent docx import should parse negative prompt")
    try expect(imported[0].tags.contains("Agent") && imported[0].tags.contains("DOCX"), "agent docx import should parse tags")
}

func testAutomationServiceImportsImageMetadata() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let service = PromptStudioAutomationService(repository: repository)
    let png = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")!
    try bytes.write(to: png)

    let imported = try service.importFiles(paths: [png.path])
    try expect(imported[0].assetKind == .image, "png import should keep image asset kind")
    try expect(imported[0].width == 1 && imported[0].height == 1, "png import should read pixel dimensions")
    try expect(imported[0].aspectRatio == "1:1", "png import should normalize aspect ratio")
    try expect(imported[0].fileSize > 0, "png import should store file size")
}

func testPromptClipboardInterpreterPreservesPlainTextAndBuildsTitle() throws {
    let source = "\r\n  This   is a simple paragraph.\r\nSecond line\twith spacing.  \r\n"
    let interpretation = PromptClipboardInterpreter.interpret(source)
    let normalized = "This   is a simple paragraph.\nSecond line\twith spacing."

    try expect(interpretation.originalText == normalized, "plain text should normalize CRLF and outer whitespace")
    try expect(interpretation.prompt == normalized, "plain text should remain intact in the prompt")
    try expect(interpretation.title == "This is a simple paragraph.", "title should use the first sentence with compressed whitespace")
    try expect(interpretation.title.count <= 40, "title should be capped at 40 Characters")
    try expect(interpretation.negativePrompt.isEmpty, "plain text should not invent a negative prompt")
    try expect(interpretation.suggestedType == nil, "generic prose should keep the current prompt type")
}

func testPromptEditorPasteResolverKeepsPlainTextNative() throws {
    let interpretation = PromptClipboardInterpreter.interpret("A normal paragraph copied from a web page.")
    try expect(
        PromptEditorPasteResolver.resolve(interpretation) == .nativeText,
        "plain clipboard text should use native insertion at the current selection"
    )
}

func testPromptEditorPasteResolverMatchesOnlyStructuredFields() throws {
    let structured = PromptClipboardInterpreter.interpret(
        "Prompt: cinematic portrait\nNegative Prompt: watermark\nTags: portrait, studio\nParameters: ar=4:5"
    )
    let decision = PromptEditorPasteResolver.resolve(structured)
    guard case .structured(let summary) = decision else {
        throw CoreUnitTestError.failure("structured clipboard text should request field matching")
    }
    try expect(summary.hasNegativePrompt, "summary should report a matched negative prompt")
    try expect(summary.tagCount == 2, "summary should report only the two explicitly matched tags")
    try expect(summary.parameterCount == 1, "summary should report the matched parameter count")

    let promptOnly = PromptClipboardInterpreter.interpret("Prompt: cinematic portrait")
    guard case .structured(let promptSummary) = PromptEditorPasteResolver.resolve(promptOnly) else {
        throw CoreUnitTestError.failure("an explicit Prompt field should match title and Prompt")
    }
    try expect(promptSummary.hasPrompt, "prompt-only structured text should report its explicit Prompt field")

    let metadataOnly = PromptClipboardInterpreter.interpret("Negative Prompt: watermark\nTags: clean, studio")
    guard case .structured(let metadataSummary) = PromptEditorPasteResolver.resolve(metadataOnly) else {
        throw CoreUnitTestError.failure("metadata-only clipboard text should match without replacing Prompt")
    }
    try expect(!metadataSummary.hasPrompt, "metadata-only matching must preserve the existing Prompt")

    let unknownJSON = PromptClipboardInterpreter.interpret(#"{"unknown":"value"}"#)
    try expect(PromptEditorPasteResolver.resolve(unknownJSON) == .nativeText, "unknown JSON keys should stay a native paste")

    let duplicateNormalizedKeys = PromptClipboardInterpreter.interpret(#"{"prompt":"one","Prompt":"two"}"#)
    guard case .structured(let duplicateSummary) = PromptEditorPasteResolver.resolve(duplicateNormalizedKeys) else {
        throw CoreUnitTestError.failure("duplicate normalized JSON keys should match safely without crashing")
    }
    try expect(duplicateSummary.hasPrompt, "duplicate normalized JSON should retain the explicit Prompt match")

    let inline = PromptClipboardInterpreter.interpret("cinematic portrait --ar 16:9 #studio")
    guard case .structured(let inlineSummary) = PromptEditorPasteResolver.resolve(inline) else {
        throw CoreUnitTestError.failure("inline Prompt syntax should match Prompt and its metadata")
    }
    try expect(inlineSummary.hasPrompt, "inline syntax must preserve and fill the residual Prompt text")
    try expect(inlineSummary.tagCount == 1 && inlineSummary.parameterCount == 1, "inline syntax should match its explicit tag and parameter")

    let inlineNegative = PromptClipboardInterpreter.interpret("cinematic portrait --no watermark")
    guard case .structured(let inlineNegativeSummary) = PromptEditorPasteResolver.resolve(inlineNegative) else {
        throw CoreUnitTestError.failure("inline negative syntax should match Prompt and Negative Prompt")
    }
    try expect(inlineNegativeSummary.hasPrompt && inlineNegativeSummary.hasNegativePrompt, "inline --no must not discard the residual Prompt")

    let modelAndInlinePrompt = PromptClipboardInterpreter.interpret("Model: Flux\ncinematic portrait --ar 16:9")
    guard case .structured(let modelAndInlineSummary) = PromptEditorPasteResolver.resolve(modelAndInlinePrompt) else {
        throw CoreUnitTestError.failure("model metadata plus an inline Prompt should match both fields")
    }
    try expect(modelAndInlineSummary.hasPrompt && modelAndInlineSummary.hasExplicitModel, "model metadata must not swallow the following inline Prompt")

    let invalidPromptJSON = PromptClipboardInterpreter.interpret(#"{"prompt":123}"#)
    try expect(PromptEditorPasteResolver.resolve(invalidPromptJSON) == .nativeText, "a non-string JSON Prompt must not clear an existing draft")
}

func testPromptClipboardInterpreterTitleCapDoesNotTruncatePrompt() throws {
    let source = "A very long first sentence that should be shortened for the title while preserving the source prompt."
    let interpretation = PromptClipboardInterpreter.interpret(source)

    try expect(interpretation.title.count == 40, "long titles should be truncated to exactly 40 Characters")
    try expect(interpretation.prompt == source, "title truncation must never truncate the prompt")
}

func testPromptClipboardInterpreterParsesChineseStructuredFields() throws {
    let interpretation = PromptClipboardInterpreter.interpret(
        "提示词：古风人物肖像，柔和光线\n负面提示词：水印，文字\n标签：人物，写实, 人物\n参数：步数=20"
    )

    try expect(interpretation.prompt == "古风人物肖像，柔和光线", "Chinese prompt heading should be parsed")
    try expect(interpretation.negativePrompt == "水印，文字", "Chinese negative prompt heading should be parsed")
    try expect(interpretation.tags == ["人物", "写实"], "Chinese tags should be normalized and deduplicated")
    try expect(interpretation.parameters["步数"] == "20", "Chinese parameters should be retained")
}

func testPromptClipboardInterpreterParsesJSON() throws {
    let interpretation = PromptClipboardInterpreter.interpret(
        #"{"prompt":"studio portrait","negative_prompt":"watermark","tags":["portrait","portrait"],"parameters":{"ar":"4:5"}}"#
    )

    try expect(interpretation.prompt == "studio portrait", "JSON prompt should be parsed")
    try expect(interpretation.negativePrompt == "watermark", "JSON negative prompt should be parsed")
    try expect(interpretation.tags.first == "portrait" && interpretation.tags.filter { $0 == "portrait" }.count == 1, "JSON tags should be normalized and deduplicated")
    try expect(interpretation.parameters["ar"] == "4:5", "JSON parameters should be retained")
    try expect(interpretation.formatHint == "JSON", "a structured JSON clipboard payload should preserve a JSON format hint")
}

func testPromptClipboardInterpreterInfersFourPromptTypes() throws {
    let image = PromptClipboardInterpreter.interpret("生成一张静态人物画面，精心构图，人物穿着红色服装，柔和光线，暖色调，85mm焦段。")
    let video = PromptClipboardInterpreter.interpret("生成一个5秒人物转身视频，连续动作，镜头缓慢运镜并完成转场。")
    let audio = PromptClipboardInterpreter.interpret("制作一段女声旁白，音色温暖，语速自然，加入轻柔BGM和环境音效。")
    let text = PromptClipboardInterpreter.interpret("写一篇文章，整理并总结以下资料，翻译成Markdown结构化内容。")

    try expect(image.suggestedType == .image && image.typeConfidence == .high, "image output intent should suggest image with high confidence")
    try expect(video.suggestedType == .video && video.typeConfidence == .high, "video output intent should suggest video with high confidence")
    try expect(audio.suggestedType == .audio && audio.typeConfidence == .high, "audio output intent should suggest audio with high confidence")
    try expect(text.suggestedType == .text && text.typeConfidence == .high, "text output intent should suggest text with high confidence")
}

func testPromptClipboardInterpreterDoesNotTreatRealisticAsWriteIntent() throws {
    let interpretation = PromptClipboardInterpreter.interpret("写实人物肖像，柔和光线，高细节")

    try expect(interpretation.suggestedType == .image, "写实 should contribute image semantics without becoming a writing intent")
}

func testPromptClipboardInterpreterRecognizesExplicitTargetIntents() throws {
    let chineseCases: [(String, PromptType)] = [
        ("输出一张高清图", .image),
        ("修改这张图片", .image),
        ("改写这篇文章", .text),
        ("写文章介绍产品", .text),
        ("设计温柔女声音色", .audio)
    ]

    for (source, expectedType) in chineseCases {
        let interpretation = PromptClipboardInterpreter.interpret(source)
        try expect(interpretation.suggestedType == expectedType, "\(source) should suggest \(expectedType.rawValue)")
        try expect(interpretation.typeConfidence == .high, "\(source) should have high confidence")
    }

    let englishCases: [(String, PromptType)] = [
        ("edit this image", .image),
        ("rewrite this article", .text),
        ("design a gentle female voice timbre", .audio)
    ]
    for (source, expectedType) in englishCases {
        let interpretation = PromptClipboardInterpreter.interpret(source)
        try expect(interpretation.suggestedType == expectedType, "\(source) should suggest \(expectedType.rawValue)")
        try expect(interpretation.typeConfidence == .high, "\(source) should have high confidence")
    }
}

func testPromptClipboardInterpreterPrefersVideoOutputOverReferenceImage() throws {
    let interpretation = PromptClipboardInterpreter.interpret("图1是人物参考，生成一个5秒人物转身视频，镜头连续运镜。")

    try expect(interpretation.suggestedType == .video, "video output should win over a referenced image")
    try expect(interpretation.typeConfidence == .high, "explicit video output should have high confidence")
}

func testPromptClipboardInterpreterKeepsModelAndFormatHintsWeak() throws {
    let labeled = PromptClipboardInterpreter.interpret("Model: Nano Banana 2\nFormat: JSON")
    try expect(labeled.modelHint == "Nano Banana 2", "English model field should be retained as a hint")
    try expect(labeled.formatHint == "JSON", "English format field should be retained as a hint")
    try expect(labeled.suggestedType == nil, "model and format names alone must not force a type")

    let chineseLabeled = PromptClipboardInterpreter.interpret("模型：Seedance 2\n格式：JSON")
    try expect(chineseLabeled.modelHint == "Seedance 2", "Chinese model field should be retained as a hint")
    try expect(chineseLabeled.formatHint == "JSON", "Chinese format field should be retained as a hint")
    try expect(chineseLabeled.suggestedType == nil, "Chinese model and format names alone must not force a type")

    let bareNames = PromptClipboardInterpreter.interpret("Nano Banana Seedance JSON")
    try expect(bareNames.modelHint == nil && bareNames.formatHint == nil, "bare names should not be mistaken for labeled hints")
    try expect(bareNames.suggestedType == nil, "bare model and format names must not force a type")
}

func testPromptClipboardInterpreterPreservesTagsAndMidjourneyParameters() throws {
    let interpretation = PromptClipboardInterpreter.interpret(
        "Prompt: cinematic portrait #人物 #人物 --ar 16:9 --stylize 250\nTags: 人物, 写实, 人物"
    )

    try expect(interpretation.tags == ["人物", "写实"], "tags should be deduplicated while preserving order")
    try expect(interpretation.parameters["ar"] == "16:9", "aspect ratio parameter should be retained")
    try expect(interpretation.parameters["stylize"] == "250", "stylize parameter should be retained")
}

func testPromptClipboardInterpreterLeavesConflictsAndLowConfidenceUnspecified() throws {
    let conflict = PromptClipboardInterpreter.interpret("生成一张图片并制作一段5秒视频")
    try expect(conflict.suggestedType == nil, "conflicting explicit output types should not switch the current tab")
    try expect(conflict.warnings.contains { $0.contains("冲突") }, "conflicting output types should explain the warning")
}

func testPromptClipboardInterpreterHandlesBlankInput() throws {
    let interpretation = PromptClipboardInterpreter.interpret(" \r\n\t ")

    try expect(interpretation.originalText.isEmpty, "blank input should normalize to an empty original text")
    try expect(interpretation.prompt.isEmpty, "blank input should produce an empty prompt")
    try expect(interpretation.title.isEmpty, "blank input should produce an empty title")
    try expect(interpretation.suggestedType == nil, "blank input should not suggest a type")
}

func testPromptPasteRouteResolverHonorsPastePriority() throws {
    try expect(
        PromptPasteRouteResolver.resolve(isTextInputActive: true, hasFileURLs: true, plainText: "prompt") == .nativeTextPaste,
        "active text input should keep native text paste as the highest priority"
    )
    try expect(
        PromptPasteRouteResolver.resolve(isTextInputActive: false, hasFileURLs: true, plainText: "prompt") == .importFiles,
        "file URLs should route to file import when no text input is active"
    )
    try expect(
        PromptPasteRouteResolver.resolve(isTextInputActive: false, hasFileURLs: false, plainText: " prompt ") == .smartPaste(" prompt "),
        "plain text should route to smart paste when no files or text input are present"
    )
    try expect(
        PromptPasteRouteResolver.resolve(isTextInputActive: false, hasFileURLs: false, plainText: " \r\n\t ") == .unavailable,
        "empty pasteboard content should be unavailable"
    )
}

func testPromptClipboardInterpreterStripsModelAndFormatMetadataFromPrompt() throws {
    let interpretation = PromptClipboardInterpreter.interpret(
        "Model: Nano Banana 2\nFormat: JSON\nPrompt: 生成一张静态人物画面"
    )

    try expect(interpretation.prompt == "生成一张静态人物画面", "model and format metadata lines should not pollute the prompt")
    try expect(interpretation.modelHint == "Nano Banana 2" && interpretation.formatHint == "JSON", "metadata lines should still produce hints")
}

func testPromptComposerTypeDecisionPreservesManualConfirmation() throws {
    let video = PromptClipboardInterpreter.interpret("生成一个5秒人物转身视频，连续动作，镜头缓慢运镜。")
    let manual = PromptComposerTypeDecision.resolve(
        interpretation: video,
        mode: .manual(.image)
    )
    try expect(manual == .manual(type: .image), "manual confirmation must not be overwritten by a new inference")

    let automatic = PromptComposerTypeDecision.resolve(
        interpretation: video,
        mode: .automatic
    )
    try expect(
        automatic == .automatic(type: .video, confidence: .high, reason: video.typeReason),
        "automatic mode should apply a high-confidence video inference"
    )
}

func testPromptComposerTypeDecisionReturnsPendingForLowConfidenceAndConflicts() throws {
    let generic = PromptClipboardInterpreter.interpret("一段普通的说明文字")
    let genericDecision = PromptComposerTypeDecision.decide(interpretation: generic, mode: .automatic)
    try expect(genericDecision.isPendingSelection, "low-confidence prose should wait for a type selection")
    try expect(genericDecision.type == nil, "pending type decisions must not expose a guessed type")

    let conflict = PromptClipboardInterpreter.interpret("生成一张图片并制作一段5秒视频")
    let conflictDecision = PromptComposerTypeDecision.resolve(interpretation: conflict, mode: .automatic)
    try expect(conflictDecision.isPendingSelection, "conflicting output intents should wait for a type selection")

    let resumed = PromptComposerTypeDecision.resolve(
        text: "制作一段女声旁白，音色温暖，语速自然。",
        mode: .automatic
    )
    try expect(resumed.type == .audio, "automatic mode should resume updating after a pending decision")
}

func testPromptComposerTypeDecisionDelegatesReferenceImageVideoSemantics() throws {
    let interpretation = PromptClipboardInterpreter.interpret("图1是人物参考，生成一个5秒人物转身视频，镜头连续运镜。")
    let decision = PromptComposerTypeDecision.resolve(interpretation: interpretation)
    try expect(decision.type == .video, "reference image plus video output should resolve to video")
    try expect(decision.confidence == .high, "explicit video output should retain high confidence")
}

func testPromptComposerMetadataPolicyUsesExactSameTypeModels() throws {
    let localModels = [
        ModelProfile(id: "nano_banana_2", name: "Nano Banana 2", type: .image, parameters: []),
        ModelProfile(id: "seedance_2", name: "Seedance 2.0", type: .video, parameters: []),
        ModelProfile(id: "wrong_type", name: "Video Banana", type: .video, parameters: [])
    ]
    let exact = PromptClipboardInterpretation(parameters: ["seed": "7"], modelHint: "Nano Banana 2", formatHint: "JSON")
    let exactDecision = PromptComposerMetadataPolicy.resolve(type: .image, interpretation: exact, localModels: localModels)
    try expect(exactDecision.model.id == "nano_banana_2", "an exact model name should resolve to a local same-type model")
    try expect(exactDecision.model.type == .image, "resolved model should retain the determined prompt type")
    try expect(exactDecision.promptFormatID == nil && exactDecision.promptFormat == nil, "non-text prompts must not persist text format metadata")
    try expect(exactDecision.parameters == ["seed": "7"], "non-format parameters should be retained")

    let unknown = PromptClipboardInterpretation(modelHint: "Nano Banana Ultra", formatHint: "JSON")
    let unknownDecision = PromptComposerMetadataPolicy.resolve(type: .image, interpretation: unknown, localModels: localModels)
    try expect(unknownDecision.model.id == PromptComposerMetadataPolicy.unspecifiedModelID, "unknown model hints should use the internal unspecified model")
    try expect(unknownDecision.model.name == PromptComposerMetadataPolicy.unspecifiedModelName, "unspecified model should use the localized fallback name")
    try expect(unknownDecision.model.type == .image, "unspecified model should use the determined prompt type")

    let wrongType = PromptClipboardInterpretation(modelHint: "Nano Banana 2")
    let wrongTypeDecision = PromptComposerMetadataPolicy.resolve(type: .video, interpretation: wrongType, localModels: localModels)
    try expect(wrongTypeDecision.model.id == PromptComposerMetadataPolicy.unspecifiedModelID, "a model matching only another type must not be reused")
}

func testPromptComposerMetadataPolicyNormalizesTextFormatsAndDefaultsMarkdown() throws {
    let localModels = [ModelProfile(id: "chatgpt_gpt", name: "ChatGPT / GPT", type: .text, parameters: [])]
    let formats: [(String, String, String)] = [
        ("JSON", "text_json", "JSON"),
        ("text_json", "text_json", "JSON"),
        ("yaml", "text_yaml", "YAML"),
        ("text_yaml", "text_yaml", "YAML"),
        ("TXT", "text_txt", "TXT"),
        ("text_txt", "text_txt", "TXT"),
        ("", "text_markdown", "Markdown"),
        ("text_markdown", "text_markdown", "Markdown"),
        ("unsupported", "text_markdown", "Markdown")
    ]
    for (hint, expectedID, expectedName) in formats {
        let interpretation = PromptClipboardInterpretation(parameters: ["prompt_format_id": "stale", "tone": "calm"], formatHint: hint.isEmpty ? nil : hint)
        let decision = PromptComposerMetadataPolicy.resolve(type: .text, interpretation: interpretation, localModels: localModels)
        try expect(decision.promptFormatID == expectedID, "text format \(hint) should resolve to \(expectedID)")
        try expect(decision.promptFormat == expectedName, "text format \(hint) should display as \(expectedName)")
        try expect(decision.parameters["prompt_format_id"] == expectedID && decision.parameters["prompt_format"] == expectedName, "text format metadata should be canonicalized")
        try expect(decision.parameters["tone"] == "calm", "custom parameters should survive format canonicalization")
    }
}

func testPromptClipboardInterpreterInfersExplicitTextOutputFormats() throws {
    let cases: [(String, String)] = [
        ("分析数据并输出 JSON", "JSON"),
        ("整理配置并输出 YAML", "YAML"),
        ("提取正文，保存为 TXT", "TXT"),
        ("保存为 JSON", "JSON"),
        ("save as Markdown", "Markdown")
    ]
    for (text, expectedFormat) in cases {
        let interpretation = PromptClipboardInterpreter.interpret(text)
        try expect(interpretation.suggestedType == .text, "explicit \(expectedFormat) output should infer a text Prompt")
        try expect(interpretation.formatHint == expectedFormat, "explicit \(expectedFormat) output should preserve its format hint")
    }
}

func testUnifiedPromptTypeClassifierAlwaysResolvesFourTypes() throws {
    let cases: [(String, PromptType)] = [
        ("分析数据并输出 JSON", .text),
        ("生成一张静态图片，人物肖像", .image),
        ("制作 8 秒视频，镜头向前推进", .video),
        ("生成旁白和配音，温暖的声线", .audio),
        ("随便写点什么", .image)
    ]
    for (text, expected) in cases {
        try expect(PromptTypeClassifier.classify(text: text) == expected, "classifier should resolve \(text) to \(expected.rawValue)")
    }

    try expect(
        PromptTypeClassifier.classify(
            interpretation: PromptClipboardInterpretation(suggestedType: .text, typeConfidence: .low),
            mode: .manual(.audio)
        ) == .audio,
        "manual type should always win over automatic inference"
    )
    try expect(
        PromptTypeClassifier.classify(
            interpretation: PromptClipboardInterpretation(
                suggestedType: .video,
                typeConfidence: .medium,
                warnings: ["输出类型冲突"]
            )
        ) == .image,
        "conflicting interpretation should use the image fallback"
    )
    try expect(
        PromptTypeClassifier.classify(
            interpretation: PromptClipboardInterpretation(warnings: ["输出类型冲突"]),
            mode: .manual(.audio)
        ) == .audio,
        "manual type should survive a conflicting automatic interpretation"
    )
}

func testHomepageSmartPasteAlwaysProducesASelectedComposerType() throws {
    let vague = PromptClipboardInterpreter.interpret("一个关于夏日旅行的灵感")
    let classification = PromptTypeClassifier.resolve(interpretation: vague)
    try expect(classification.usedFallback, "vague homepage clipboard text should use the product fallback")
    try expect(
        classification.composerDecision.type == .image,
        "homepage smart paste must visibly select the fallback image type"
    )

    let video = PromptClipboardInterpreter.interpret("生成一段 5 秒视频，镜头缓慢推进")
    try expect(
        PromptTypeClassifier.resolve(interpretation: video).composerDecision.type == .video,
        "homepage smart paste must retain a confidently inferred media type"
    )
}

func testPromptItemPrimaryAssetStatesKeepPlaceholdersSeparateFromDocuments() throws {
    let assetFixtureRoot = try temporaryLibraryURL()
    let realMarkdownPath = assetFixtureRoot.appendingPathComponent("real.md")
    let realJSONPath = assetFixtureRoot.appendingPathComponent("real.json")
    let realTXTPath = assetFixtureRoot.appendingPathComponent("real.txt")
    let realDOCXPath = assetFixtureRoot.appendingPathComponent("real.docx")
    for path in [realMarkdownPath, realJSONPath, realTXTPath, realDOCXPath] {
        try Data("fixture".utf8).write(to: path)
    }
    let imagePlaceholder = sampleItem(title: "image placeholder", assetKind: .image, prompt: "image", assetPath: "", format: "")
    let videoPlaceholder = sampleItem(title: "video placeholder", assetKind: .video, prompt: "video", assetPath: "", format: "PROMPT")
    let audioPlaceholder = sampleItem(title: "audio placeholder", assetKind: .audio, prompt: "audio", assetPath: "", format: "TEXT")
    let markdown = sampleItem(title: "markdown", assetKind: .markdown, prompt: "# markdown", assetPath: realMarkdownPath.path, format: "MD")
    let json = sampleItem(title: "json", assetKind: .json, prompt: "{}", assetPath: realJSONPath.path, format: "JSON")
    let txt = sampleItem(title: "txt", assetKind: .text, prompt: "txt", assetPath: realTXTPath.path, format: "TXT")
    let docx = sampleItem(title: "docx", assetKind: .document, prompt: "docx", assetPath: realDOCXPath.path, format: "DOCX")
    let missingText = sampleItem(title: "missing text", assetKind: .markdown, prompt: "missing", assetPath: assetFixtureRoot.appendingPathComponent("missing.md").path, format: "MD")
    let textWithoutPath = sampleItem(title: "text without path", assetKind: .markdown, prompt: "draft", assetPath: "", format: "PROMPT")

    for placeholder in [imagePlaceholder, videoPlaceholder, audioPlaceholder] {
        try expect(placeholder.isMediaPromptPlaceholder, "empty media prompt should be a media placeholder")
        try expect(!placeholder.hasPrimaryAsset, "media placeholder should not claim a primary asset")
    }
    for document in [markdown, json, txt, docx] {
        try expect(!document.isMediaPromptPlaceholder, "real text document should not be treated as a media placeholder")
        try expect(document.primaryAssetState == .available, "existing text document should be available")
        try expect(document.hasPrimaryAsset, "real text document should report a primary asset path")
    }
    try expect(missingText.primaryAssetState == .missing, "missing text document should report missing")
    try expect(textWithoutPath.primaryAssetState == .textDocument, "text draft without a path should retain text-document state")
}

func testCapturedPromptUsesUnifiedClassificationAndIsIdempotent() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let service = PromptStudioAutomationService(repository: repository)
    let candidates: [(String, String, PromptType, AssetKind)] = [
        ("capture-image", "生成一张照片，柔和光线", .image, .image),
        ("capture-video", "生成 6 秒视频，连续动作和运镜", .video, .video),
        ("capture-audio", "生成旁白和配音，温暖声线", .audio, .audio),
        ("capture-text", "分析数据并输出 JSON", .text, .markdown),
        ("capture-fallback", "随便写点什么", .image, .image)
    ]
    for (captureID, selectedText, expectedType, expectedKind) in candidates {
        let item = try service.createCapturedPrompt(WebCaptureCandidate(captureID: captureID, selectedText: selectedText))
        try expect(item.type == expectedType && item.assetKind == expectedKind, "capture \(captureID) should use unified type and asset kind")
        if expectedType == .text {
            try expect(item.format.uppercased() == "MD", "text capture should retain markdown document semantics")
            try expect(item.isTextDocumentLike && !item.isMediaPromptPlaceholder, "text capture should be a text document, not media placeholder")
            try expect(!item.assetPath.isEmpty && FileManager.default.fileExists(atPath: item.assetPath), "text capture should create a real markdown asset")
            try expect(item.primaryAssetState == .available, "text capture markdown should report an available primary asset")
            let markdown = try String(contentsOfFile: item.assetPath, encoding: .utf8)
            try expect(markdown.contains(selectedText) && markdown.contains("# \(item.title)"), "captured markdown should contain title and prompt text")
        } else {
            try expect(item.assetPath.isEmpty && item.thumbnailPath.isEmpty, "media capture \(captureID) should not invent an asset path")
            try expect(item.format.isEmpty, "media capture should not pretend to be a real media file")
            try expect(item.isMediaPromptPlaceholder, "media capture should be represented as a placeholder")
        }
        try expect(try service.createCapturedPrompt(WebCaptureCandidate(captureID: captureID, selectedText: selectedText)).id == item.id, "capture should be idempotent")
    }
    try expect(try repository.loadItems().count == candidates.count, "capture retries should not duplicate rows")
}

func testConcurrentTextCaptureLeavesOnlyWinningMarkdownAsset() throws {
    let libraryURL = try temporaryLibraryURL()
    let firstRepository = try PromptRepository(libraryURL: libraryURL)
    let secondRepository = try PromptRepository(libraryURL: libraryURL)
    let services = [
        PromptStudioAutomationService(repository: firstRepository),
        PromptStudioAutomationService(repository: secondRepository)
    ]
    let candidate = WebCaptureCandidate(captureID: "concurrent-text-capture", selectedText: "分析数据并输出 JSON")
    let group = DispatchGroup()
    let state = CaptureRaceState()
    for service in services {
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                state.append(item: try service.createCapturedPrompt(candidate))
            } catch {
                state.append(error: error)
            }
        }
    }
    group.wait()
    try expect(state.errors.isEmpty, "concurrent text capture retries should not fail")
    try expect(state.items.count == 2 && state.items[0].id == state.items[1].id, "concurrent text capture should return one winning item")
    let documentsURL = libraryURL.appendingPathComponent("assets/documents")
    let markdownFiles = try FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension.lowercased() == "md" }
    try expect(markdownFiles.count == 1, "concurrent text capture should clean the losing markdown asset")
}

func testPromptPlaceholderMigrationIsSafeIdempotentAndTransactional() throws {
    let libraryURL = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: libraryURL)
    let image = sampleItem(title: "legacy image", assetKind: .text, prompt: "生成一张图片", assetPath: "", format: "prompt")
    let video = sampleItem(title: "legacy video", assetKind: .text, prompt: "制作 5 秒视频", assetPath: "", format: "TEXT")
    var text = sampleItem(title: "legacy text", assetKind: .text, prompt: "分析数据并输出 JSON", assetPath: "", format: "TEXT")
    text.versions[0].negativePrompt = "制作 5 秒视频"
    var staleThumbnail = video
    staleThumbnail.id = UUID().uuidString
    staleThumbnail.title = "legacy video stale thumbnail"
    staleThumbnail.thumbnailPath = "/tmp/stale-thumbnail.png"
    let realMarkdown = sampleItem(title: "real markdown", assetKind: .markdown, prompt: "生成一张图片", assetPath: "/tmp/real.md", format: "MD")
    let realImage = sampleItem(title: "real image", assetKind: .image, prompt: "生成一张图片", assetPath: "/tmp/real.png", format: "PNG")
    try repository.saveItems([image, video, text, staleThumbnail, realMarkdown, realImage])

    let first = try repository.migratePromptPlaceholders()
    try expect(first.migratedCount == 4, "migration should only touch empty PROMPT/TEXT placeholder candidates")
    try expect(first.failedCount == 0 && first.failures.isEmpty, "successful migration should report no failures")
    let migrated = try repository.loadItems()
    try expect(migrated.first(where: { $0.id == image.id })?.assetKind == .image, "image placeholder should migrate to image asset kind")
    try expect(migrated.first(where: { $0.id == video.id })?.type == .video, "video placeholder should migrate to video type")
    try expect(migrated.first(where: { $0.id == text.id })?.assetKind == .markdown, "text placeholder should migrate to markdown asset kind")
    try expect(migrated.first(where: { $0.id == text.id })?.type == .text, "migration classification should use the positive prompt only")
    try expect(migrated.first(where: { $0.id == text.id })?.format.uppercased() == "MD", "text placeholder should canonicalize to MD")
    guard let migratedText = migrated.first(where: { $0.id == text.id }) else {
        throw CoreUnitTestError.failure("migrated text row should exist")
    }
    try expect(!migratedText.assetPath.isEmpty && FileManager.default.fileExists(atPath: migratedText.assetPath), "text migration should create a markdown asset")
    try expect(try String(contentsOfFile: migratedText.assetPath, encoding: .utf8).contains(text.currentVersion?.prompt ?? ""), "migrated markdown should contain the current prompt")
    try expect(migrated.first(where: { $0.id == staleThumbnail.id })?.thumbnailPath == "", "media migration should clear stale thumbnail paths")
    try expect(migrated.first(where: { $0.id == realMarkdown.id })?.assetKind == .markdown, "real markdown row must not be touched")
    try expect(migrated.first(where: { $0.id == realImage.id })?.assetKind == .image, "real media row must not be touched")
    let second = try repository.migratePromptPlaceholders()
    try expect(second.migratedCount == 0 && second.failedCount == 0, "migration should be idempotent")

    let rollbackURL = try temporaryLibraryURL()
    let rollbackRepository = try PromptRepository(libraryURL: rollbackURL)
    let firstRollbackItem = sampleItem(title: "rollback one", assetKind: .text, prompt: "分析数据并输出 JSON", assetPath: "", format: "PROMPT")
    let secondRollbackItem = sampleItem(title: "rollback two", assetKind: .text, prompt: "分析数据并输出 JSON", assetPath: "", format: "PROMPT")
    try rollbackRepository.saveItems([firstRollbackItem, secondRollbackItem])
    let rollbackDatabaseURL = rollbackURL.appendingPathComponent("database/promptstudio.sqlite")
    let rollbackDatabase = try SQLiteDatabase(path: rollbackDatabaseURL.path)
    try rollbackDatabase.execute("CREATE TRIGGER fail_placeholder_migration BEFORE UPDATE OF assetPath ON prompt_items WHEN NEW.id = '\(firstRollbackItem.id)' BEGIN SELECT RAISE(ABORT, 'migration failure'); END;")
    let rollbackResult = try rollbackRepository.migratePromptPlaceholders()
    try expect(rollbackResult.migratedCount == 1 && rollbackResult.failedCount == 1, "migration should isolate a failed row and continue")
    try expect(rollbackResult.failures.first?.itemID == firstRollbackItem.id, "migration should identify the failed row")
    let rolledBack = try rollbackRepository.loadItems()
    try expect(rolledBack.first(where: { $0.id == firstRollbackItem.id })?.assetKind == .text, "failed migration should roll back the failed row")
    try expect(rolledBack.first(where: { $0.id == secondRollbackItem.id })?.assetKind == .markdown, "migration should commit the successful row")
    let rollbackDocuments = rollbackURL.appendingPathComponent("assets/documents")
    let leftoverMarkdown = (try? FileManager.default.contentsOfDirectory(at: rollbackDocuments, includingPropertiesForKeys: nil)) ?? []
    try expect(leftoverMarkdown.count == 1, "failed migration should leave only the successful markdown file")
    try expect(rolledBack.first(where: { $0.id == firstRollbackItem.id })?.assetPath.isEmpty == true, "failed migration should not persist a file path")
}

do {
    try testLibraryURLResolution()
    try testExistingLibraryValidationDoesNotCreateDatabase()
    try testSearchFiltering()
    try testThumbnailDecodeSizing()
    try testPromptSelectionResolver()
    try testMarqueeSelectionResolver()
    try testPromptItemDragPayload()
    try testSelectionActionContextPreservesFinderStyleMultiSelection()
    try testSelectionActionContextBuildsCompleteDragPayload()
    try testMultiItemDragPreviewPlanKeepsDraggedItemOnTop()
    try testMultiItemDragPreviewPlanCapsVisualsWithoutTruncatingPayload()
    try testFolderSelectionActionContextPreservesVisualOrderAndNormalizesNestedSelection()
    try testFolderDragPayloadRoundTripAndPreviewCap()
    try testFolderBatchMovePlannerRejectsInvalidGroupsAndPreservesLegalOrder()
    try testPromptRepositoryBatchFolderMoveAndDeleteRollback()
    try testPromptItemBatchMovePlanner()
    try testPromptRepositoryBatchDeletedStateRollsBack()
    try testPromptRepositoryBatchPermanentDeleteRollsBack()
    try testFilteringPerformanceWith1000Items()
    try testTextFormatFiltering()
    try testPrimaryPromptAssetsAndAttachments()
    try testTextSyntaxModeInference()
    try testTextSyntaxRulesDetectJSONTokens()
    try testMarkdownHeadingRulesDetectCommonTitleShapes()
    try testMarkdownHeadingRulesAvoidBodyLikeLines()
    try testLargeMarkdownKeepsHeadingHighlightRules()
    try testMarkdownNegativeHighlightRequiresTitle()
    try testFolderFilteringUsesStableFolderID()
    try testSQLiteRoundTrip()
    try testRepositoryBulkSaveLoadPerformanceWith1000Items()
    try testPromptRepositoryBatchFolderUpdatePerformanceWith1000Items()
    try testAssetKindInferenceAndPromptParsing()
    try testAssetFormatCatalogCoversEagleMacOSFormats()
    try testAssetFormatCatalogRepresentativeMappings()
    try testPromptDocumentFormatsExtractMetadata()
    try testAutomationServiceImportsAllKnownFormatFixtures()
    try testUnknownFormatImportsAsGenericFile()
    try testTagRefreshDeletesUnusedTags()
    try testTrashAndRestore()
    try testAspectRatioDisplayNormalizesImportedSizes()
    try testSeedAssetRepairKeepsExistingUserData()
    try testThumbnailPathUpdatePersistsWithoutChangingOriginalAsset()
    try testLastUsedUpdatePersistsForRecentSorting()
    try testPinnedAtDoesNotAffectNormalCollectionSorting()
    try testPinnedAtDoesNotAffectRecentOrTrashSorting()
    try testPinnedAtPersistsAndMigratesFromOldSchema()
    try testWebCaptureCoreContracts()
    try testWebCaptureEventsUseDiscriminatedProtocolPayloads()
    try testCapturedInsertIsAtomicAndNeverReplacesExistingVersions()
    try testCapturedInsertSerializesAcrossRepositoryConnections()
    try testCaptureDefaultsRepairExistingResources()
    try testWebCaptureValidationAndTitleLimit()
    try testWebCaptureSchemaMigrationAddsColumnsAndIndex()
    try testFolderSeedIsIdempotent()
    try testFolderCRUDRoundTrip()
    try testFolderCreatedAtMigratesFromLegacySchema()
    try testAutomationServiceCreatesAndUpdatesPrompts()
    try testAutomationServiceCreatesTypedPromptPlaceholdersAndMarkdown()
    try testAutomationServiceImportsTextMetadata()
    try testDocumentTextExtractorReadsRealDocx()
    try testAutomationServiceImportsRealDocxMetadata()
    try testAutomationServiceImportsImageMetadata()
    try testPromptClipboardInterpreterPreservesPlainTextAndBuildsTitle()
    try testPromptEditorPasteResolverKeepsPlainTextNative()
    try testPromptEditorPasteResolverMatchesOnlyStructuredFields()
    try testPromptClipboardInterpreterTitleCapDoesNotTruncatePrompt()
    try testPromptClipboardInterpreterParsesChineseStructuredFields()
    try testPromptClipboardInterpreterParsesJSON()
    try testPromptClipboardInterpreterInfersFourPromptTypes()
    try testPromptClipboardInterpreterDoesNotTreatRealisticAsWriteIntent()
    try testPromptClipboardInterpreterRecognizesExplicitTargetIntents()
    try testPromptClipboardInterpreterPrefersVideoOutputOverReferenceImage()
    try testPromptClipboardInterpreterKeepsModelAndFormatHintsWeak()
    try testPromptClipboardInterpreterPreservesTagsAndMidjourneyParameters()
    try testPromptClipboardInterpreterLeavesConflictsAndLowConfidenceUnspecified()
    try testPromptClipboardInterpreterHandlesBlankInput()
    try testPromptPasteRouteResolverHonorsPastePriority()
    try testPromptClipboardInterpreterStripsModelAndFormatMetadataFromPrompt()
    try testPromptComposerTypeDecisionPreservesManualConfirmation()
    try testPromptComposerTypeDecisionReturnsPendingForLowConfidenceAndConflicts()
    try testPromptComposerTypeDecisionDelegatesReferenceImageVideoSemantics()
    try testPromptComposerMetadataPolicyUsesExactSameTypeModels()
    try testPromptComposerMetadataPolicyNormalizesTextFormatsAndDefaultsMarkdown()
    try testPromptClipboardInterpreterInfersExplicitTextOutputFormats()
    try testUnifiedPromptTypeClassifierAlwaysResolvesFourTypes()
    try testHomepageSmartPasteAlwaysProducesASelectedComposerType()
    try testPromptItemPrimaryAssetStatesKeepPlaceholdersSeparateFromDocuments()
    try testCapturedPromptUsesUnifiedClassificationAndIsIdempotent()
    try testConcurrentTextCaptureLeavesOnlyWinningMarkdownAsset()
    try testPromptPlaceholderMigrationIsSafeIdempotentAndTransactional()
    try await runReferenceThumbnailServiceTests()
    try testPromptRepositoryBatchFolderUpdateRollsBack()
    try testPromptRepositoryFolderUpdatePreservesVersions()
    print("PromptStudioCoreUnitTests passed")
} catch {
    fputs("PromptStudioCoreUnitTests failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
