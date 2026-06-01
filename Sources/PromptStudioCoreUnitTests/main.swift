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

func sampleItem(
    title: String,
    modelId: String = "nano_banana_2",
    assetKind: AssetKind = .image,
    tags: [String] = ["风景"],
    prompt: String,
    aspectRatio: String = "16:9",
    width: Int = 1920,
    height: Int = 1080,
    assetPath: String = "/tmp/mock.png"
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
        format: "PNG",
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

func testSearchFiltering() throws {
    let item = sampleItem(title: "森林露营车", modelId: "midjourney", tags: ["风景", "插画"], prompt: "green camper in a lush forest")
    let other = sampleItem(title: "人物肖像", modelId: "seedream_7", tags: ["人物"], prompt: "editorial portrait")

    try expect(PromptFiltering.apply([item, other], filter: PromptFilter(query: "camper")).map(\.id) == [item.id], "query should match prompt body")
    try expect(PromptFiltering.apply([item, other], filter: PromptFilter(modelId: "seedream_7")).map(\.id) == [other.id], "model filter should isolate Seedream item")
    try expect(PromptFiltering.apply([item, other], filter: PromptFilter(collection: .tag("插画"))).map(\.id) == [item.id], "tag collection should isolate illustration item")
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

func testAssetKindInferenceAndPromptParsing() throws {
    try expect(AssetKind.infer(fileExtension: "mp3") == .audio, "mp3 should import as audio")
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
    let folder = LibraryFolder(id: "folder-1", name: "旧文件夹", parentId: parent.id, type: .image, sortOrder: 3)

    try repository.saveFolder(parent)
    try repository.saveFolder(folder)
    try expect(try repository.loadFolders().contains { $0.parentId == parent.id && $0.name == "旧文件夹" }, "saved child folder should load with parent")

    try repository.renameFolder(id: folder.id, name: "新文件夹")
    try expect(try repository.loadFolders().first { $0.id == folder.id }?.name == "新文件夹", "renamed folder should persist")

    try repository.deleteFolder(id: folder.id)
    try expect(try repository.loadFolders().contains { $0.id == folder.id } == false, "deleted folder should be removed")
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

do {
    try testSearchFiltering()
    try testFolderFilteringUsesStableFolderID()
    try testSQLiteRoundTrip()
    try testAssetKindInferenceAndPromptParsing()
    try testTagRefreshDeletesUnusedTags()
    try testTrashAndRestore()
    try testAspectRatioDisplayNormalizesImportedSizes()
    try testSeedAssetRepairKeepsExistingUserData()
    try testThumbnailPathUpdatePersistsWithoutChangingOriginalAsset()
    try testLastUsedUpdatePersistsForRecentSorting()
    try testFolderSeedIsIdempotent()
    try testFolderCRUDRoundTrip()
    try testAutomationServiceCreatesAndUpdatesPrompts()
    try testAutomationServiceImportsTextMetadata()
    try testAutomationServiceImportsImageMetadata()
    print("PromptStudioCoreUnitTests passed")
} catch {
    fputs("PromptStudioCoreUnitTests failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
