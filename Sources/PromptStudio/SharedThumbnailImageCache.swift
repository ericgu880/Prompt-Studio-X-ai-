import AppKit
import ImageIO
import PromptStudioCore

/// Deterministic decode barrier used by the attached Summary tests.  It is
/// also a useful diagnostic seam: production decoding remains ImageIO-backed,
/// while a test can hold one generation after the valid file has been opened.
actor SharedThumbnailDecodeGate {
    private var blockedPaths: Set<String> = []
    private var enteredPaths: Set<String> = []
    private var releaseWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var enteredWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func reset() {
        blockedPaths.removeAll()
        enteredPaths.removeAll()
        let pending = releaseWaiters.values.flatMap { $0 }
        releaseWaiters.removeAll()
        pending.forEach { $0.resume() }
        let entered = enteredWaiters.values.flatMap { $0 }
        enteredWaiters.removeAll()
        entered.forEach { $0.resume() }
    }

    func block(path: String) {
        blockedPaths.insert(path)
    }

    func waitIfBlocked(path: String) async {
        guard blockedPaths.contains(path) else { return }
        enteredPaths.insert(path)
        let waiters = enteredWaiters.removeValue(forKey: path) ?? []
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters[path, default: []].append(continuation)
        }
    }

    func waitUntilEntered(path: String) async {
        if enteredPaths.contains(path) { return }
        await withCheckedContinuation { continuation in
            enteredWaiters[path, default: []].append(continuation)
        }
    }

    func release(path: String) {
        blockedPaths.remove(path)
        let waiters = releaseWaiters.removeValue(forKey: path) ?? []
        waiters.forEach { $0.resume() }
    }
}

struct ThumbnailImageRequest: Hashable, Sendable {
    let path: String
    let contentVersion: TimeInterval
    let pixelBucket: Int

    init(path: String, contentVersion: TimeInterval, maxPixelSize: Int) {
        self.path = path
        self.contentVersion = contentVersion
        pixelBucket = ThumbnailDecodeSizing.bucket(for: maxPixelSize)
    }

    func replacingBucket(_ bucket: Int) -> ThumbnailImageRequest {
        ThumbnailImageRequest(path: path, contentVersion: contentVersion, maxPixelSize: bucket)
    }

    var cacheKey: NSString {
        "\(path)|\(contentVersion)|\(pixelBucket)" as NSString
    }
}

@MainActor
final class SharedThumbnailImageCache {
    static let shared = SharedThumbnailImageCache()
    nonisolated static let decodeGate = SharedThumbnailDecodeGate()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 360
        cache.totalCostLimit = 160 * 1024 * 1024
        return cache
    }()
    private var inFlightLoads: [ThumbnailImageRequest: Task<NSImage?, Never>] = [:]
    /// Cache admission is bound to the exact request being decoded. A live
    /// waiter for another path/content version must never keep a canceled
    /// result eligible for insertion.
    private var liveWaiters: [ThumbnailImageRequest: Set<UUID>] = [:]

    func cachedImage(for request: ThumbnailImageRequest) -> NSImage? {
        for bucket in ThumbnailDecodeSizing.reusableBuckets(for: request.pixelBucket) {
            let candidate = request.replacingBucket(bucket)
            if let image = cache.object(forKey: candidate.cacheKey) {
                DebugPerformanceProbe.record("image.cache.hit")
                return image
            }
        }
        DebugPerformanceProbe.record("image.cache.miss")
        return nil
    }

    func image(for request: ThumbnailImageRequest) async -> NSImage? {
        guard !request.path.isEmpty else { return nil }
        if let cached = cachedImage(for: request) {
            return cached
        }
        for bucket in ThumbnailDecodeSizing.reusableBuckets(for: request.pixelBucket) {
            let candidate = request.replacingBucket(bucket)
            if let task = inFlightLoads[candidate] {
                return await task.value
            }
        }

        let task = Task.detached(priority: .utility) {
            let start = DebugPerformanceProbe.now()
            await Self.decodeGate.waitIfBlocked(path: request.path)
            let image = Self.decodeThumbnail(at: request.path, maxPixelSize: request.pixelBucket)
            DebugPerformanceProbe.recordDuration("image.decode.ms", startedAt: start)
            return image
        }
        inFlightLoads[request] = task
        let image = await task.value
        inFlightLoads[request] = nil
        if let image {
            cache.setObject(image, forKey: request.cacheKey, cost: Self.cacheCost(for: image))
        }
        return image
    }

    /// Generation-scoped image load for virtualized Summary cells.  A late
    /// result from a canceled generation is never inserted into the shared
    /// cache unless another live generation is still waiting on the same
    /// decode.
    func image(for request: ThumbnailImageRequest, generation: UUID) async -> NSImage? {
        guard !request.path.isEmpty else { return nil }
        if let cached = cachedImage(for: request) {
            return cached
        }

        let loadRequest = ThumbnailDecodeSizing.reusableBuckets(for: request.pixelBucket)
            .map(request.replacingBucket)
            .first(where: { inFlightLoads[$0] != nil }) ?? request
        addLiveWaiter(generation, for: loadRequest)

        let task: Task<NSImage?, Never>
        if let inFlight = inFlightLoads[loadRequest] {
            task = inFlight
        } else {
            let created = Task.detached(priority: .utility) {
                let start = DebugPerformanceProbe.now()
                await Self.decodeGate.waitIfBlocked(path: loadRequest.path)
                let image = Self.decodeThumbnail(at: loadRequest.path, maxPixelSize: loadRequest.pixelBucket)
                DebugPerformanceProbe.recordDuration("image.decode.ms", startedAt: start)
                return image
            }
            inFlightLoads[loadRequest] = created
            task = created
        }

        let image = await task.value
        inFlightLoads[loadRequest] = nil
        if Task.isCancelled {
            removeLiveWaiter(generation, for: loadRequest)
        }
        // Check the exact request's live waiter set before cache insertion.
        // Task.isCancelled only controls this caller; another live generation
        // may reuse the same decoded request, but an unrelated path may not.
        if let image, hasLiveWaiters(for: loadRequest) {
            cache.setObject(image, forKey: loadRequest.cacheKey, cost: Self.cacheCost(for: image))
        }
        guard !Task.isCancelled, hasLiveWaiter(generation, for: loadRequest) else { return nil }
        removeLiveWaiter(generation, for: loadRequest)
        return image
    }

    func cancelGeneration(_ generation: UUID) {
        for request in Array(liveWaiters.keys) {
            removeLiveWaiter(generation, for: request)
        }
    }

    private func addLiveWaiter(_ generation: UUID, for request: ThumbnailImageRequest) {
        liveWaiters[request, default: []].insert(generation)
    }

    private func removeLiveWaiter(_ generation: UUID, for request: ThumbnailImageRequest) {
        guard var waiters = liveWaiters[request] else { return }
        waiters.remove(generation)
        if waiters.isEmpty {
            liveWaiters[request] = nil
        } else {
            liveWaiters[request] = waiters
        }
    }

    private func hasLiveWaiter(_ generation: UUID, for request: ThumbnailImageRequest) -> Bool {
        liveWaiters[request]?.contains(generation) == true
    }

    private func hasLiveWaiters(for request: ThumbnailImageRequest) -> Bool {
        !(liveWaiters[request]?.isEmpty ?? true)
    }

    func prefetch(_ requests: [ThumbnailImageRequest]) {
        for request in Set(requests) where cachedImage(for: request) == nil {
            Task { [weak self] in
                _ = await self?.image(for: request)
            }
        }
    }

    private nonisolated static func decodeThumbnail(at path: String, maxPixelSize: Int) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func cacheCost(for image: NSImage) -> Int {
        if let representation = image.representations.first {
            return max(1, representation.pixelsWide * representation.pixelsHigh * 4)
        }
        return max(1, Int(image.size.width * image.size.height * 4))
    }
}

@MainActor
final class SharedThumbnailImageLoader: ObservableObject {
    @Published private(set) var image: NSImage?

    private var representedRequest: ThumbnailImageRequest?
    private var representedGeneration: UUID?

    func load(_ request: ThumbnailImageRequest) async {
        if let previousGeneration = representedGeneration {
            SharedThumbnailImageCache.shared.cancelGeneration(previousGeneration)
        }
        representedRequest = request
        let generation = UUID()
        representedGeneration = generation
        defer {
            SharedThumbnailImageCache.shared.cancelGeneration(generation)
            if representedGeneration == generation {
                representedGeneration = nil
            }
        }
        if let cached = SharedThumbnailImageCache.shared.cachedImage(for: request) {
            image = cached
            return
        }
        image = nil
        let loaded = await SharedThumbnailImageCache.shared.image(for: request, generation: generation)
        guard !Task.isCancelled,
              representedRequest == request,
              representedGeneration == generation else { return }
        image = loaded
    }
}
