import AppKit
import AVFoundation
import Foundation
import ImageIO
import PromptStudioCore
import UniformTypeIdentifiers

enum ThumbnailService {
    static let maxPixelSize = 900
    private static let documentThumbnailVersion = 4

    static func thumbnailURL(itemID: String, libraryURL: URL) -> URL {
        libraryURL
            .appendingPathComponent("thumbnails")
            .appendingPathComponent(itemID + ".jpg")
    }

    static func existingThumbnailPath(for item: PromptItem, libraryURL: URL) -> String? {
        let thumbnailURL = generatedThumbnailURL(for: item, libraryURL: libraryURL)
        if FileManager.default.fileExists(atPath: thumbnailURL.path) {
            return thumbnailURL.path
        }
        guard !item.isTextDocumentLike else { return nil }
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
        guard item.supportsGeneratedThumbnail else { return nil }

        let sourceURL = URL(fileURLWithPath: item.assetPath)
        let destinationURL = generatedThumbnailURL(for: item, libraryURL: libraryURL)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return destinationURL.path
        }

        if item.isTextDocumentLike {
            return try generateMarkdownThumbnail(from: sourceURL, to: destinationURL)
        }

        if item.assetKind == .video {
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

    private static func generatedThumbnailURL(for item: PromptItem, libraryURL: URL) -> URL {
        if item.isTextDocumentLike {
            return libraryURL
                .appendingPathComponent("thumbnails")
                .appendingPathComponent("\(item.id)-doc-v\(documentThumbnailVersion).jpg")
        }
        return thumbnailURL(itemID: item.id, libraryURL: libraryURL)
    }

    private static func generateMarkdownThumbnail(from sourceURL: URL, to destinationURL: URL) throws -> String? {
        let text = AppKitBridge.readDocumentText(from: sourceURL) ?? ""
        let lines = Array(text.components(separatedBy: .newlines).prefix(18))
        let size = NSSize(width: 1280, height: 720)
        let jpeg = Thread.isMainThread
            ? renderMarkdownThumbnail(lines: lines, size: size)
            : DispatchQueue.main.sync { renderMarkdownThumbnail(lines: lines, size: size) }
        guard let jpeg else { return nil }
        try jpeg.write(to: destinationURL, options: .atomic)
        return destinationURL.path
    }

    private static func renderMarkdownThumbnail(lines: [String], size: NSSize) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor(hex: 0x1A1A1A).setFill()
        NSRect(origin: .zero, size: size).fill()

        let panelRect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: panelRect, xRadius: 18, yRadius: 18)
        NSColor(hex: 0x1A1A1A).setFill()
        path.fill()
        NSColor(hex: 0x3D4248).setStroke()
        path.lineWidth = 2
        path.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let lineNumberParagraph = NSMutableParagraphStyle()
        lineNumberParagraph.alignment = .right

        let bodyFont = NSFont(name: "PingFangSC-Regular", size: 25) ?? .systemFont(ofSize: 25)
        let headingFont = NSFont(name: "PingFangSC-Regular", size: 28) ?? .systemFont(ofSize: 28)
        let lineNumberFont = NSFont.monospacedDigitSystemFont(ofSize: 23, weight: .regular)
        let muted = NSColor(hex: 0xBDBEC0)
        let textColor = NSColor(hex: 0xBDBEC0)
        let headingColor = NSColor(hex: 0x41CBE0)
        let listColor = NSColor(hex: 0xFF9F0A)
        let quoteColor = NSColor(hex: 0x37DD61)
        let negativeColor = NSColor(hex: 0xFF5F57)
        let strongColor = NSColor(hex: 0xEEEEEE)

        let lineHeight: CGFloat = 40
        let contentInset: CGFloat = 40
        var y = panelRect.maxY - contentInset - lineHeight
        for (index, rawLine) in lines.enumerated() {
            guard y > panelRect.minY + contentInset else { break }
            let line = rawLine.isEmpty ? " " : rawLine
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            let isHeading = trimmedLine.hasPrefix("#")
            let isList = trimmedLine.hasPrefix("-")
            let isQuote = trimmedLine.hasPrefix(">")
            let isNegative = line.range(
                of: #"负面提示词|负面约束|反向提示词|Negative Prompt|不要|禁止|避免|不出现|不使用|无字幕|无文字|无水印|无logo|无Logo|无LOGO|无品牌|无现代|无多余|无夸张|无脸部崩坏|无身份不一致"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            let hasStrong = line.contains("**")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: isHeading ? headingFont : bodyFont,
                .foregroundColor: thumbnailTextColor(
                    isHeading: isHeading,
                    isList: isList,
                    isQuote: isQuote,
                    isNegative: isNegative,
                    hasStrong: hasStrong,
                    headingColor: headingColor,
                    listColor: listColor,
                    quoteColor: quoteColor,
                    negativeColor: negativeColor,
                    strongColor: strongColor,
                    textColor: textColor
                ),
                .paragraphStyle: paragraph
            ]
            let lineNumberAttributes: [NSAttributedString.Key: Any] = [
                .font: lineNumberFont,
                .foregroundColor: muted,
                .paragraphStyle: lineNumberParagraph
            ]

            NSString(string: "\(index + 1)").draw(
                in: NSRect(x: panelRect.minX + contentInset, y: y, width: 60, height: lineHeight),
                withAttributes: lineNumberAttributes
            )
            NSString(string: line).draw(
                in: NSRect(x: panelRect.minX + 120, y: y, width: panelRect.width - 120 - contentInset, height: lineHeight),
                withAttributes: attributes
            )
            y -= lineHeight
        }

        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
            return nil
        }
        return jpeg
    }

    private static func thumbnailTextColor(
        isHeading: Bool,
        isList: Bool,
        isQuote: Bool,
        isNegative: Bool,
        hasStrong: Bool,
        headingColor: NSColor,
        listColor: NSColor,
        quoteColor: NSColor,
        negativeColor: NSColor,
        strongColor: NSColor,
        textColor: NSColor
    ) -> NSColor {
        if hasStrong { return strongColor }
        if isNegative { return negativeColor }
        if isHeading { return headingColor }
        if isQuote { return quoteColor }
        if isList { return listColor }
        return textColor
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

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xff) / 255.0,
            green: CGFloat((hex >> 8) & 0xff) / 255.0,
            blue: CGFloat(hex & 0xff) / 255.0,
            alpha: alpha
        )
    }
}
