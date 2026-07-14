import Foundation

public enum ThumbnailDecodeSizing {
    public static let pixelBuckets = [256, 512, 1024]

    public static func bucket(for requestedPixels: Int) -> Int {
        let requested = max(1, requestedPixels)
        return pixelBuckets.first(where: { $0 >= requested }) ?? pixelBuckets[pixelBuckets.count - 1]
    }

    public static func reusableBuckets(for requestedPixels: Int) -> [Int] {
        let requestedBucket = bucket(for: requestedPixels)
        return pixelBuckets.filter { $0 >= requestedBucket }
    }
}
