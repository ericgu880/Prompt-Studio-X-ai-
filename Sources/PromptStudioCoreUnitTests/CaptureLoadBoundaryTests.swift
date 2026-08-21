import CryptoKit
import Foundation
import PromptStudioCore

func testCapturedCreateAndDuplicateAvoidFullItemHydration() throws {
    let libraryURL = try temporaryLibraryURL()
    defer { try? FileManager.default.removeItem(at: libraryURL) }

    let repository = try PromptRepository(libraryURL: libraryURL)
    let service = PromptStudioAutomationService(repository: repository)
    let textCandidate = WebCaptureCandidate(
        captureID: "capture-load-boundary-text",
        selectedText: "分析数据并输出 JSON",
        pageTitle: "Text capture"
    )

    let textCreateObservation = PromptRepositoryLoadInstrumentation.beginObservation(for: libraryURL)
    let textItem = try service.createCapturedPrompt(textCandidate)
    try expect(textItem.type == .text && textItem.assetKind == .markdown, "new text capture should preserve text semantics")
    try expect(textItem.sortOrder == -1, "first text capture should use the empty-library top sort order")
    try expect(textCreateObservation.delta == 0, "new text capture must not hydrate all prompt items")

    let textDuplicateObservation = PromptRepositoryLoadInstrumentation.beginObservation(for: libraryURL)
    let textRetry = try service.createCapturedPrompt(textCandidate)
    try expect(textRetry.id == textItem.id, "duplicate text capture should return the original item")
    try expect(textDuplicateObservation.delta == 0, "duplicate text capture must not hydrate all prompt items")

    let textFindObservation = PromptRepositoryLoadInstrumentation.beginObservation(for: libraryURL)
    let foundText = try repository.findItem(captureID: textCandidate.captureID)
    try expect(foundText == textItem, "capture point lookup should preserve the saved text item")
    try expect(textFindObservation.delta == 0, "capture point lookup must not hydrate all prompt items")

    let imageData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")!
    let stagedImageURL = libraryURL.appendingPathComponent("staged.png")
    try imageData.write(to: stagedImageURL)
    let imageCandidate = WebImageCaptureCandidate(
        captureID: "capture-load-boundary-image",
        domSourceKind: .image,
        acquisitionMethod: .loadedBytes,
        sha256: SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined(),
        originalFileName: "forest.png",
        byteCount: Int64(imageData.count),
        pixelWidth: 1,
        pixelHeight: 1
    )

    let imageCreateObservation = PromptRepositoryLoadInstrumentation.beginObservation(for: libraryURL)
    let imageItem = try service.createCapturedImage(imageCandidate, stagedFileURL: stagedImageURL)
    try expect(imageItem.type == .image && imageItem.assetKind == .image, "new image capture should preserve image semantics")
    try expect(imageItem.sortOrder == -2, "second image capture should use the scalar top sort order")
    try expect(imageCreateObservation.delta == 0, "new image capture must not hydrate all prompt items")

    let imageDuplicateObservation = PromptRepositoryLoadInstrumentation.beginObservation(for: libraryURL)
    let imageRetry = try service.createCapturedImage(imageCandidate, stagedFileURL: stagedImageURL)
    try expect(imageRetry.id == imageItem.id, "duplicate image capture should return the original item")
    try expect(imageDuplicateObservation.delta == 0, "duplicate image capture must not hydrate all prompt items")
}

func testAutomationCreateTextAndImageAvoidFullItemHydration() throws {
    let libraryURL = try temporaryLibraryURL()
    defer { try? FileManager.default.removeItem(at: libraryURL) }

    let repository = try PromptRepository(libraryURL: libraryURL)
    let service = PromptStudioAutomationService(repository: repository)

    let textObservation = PromptRepositoryLoadInstrumentation.beginObservation(for: libraryURL)
    let textItem = try service.createPrompt(
        AutomationCreatePromptInput(title: "Created text", prompt: "分析数据并输出 JSON")
    )
    try expect(textItem.type == .text && textItem.assetKind == .markdown, "normal text create should preserve text semantics")
    try expect(textItem.sortOrder == -1, "normal text create should use scalar top sort order")
    try expect(textObservation.delta == 0, "normal text create must not hydrate all prompt items")

    let imageObservation = PromptRepositoryLoadInstrumentation.beginObservation(for: libraryURL)
    let imageItem = try service.createPrompt(
        AutomationCreatePromptInput(title: "Created image", prompt: "生成一张照片，柔和光线")
    )
    try expect(imageItem.type == .image && imageItem.assetKind == .image, "normal image create should preserve image semantics")
    try expect(imageItem.sortOrder == -2, "normal image create should use scalar top sort order")
    try expect(imageObservation.delta == 0, "normal image create must not hydrate all prompt items")
}
