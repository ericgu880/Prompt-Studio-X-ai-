import Foundation
import PromptStudioCore

private enum MediaImportFixtureError: Error {
    case unreadable
}

private final class MediaImportConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0

    func enter() {
        lock.lock()
        active += 1
        maximum = max(maximum, active)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        active -= 1
        lock.unlock()
    }

    func maximumValue() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return maximum
    }
}

private func mediaImportFixtureDependencies(
    failingName: String? = nil,
    probe: MediaImportConcurrencyProbe? = nil
) -> MediaImportDependencies {
    MediaImportDependencies(
        resolveAssetKind: { url in
            url.pathExtension.lowercased() == "png" ? .image : .text
        },
        inspectFile: { url, kind in
            if let failingName, url.lastPathComponent.hasSuffix(failingName) {
                throw MediaImportFixtureError.unreadable
            }
            if let probe {
                probe.enter()
                defer { probe.leave() }
                Thread.sleep(forTimeInterval: 0.025)
            }
            let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            return MediaImportFileInfo(
                width: kind == .image ? 128 : 0,
                height: kind == .image ? 96 : 0,
                fileSize: Int64(size),
                format: url.pathExtension.uppercased()
            )
        },
        parsePrompt: { url, kind in
            guard kind.isTextDocumentLike else { return ParsedPromptMetadata() }
            return PromptImportParser.parse(
                text: (try? String(contentsOf: url, encoding: .utf8)) ?? "",
                assetKind: kind
            )
        }
    )
}

private func mediaImportRequest(_ sources: [URL]) -> MediaImportRequest {
    MediaImportRequest(
        sourceFiles: sources,
        targetFolderID: "folder-uncategorized",
        targetFolderName: "未分类",
        acceptedType: nil,
        firstSortOrder: 1,
        modelsByType: [
            PromptType.image.rawValue: MediaImportModel(id: "image_2", name: "GPT Image 2"),
            PromptType.text.rawValue: MediaImportModel(id: "local_asset", name: "Local Asset")
        ]
    )
}

func runMediaImportServiceTests() async throws {
    try await testMediaImportScanSkipsHiddenFilesAndKeepsInputOrder()
    try await testMediaImportUsesBoundedConcurrencyAndStableOrder()
    try await testMediaImportPersists100FilesAndTagsInOneBatch()
    try await testMediaImportContinuesAfterIndividualFailure()
    try await testMediaImportRejectsZeroByteMediaWithoutStoppingTextFiles()
    try await testMediaImportKeepsDuplicateContentAndCountsTypeSkips()
    try await testMediaImportBatchPersistenceRollsBackAndCleansCopies()
    try await testMediaImportCancellationCleansUncommittedCopies()
}

private func testMediaImportKeepsDuplicateContentAndCountsTypeSkips() async throws {
    let libraryURL = try temporaryLibraryURL()
    let sourceRoot = try temporaryLibraryURL()
    let first = sourceRoot.appendingPathComponent("duplicate-a.txt")
    let second = sourceRoot.appendingPathComponent("duplicate-b.txt")
    let skippedImage = sourceRoot.appendingPathComponent("skipped.png")
    let duplicateContent = Data("Prompt: duplicate content".utf8)
    try duplicateContent.write(to: first)
    try duplicateContent.write(to: second)
    try Data([0x01]).write(to: skippedImage)

    let service = MediaImportService(
        libraryURL: libraryURL,
        dependencies: mediaImportFixtureDependencies()
    )
    let baseRequest = mediaImportRequest([first, skippedImage, second])
    let request = MediaImportRequest(
        sourceFiles: baseRequest.sourceFiles,
        targetFolderID: baseRequest.targetFolderID,
        targetFolderName: baseRequest.targetFolderName,
        acceptedType: .text,
        firstSortOrder: baseRequest.firstSortOrder,
        modelsByType: baseRequest.modelsByType
    )
    let result = try await service.importFiles(request) { _ in }

    try expect(result.importedItems.map(\.title) == ["duplicate-a", "duplicate-b"], "same-content files with distinct source paths should remain independent imports")
    try expect(result.skippedCount == 1 && result.failures.isEmpty, "type mismatches should count as skips rather than failures")
    try expect(try PromptRepository(libraryURL: libraryURL).loadItems().count == 2, "duplicate-content imports should both persist")
}

private func testMediaImportRejectsZeroByteMediaWithoutStoppingTextFiles() async throws {
    let libraryURL = try temporaryLibraryURL()
    let sourceRoot = try temporaryLibraryURL()
    let brokenImage = sourceRoot.appendingPathComponent("broken.png")
    let validText = sourceRoot.appendingPathComponent("valid.txt")
    try Data().write(to: brokenImage)
    try Data("Prompt: still imported".utf8).write(to: validText)

    let service = MediaImportService(
        libraryURL: libraryURL,
        dependencies: mediaImportFixtureDependencies()
    )
    let result = try await service.importFiles(mediaImportRequest([brokenImage, validText])) { _ in }

    try expect(result.importedItems.map(\.title) == ["valid"], "zero-byte media should not stop later valid files")
    try expect(result.failures.count == 1 && result.failures[0].fileName == "broken.png", "zero-byte media should be reported as a per-file failure")
}

private func testMediaImportPersists100FilesAndTagsInOneBatch() async throws {
    let libraryURL = try temporaryLibraryURL()
    let sourceRoot = try temporaryLibraryURL()
    let sources = try (0..<100).map { index -> URL in
        let url = sourceRoot.appendingPathComponent(String(format: "%03d.txt", index))
        try Data("Prompt: batch item \(index)\nTags: 批量导入, fixture".utf8).write(to: url)
        return url
    }
    let service = MediaImportService(
        libraryURL: libraryURL,
        maxConcurrentFileTasks: 2,
        dependencies: mediaImportFixtureDependencies()
    )
    let startedAt = ProcessInfo.processInfo.systemUptime
    let result = try await service.importFiles(mediaImportRequest(sources)) { _ in }
    let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
    let reopenedRepository = try PromptRepository(libraryURL: libraryURL)
    let persistedItems = try reopenedRepository.loadItems()
    let persistedTags = try reopenedRepository.loadTags()

    try expect(result.importedItems.count == 100, "100-file batch should return every imported item")
    try expect(persistedItems.count == 100, "100-file batch should survive reopening the repository")
    try expect(persistedTags.contains(where: { $0.name == "批量导入" && $0.count == 100 }), "batch tags should be recomputed once with the final count")
    try expect(persistedItems.map(\.title) == sources.map { $0.deletingPathExtension().lastPathComponent }, "100-file batch should preserve source order")
    print(String(format: "MediaImport 100-file batch: %.2fms prepare=%.2fms persist=%.2fms", elapsedMilliseconds, result.metrics.prepareMilliseconds, result.metrics.persistMilliseconds))
}

private func testMediaImportScanSkipsHiddenFilesAndKeepsInputOrder() async throws {
    let libraryURL = try temporaryLibraryURL()
    let sourceRoot = try temporaryLibraryURL()
    let first = sourceRoot.appendingPathComponent("01.txt")
    let nested = sourceRoot.appendingPathComponent("nested")
    let second = nested.appendingPathComponent("02.txt")
    let hidden = sourceRoot.appendingPathComponent(".hidden.txt")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data("one".utf8).write(to: first)
    try Data("two".utf8).write(to: second)
    try Data("hidden".utf8).write(to: hidden)

    let service = MediaImportService(
        libraryURL: libraryURL,
        dependencies: mediaImportFixtureDependencies()
    )
    let scanned = await service.scan([first, nested, hidden])
    try expect(scanned.map(\.lastPathComponent) == ["01.txt", "02.txt"], "scan should keep input order and skip hidden files")
}

private func testMediaImportUsesBoundedConcurrencyAndStableOrder() async throws {
    let libraryURL = try temporaryLibraryURL()
    let sourceRoot = try temporaryLibraryURL()
    let sources = try (0..<8).map { index -> URL in
        let url = sourceRoot.appendingPathComponent(String(format: "%02d.txt", index))
        try Data("Prompt: item \(index)".utf8).write(to: url)
        return url
    }
    let probe = MediaImportConcurrencyProbe()
    let service = MediaImportService(
        libraryURL: libraryURL,
        maxConcurrentFileTasks: 2,
        dependencies: mediaImportFixtureDependencies(probe: probe)
    )
    let result = try await service.importFiles(mediaImportRequest(sources)) { _ in }
    let maximum = probe.maximumValue()
    try expect(maximum == 2, "import should use exactly two workers when enough files exist")
    try expect(result.importedItems.map(\.title) == sources.map { $0.deletingPathExtension().lastPathComponent }, "concurrent import should preserve source order")
    try expect(result.importedItems.map(\.sortOrder) == Array(1...8), "concurrent import should preserve visual sort order")
    try expect(try PromptRepository(libraryURL: libraryURL).loadItems().count == 8, "batch import should persist every prepared item")
}

private func testMediaImportContinuesAfterIndividualFailure() async throws {
    let libraryURL = try temporaryLibraryURL()
    let sourceRoot = try temporaryLibraryURL()
    let names = ["good-1.txt", "bad.txt", "good-2.txt"]
    let sources = try names.map { name -> URL in
        let url = sourceRoot.appendingPathComponent(name)
        try Data("Prompt: \(name)".utf8).write(to: url)
        return url
    }
    let service = MediaImportService(
        libraryURL: libraryURL,
        dependencies: mediaImportFixtureDependencies(failingName: "bad.txt")
    )
    let result = try await service.importFiles(mediaImportRequest(sources)) { _ in }
    try expect(result.importedItems.map(\.title) == ["good-1", "good-2"], "one unreadable file should not stop later files")
    try expect(result.failures.count == 1 && result.failures[0].fileName == "bad.txt", "failed file should be reported")
    try expect(result.tags.contains(where: { $0.name == "文本" }) == false, "import should not invent tags")
}

private func testMediaImportBatchPersistenceRollsBackAndCleansCopies() async throws {
    let libraryURL = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: libraryURL)
    let database = try SQLiteDatabase(path: repository.databaseURL.path)
    try database.execute(
        "CREATE TRIGGER fail_media_import BEFORE INSERT ON prompt_items WHEN NEW.title = 'fail-db' BEGIN SELECT RAISE(ABORT, 'forced import failure'); END;"
    )
    let sourceRoot = try temporaryLibraryURL()
    let sources = try ["good.txt", "fail-db.txt"].map { name -> URL in
        let url = sourceRoot.appendingPathComponent(name)
        try Data("Prompt: \(name)".utf8).write(to: url)
        return url
    }
    let service = MediaImportService(
        libraryURL: libraryURL,
        dependencies: mediaImportFixtureDependencies()
    )
    do {
        _ = try await service.importFiles(mediaImportRequest(sources)) { _ in }
        throw CoreUnitTestError.failure("forced database failure should escape the import service")
    } catch CoreUnitTestError.failure {
        throw CoreUnitTestError.failure("forced database failure should not be swallowed")
    } catch {
        // Expected SQLite rollback.
    }
    try expect(try repository.loadItems().isEmpty, "database failure should roll back the entire imported batch")
    let dataDirectory = libraryURL.appendingPathComponent("assets/data")
    let leftovers = (try? FileManager.default.contentsOfDirectory(at: dataDirectory, includingPropertiesForKeys: nil)) ?? []
    try expect(leftovers.isEmpty, "database failure should remove copied files from the failed batch")
}

private func testMediaImportCancellationCleansUncommittedCopies() async throws {
    let libraryURL = try temporaryLibraryURL()
    let sourceRoot = try temporaryLibraryURL()
    let sources = try (0..<20).map { index -> URL in
        let url = sourceRoot.appendingPathComponent("cancel-\(index).txt")
        try Data("Prompt: cancel \(index)".utf8).write(to: url)
        return url
    }
    let service = MediaImportService(
        libraryURL: libraryURL,
        maxConcurrentFileTasks: 2,
        dependencies: mediaImportFixtureDependencies(probe: MediaImportConcurrencyProbe())
    )
    let task = Task {
        try await service.importFiles(mediaImportRequest(sources)) { _ in }
    }
    try await Task.sleep(for: .milliseconds(40))
    task.cancel()
    do {
        _ = try await task.value
        throw CoreUnitTestError.failure("cancelled import should throw CancellationError")
    } catch is CancellationError {
        // Expected cancellation.
    }
    let repository = try PromptRepository(libraryURL: libraryURL)
    try expect(try repository.loadItems().isEmpty, "cancelled import must not persist a partial batch")
    let dataDirectory = libraryURL.appendingPathComponent("assets/data")
    let leftovers = (try? FileManager.default.contentsOfDirectory(at: dataDirectory, includingPropertiesForKeys: nil)) ?? []
    try expect(leftovers.isEmpty, "cancelled import should remove files copied before persistence")
}
