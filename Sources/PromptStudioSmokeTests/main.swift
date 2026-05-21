import Foundation
import PromptStudioCore

@discardableResult
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws -> Bool {
    if try condition() {
        return true
    }
    throw SmokeTestError.failure(message)
}

enum SmokeTestError: Error, LocalizedError {
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
        type: .image,
        modelId: modelId,
        modelName: modelId,
        folderName: "PromptStudio",
        category: "图片 Prompt",
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
        .appendingPathComponent("PromptStudioSmokeTests")
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

func testSQLiteRoundTrip() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let item = sampleItem(title: "版本测试", prompt: "initial prompt")

    try repository.saveItem(item)
    var loaded = try repository.loadItems()
    try expect(loaded.count == 1, "repository should load one saved item")
    try expect(loaded[0].versions.first?.prompt == "initial prompt", "initial version should persist")

    loaded[0].versions.append(
        PromptVersion(promptItemId: loaded[0].id, version: "V1.1", prompt: "updated prompt", note: "edit")
    )
    try repository.saveItem(loaded[0])

    let reloaded = try repository.loadItems()
    try expect(reloaded[0].versions.count == 2, "new version should persist")
    try expect(reloaded[0].currentVersion?.prompt == "updated prompt", "current version should be latest")
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

do {
    try testSearchFiltering()
    try testSQLiteRoundTrip()
    try testTrashAndRestore()
    try testAspectRatioDisplayNormalizesImportedSizes()
    try testSeedAssetRepairKeepsExistingUserData()
    print("PromptStudioSmokeTests passed")
} catch {
    fputs("PromptStudioSmokeTests failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
