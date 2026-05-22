import AppKit
import AVFoundation
import Foundation
import ImageIO
import PromptStudioCore
import UniformTypeIdentifiers

enum ThumbnailService {
    static let maxPixelSize = 900

    static func thumbnailURL(itemID: String, libraryURL: URL) -> URL {
        libraryURL
            .appendingPathComponent("thumbnails")
            .appendingPathComponent(itemID + ".jpg")
    }

    static func existingThumbnailPath(for item: PromptItem, libraryURL: URL) -> String? {
        let thumbnailURL = thumbnailURL(itemID: item.id, libraryURL: libraryURL)
        if FileManager.default.fileExists(atPath: thumbnailURL.path) {
            return thumbnailURL.path
        }
        if !item.thumbnailPath.isEmpty,
           item.thumbnailPath != item.assetPath,
           FileManager.default.fileExists(atPath: item.thumbnailPath) {
            return item.thumbnailPath
        }
        return nil
    }

    @discardableResult
    static func generateThumbnail(for item: PromptItem, libraryURL: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: item.assetPath) else { return nil }

        let sourceURL = URL(fileURLWithPath: item.assetPath)
        let destinationURL = thumbnailURL(itemID: item.id, libraryURL: libraryURL)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return destinationURL.path
        }

        if item.type == .video {
            return try generateVideoThumbnail(from: sourceURL, to: destinationURL)
        }

        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(
                destinationURL as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else {
            return nil
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.82
        ]
        CGImageDestinationAddImage(destination, thumbnail, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return destinationURL.path
    }

    private static func generateVideoThumbnail(from sourceURL: URL, to destinationURL: URL) throws -> String? {
        let asset = AVURLAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)

        let image: CGImage
        do {
            image = try generator.copyCGImage(at: time, actualTime: nil)
        } catch {
            image = try generator.copyCGImage(at: .zero, actualTime: nil)
        }

        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.82
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return destinationURL.path
    }

    static func generateThumbnailsSynchronously(for candidates: [PromptItem], libraryURL: URL) -> [(String, String)] {
        var generated: [(String, String)] = []
        for item in candidates {
            if let path = try? generateThumbnail(for: item, libraryURL: libraryURL) {
                generated.append((item.id, path))
            }
        }
        return generated
    }
}

@MainActor
protocol ThumbnailGenerationReceiver: AnyObject {
    func thumbnailGenerationDidFinish(_ generated: [(String, String)], generationID: UUID)
}

@MainActor
final class ThumbnailGenerationCenter {
    static let shared = ThumbnailGenerationCenter()

    private init() {}

    func start(
        candidates: [PromptItem],
        libraryURL: URL,
        generationID: UUID,
        receiver: ThumbnailGenerationReceiver
    ) {
        let receiverBox = WeakThumbnailGenerationReceiver(receiver)
        DispatchQueue.global(qos: .utility).async {
            let generated = ThumbnailService.generateThumbnailsSynchronously(for: candidates, libraryURL: libraryURL)
            DispatchQueue.main.async {
                receiverBox.receiver?.thumbnailGenerationDidFinish(generated, generationID: generationID)
            }
        }
    }
}

private final class WeakThumbnailGenerationReceiver: @unchecked Sendable {
    weak var receiver: ThumbnailGenerationReceiver?

    init(_ receiver: ThumbnailGenerationReceiver) {
        self.receiver = receiver
    }
}
