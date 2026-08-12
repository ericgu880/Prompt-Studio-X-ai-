import Foundation
import ImageIO
import PromptStudioCore

private final class ReferenceThumbnailTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

private func referenceThumbnailTestLibrary() throws -> URL {
    let library = FileManager.default.temporaryDirectory
        .appendingPathComponent("PromptStudioReferenceThumbnailTests")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    return library
}

private func referenceThumbnailTestImage(at url: URL, width: Int = 2_048, height: Int = 1_024) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        "public.png" as CFString,
        1,
        nil
    ) else {
        throw CoreUnitTestError.failure("reference fixture image should be writable")
    }
    CGImageDestinationAddImage(destination, image, nil)
    try expect(CGImageDestinationFinalize(destination), "reference fixture image should finalize")
}

private func referenceThumbnailTestImageSize(at url: URL) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return nil
    }
    return (image.width, image.height)
}

func testReferenceThumbnailServiceGeneratesBoundedJPEGAndPreservesAspectRatio() async throws {
    let library = try referenceThumbnailTestLibrary()
    let source = library.appendingPathComponent("source.png")
    try referenceThumbnailTestImage(at: source)
    let reference = ReferenceAsset(id: "reference-size", type: "PNG", path: source.path, label: "size")
    let service = await MainActor.run {
        ReferenceThumbnailService(libraryURL: library)
    }

    let thumbnailPath = await service.thumbnail(for: reference, libraryURL: library)
    let expectedURL = ReferenceThumbnailService.thumbnailURL(referenceID: reference.id, libraryURL: library)
    try expect(thumbnailPath == expectedURL, "thumbnail should use the references v1 path")
    let outputURL = thumbnailPath ?? expectedURL
    try expect(outputURL.pathExtension == "jpg", "thumbnail should use the JPEG extension")
    try expect(referenceThumbnailTestImageSize(at: outputURL)?.width == 512, "thumbnail longest edge should be capped at 512 pixels")
    try expect(referenceThumbnailTestImageSize(at: outputURL)?.height == 256, "thumbnail should preserve the source aspect ratio")
}

func testReferenceThumbnailServiceMergesConcurrentRequests() async throws {
    let library = try referenceThumbnailTestLibrary()
    let source = library.appendingPathComponent("source.png")
    try referenceThumbnailTestImage(at: source, width: 400, height: 200)
    let reference = ReferenceAsset(id: "reference-dedupe", type: "PNG", path: source.path, label: "dedupe")
    let counter = ReferenceThumbnailTestCounter()
    let service = await MainActor.run {
        ReferenceThumbnailService(
            libraryURL: library,
            generator: { sourceURL, destinationURL in
                counter.increment()
                Thread.sleep(forTimeInterval: 0.05)
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            }
        )
    }

    let paths = await withTaskGroup(of: URL?.self, returning: [URL?].self) { group in
        for _ in 0..<8 {
            group.addTask {
                await service.thumbnail(for: reference, libraryURL: library, priority: .userInitiated)
            }
        }
        var results: [URL?] = []
        for await result in group {
            results.append(result)
        }
        return results
    }

    try expect(paths.count == 8 && paths.allSatisfy { $0 == paths.first }, "concurrent requests should resolve to one thumbnail path")
    try expect(counter.value == 1, "concurrent requests for one source version should generate once")
}

func testReferenceThumbnailServiceRebuildsCorruptThumbnail() async throws {
    let library = try referenceThumbnailTestLibrary()
    let source = library.appendingPathComponent("source.png")
    try referenceThumbnailTestImage(at: source, width: 400, height: 200)
    let reference = ReferenceAsset(id: "reference-corrupt", type: "PNG", path: source.path, label: "corrupt")
    let counter = ReferenceThumbnailTestCounter()
    let service = await MainActor.run {
        ReferenceThumbnailService(
            libraryURL: library,
            generator: { sourceURL, destinationURL in
                counter.increment()
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            }
        )
    }

    let first = await service.thumbnail(for: reference, libraryURL: library)
    try expect(first != nil, "first thumbnail should generate")
    try Data("corrupt".utf8).write(to: first!)
    let second = await service.thumbnail(for: reference, libraryURL: library)
    try expect(second == first, "rebuilding a corrupt thumbnail should retain its stable path")
    try expect(counter.value == 2, "corrupt thumbnails should trigger a rebuild")
    try expect(referenceThumbnailTestImageSize(at: second!) != nil, "rebuilt thumbnail should decode")
}

func testReferenceThumbnailServiceRebuildsWhenSourceIsNewerThanThumbnail() async throws {
    let library = try referenceThumbnailTestLibrary()
    let source = library.appendingPathComponent("source.png")
    try referenceThumbnailTestImage(at: source, width: 400, height: 200)
    let reference = ReferenceAsset(id: "reference-stale", type: "PNG", path: source.path, label: "stale")
    let counter = ReferenceThumbnailTestCounter()
    let service = await MainActor.run {
        ReferenceThumbnailService(
            libraryURL: library,
            generator: { sourceURL, destinationURL in
                counter.increment()
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            }
        )
    }

    _ = await service.thumbnail(for: reference, libraryURL: library)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: 30)],
        ofItemAtPath: source.path
    )
    let rebuilt = await service.thumbnail(for: reference, libraryURL: library)
    try expect(counter.value == 2, "a source newer than its thumbnail should rebuild instead of hitting stale output")
    try expect(rebuilt != nil, "a future-dated source should produce a valid rebuilt thumbnail")
}

func testReferenceThumbnailServiceCleansOrphanedReferenceFiles() async throws {
    let library = try referenceThumbnailTestLibrary()
    let directory = library.appendingPathComponent("thumbnails/references")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let valid = directory.appendingPathComponent("kept-v1.jpg")
    let orphan = directory.appendingPathComponent("orphan-v1.jpg")
    let unrelated = directory.appendingPathComponent("notes.txt")
    try Data("valid".utf8).write(to: valid)
    try Data("orphan".utf8).write(to: orphan)
    try Data("notes".utf8).write(to: unrelated)
    let service = await MainActor.run { ReferenceThumbnailService(libraryURL: library) }

    let removed = try await service.cleanupOrphans(validReferenceIDs: ["kept"], libraryURL: library)
    try expect(removed.count == 1 && removed[0].lastPathComponent == orphan.lastPathComponent, "cleanup should report and remove only orphan v1 reference thumbnails")
    try expect(FileManager.default.fileExists(atPath: valid.path), "cleanup should keep valid reference thumbnails")
    try expect(FileManager.default.fileExists(atPath: unrelated.path), "cleanup should keep unrelated files")
}

func testReferenceThumbnailServiceKeepsCachePathsInsideReferenceDirectory() throws {
    let library = try referenceThumbnailTestLibrary()
    let thumbnail = ReferenceThumbnailService.thumbnailURL(
        referenceID: "../outside/cache",
        libraryURL: library
    )
    let expectedDirectory = library.appendingPathComponent("thumbnails/references").standardizedFileURL.path
    try expect(
        thumbnail.deletingLastPathComponent().standardizedFileURL.path == expectedDirectory,
        "reference IDs must not escape the reference thumbnail directory"
    )
    try expect(!thumbnail.lastPathComponent.contains("/"), "reference thumbnail filenames must not contain path separators")
}

func testReferenceThumbnailServiceCancellationDoesNotPublishOldLibraryOutput() async throws {
    let library = try referenceThumbnailTestLibrary()
    let source = library.appendingPathComponent("source.png")
    try referenceThumbnailTestImage(at: source, width: 400, height: 200)
    let reference = ReferenceAsset(id: "reference-cancel", type: "PNG", path: source.path, label: "cancel")
    let service = await MainActor.run {
        ReferenceThumbnailService(
            libraryURL: library,
            generator: { sourceURL, destinationURL in
                Thread.sleep(forTimeInterval: 0.1)
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            }
        )
    }

    let request = Task { await service.request(reference, priority: .utility) }
    try await Task.sleep(for: .milliseconds(15))
    await service.cancelPendingRequests()
    let result = await request.value
    try expect(result == nil, "cancelled old-library requests should not publish a thumbnail")
    try expect(
        !FileManager.default.fileExists(
            atPath: ReferenceThumbnailService.thumbnailURL(referenceID: reference.id, libraryURL: library).path
        ),
        "cancelled old-library generation must not replace its destination"
    )
}

func runReferenceThumbnailServiceTests() async throws {
    try await testReferenceThumbnailServiceGeneratesBoundedJPEGAndPreservesAspectRatio()
    try await testReferenceThumbnailServiceMergesConcurrentRequests()
    try await testReferenceThumbnailServiceRebuildsCorruptThumbnail()
    try await testReferenceThumbnailServiceRebuildsWhenSourceIsNewerThanThumbnail()
    try await testReferenceThumbnailServiceCleansOrphanedReferenceFiles()
    try testReferenceThumbnailServiceKeepsCachePathsInsideReferenceDirectory()
    try await testReferenceThumbnailServiceCancellationDoesNotPublishOldLibraryOutput()
}
