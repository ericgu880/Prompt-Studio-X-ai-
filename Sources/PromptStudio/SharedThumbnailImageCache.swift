import AppKit
import ImageIO
import PromptStudioCore

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

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 360
        cache.totalCostLimit = 160 * 1024 * 1024
        return cache
    }()
    private var inFlightLoads: [ThumbnailImageRequest: Task<NSImage?, Never>] = [:]

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

    func load(_ request: ThumbnailImageRequest) async {
        representedRequest = request
        if let cached = SharedThumbnailImageCache.shared.cachedImage(for: request) {
            image = cached
            return
        }
        image = nil
        let loaded = await SharedThumbnailImageCache.shared.image(for: request)
        guard !Task.isCancelled, representedRequest == request else { return }
        image = loaded
    }
}
