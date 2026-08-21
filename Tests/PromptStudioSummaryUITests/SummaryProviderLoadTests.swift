import Foundation
import AppKit
import Testing
@testable import PromptStudio

@Test("Summary provider load state is pre-cancelled, single-flight, and bounded without a callback")
func summaryProviderLoadStateMachine() async {
    let preCancelled = ProviderLoadController()
    #expect(preCancelled.preCancel())
    #expect(preCancelled.begin() == nil)

    let controller = ProviderLoadController()
    let token = controller.begin()
    #expect(token != nil)
    #expect(controller.begin() == nil)
    #expect(controller.preCancel(token: token))
    #expect(controller.state == .preCancelled)
    #expect(!controller.complete(token: token ?? 0))

    let timeoutController = ProviderLoadController()
    let startedAt = ContinuousClock.now
    let result = await SummaryProviderLoader.load(
        timeoutNanoseconds: 20_000_000,
        controller: timeoutController
    ) { _ in
        // Deliberately never call the provider completion. The timeout task
        // must settle the checked continuation instead of hanging the test.
    }
    let elapsed = startedAt.duration(to: .now)
    #expect(result == .failure(.timeout))
    #expect(timeoutController.state == .timedOut)
    #expect(elapsed < .seconds(1))
    #expect(!timeoutController.complete(token: 1))
}

@Test("Summary provider callback publishes once and late callback is fail-closed")
func summaryProviderLoadPublishesOnce() async {
    let controller = ProviderLoadController()
    let result = await SummaryProviderLoader.load(
        timeoutNanoseconds: 500_000_000,
        controller: controller
    ) { completion in
        completion(Data("item-id-1".utf8), nil)
        completion(Data("late".utf8), nil)
    }
    #expect(result == .success(Data("item-id-1".utf8)))
    #expect(controller.state == .completed)
}

@Test("Summary provider timeout publishes once and a late callback cannot publish again")
func summaryProviderTimeoutRejectsLatePublication() async {
    let controller = ProviderLoadController()
    let count = LockedPublicationCount()
    let callbackBox = LateCallbackBox()
    let result = await SummaryProviderLoader.load(
        timeoutNanoseconds: 20_000_000,
        controller: controller,
        onPublication: { _ in count.increment() }
    ) { callback in
        callbackBox.store(callback)
    }
    #expect(result == .failure(.timeout))
    #expect(count.value == 1)

    callbackBox.callback?(Data("late".utf8), nil)
    #expect(count.value == 1)
    #expect(!controller.complete(token: 1))
}

@Test("provider cancellation racing timeout installation settles without an orphan publication")
func summaryProviderCancellationRacingTimeoutInstallation() async {
    let task = Task {
        await SummaryProviderLoader.load(timeoutNanoseconds: 500_000_000) { _ in }
    }
    task.cancel()
    let result = await task.value
    #expect(result == .failure(.preCancelled) || result == .failure(.cancelled))
}

@MainActor
@Test("valid PNG decode is generation-scoped: canceled old result is not cached, new result is cached")
func summaryThumbnailGenerationCancellation() async throws {
    let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 2,
        pixelsHigh: 2,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    let png = representation.representation(using: .png, properties: [:])!
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("summary-thumbnail-(UUID().uuidString).png")
    try png.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let cache = SharedThumbnailImageCache.shared
    let gate = SharedThumbnailImageCache.decodeGate
    await gate.reset()
    await gate.block(path: url.path)

    let oldRequest = ThumbnailImageRequest(path: url.path, contentVersion: 1, maxPixelSize: 64)
    let oldLoader = SharedThumbnailImageLoader()
    let oldTask = Task { @MainActor in await oldLoader.load(oldRequest) }
    await gate.waitUntilEntered(path: url.path)
    oldTask.cancel()
    await gate.release(path: url.path)
    await oldTask.value
    #expect(oldLoader.image == nil)
    #expect(cache.cachedImage(for: oldRequest) == nil)

    let newRequest = ThumbnailImageRequest(path: url.path, contentVersion: 2, maxPixelSize: 64)
    let newLoader = SharedThumbnailImageLoader()
    let newTask = Task { @MainActor in await newLoader.load(newRequest) }
    await newTask.value
    #expect(newLoader.image != nil)
    #expect(cache.cachedImage(for: newRequest) != nil)
    await gate.reset()
}

@MainActor
@Test("late canceled thumbnail result cannot use an unrelated path waiter for cache admission")
func summaryThumbnailCacheAdmissionIsRequestScoped() async throws {
    let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 2,
        pixelsHigh: 2,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    let png = representation.representation(using: .png, properties: [:])!
    let oldURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("summary-thumbnail-old-\(UUID().uuidString).png")
    let newURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("summary-thumbnail-new-\(UUID().uuidString).png")
    try png.write(to: oldURL)
    try png.write(to: newURL)
    defer {
        try? FileManager.default.removeItem(at: oldURL)
        try? FileManager.default.removeItem(at: newURL)
    }

    let cache = SharedThumbnailImageCache.shared
    let gate = SharedThumbnailImageCache.decodeGate
    await gate.reset()
    await gate.block(path: oldURL.path)
    await gate.block(path: newURL.path)

    let oldRequest = ThumbnailImageRequest(path: oldURL.path, contentVersion: 1, maxPixelSize: 64)
    let oldLoader = SharedThumbnailImageLoader()
    let oldTask = Task { @MainActor in await oldLoader.load(oldRequest) }
    await gate.waitUntilEntered(path: oldURL.path)
    oldTask.cancel()

    let newRequest = ThumbnailImageRequest(path: newURL.path, contentVersion: 1, maxPixelSize: 64)
    let newLoader = SharedThumbnailImageLoader()
    let newTask = Task { @MainActor in await newLoader.load(newRequest) }
    await gate.waitUntilEntered(path: newURL.path)

    // The old decode finishes while only an unrelated path has a live waiter.
    await gate.release(path: oldURL.path)
    await oldTask.value
    #expect(oldLoader.image == nil)
    #expect(cache.cachedImage(for: oldRequest) == nil)

    await gate.release(path: newURL.path)
    await newTask.value
    #expect(newLoader.image != nil)
    #expect(cache.cachedImage(for: newRequest) != nil)
    await gate.reset()
}

private final class LockedPublicationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class LateCallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: (@Sendable (Data?, Error?) -> Void)?

    var callback: (@Sendable (Data?, Error?) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func store(_ callback: @escaping @Sendable (Data?, Error?) -> Void) {
        lock.lock()
        storage = callback
        lock.unlock()
    }
}
