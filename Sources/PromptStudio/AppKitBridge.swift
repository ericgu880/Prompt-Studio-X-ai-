import AppKit
import AVFoundation
import Foundation
import PromptStudioCore
import UniformTypeIdentifiers

enum AppKitBridge {
    enum ImageExportFormat {
        case png
        case jpeg
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func copyFileToPasteboard(path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let url = URL(fileURLWithPath: path)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let wroteFile = pasteboard.writeObjects([url as NSURL])
        pasteboard.setPropertyList([path], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        return wroteFile
    }

    static func pasteboardFileURLs() -> [URL] {
        let pasteboard = NSPasteboard.general
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] {
            return urls.map { $0 as URL }
        }
        return []
    }

    @MainActor
    static func chooseImportFiles(acceptedType: PromptType? = nil) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "导入 PromptStudio 素材"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        switch acceptedType {
        case .image:
            panel.allowedContentTypes = [.image]
        case .video:
            panel.allowedContentTypes = [.movie, .video]
        case .audio:
            panel.allowedContentTypes = [.audio]
        case .text:
            panel.allowedContentTypes = [
                .text,
                .json,
                .commaSeparatedText,
                .plainText,
                .utf8PlainText,
                UTType(filenameExtension: "doc") ?? .data,
                UTType(filenameExtension: "docx") ?? .data
            ]
        case nil:
            panel.allowedContentTypes = [.item]
        }
        return panel.runModal() == .OK ? panel.urls : []
    }

    @MainActor
    static func chooseReferenceImages() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "选择参考图"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        return panel.runModal() == .OK ? panel.urls : []
    }

    @MainActor
    static func chooseReferenceAssets() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "选择参考资产"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .audio, .movie, .video]
        return panel.runModal() == .OK ? panel.urls : []
    }

    @MainActor
    static func chooseExportDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择导出目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func chooseExportURL(defaultName: String, allowedContentType: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.title = "导出"
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [allowedContentType]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openDefaultApplication(path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        return NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func writeImage(from source: URL, to target: URL, format: ImageExportFormat) throws {
        guard let image = NSImage(contentsOf: source),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let fileType: NSBitmapImageRep.FileType
        let properties: [NSBitmapImageRep.PropertyKey: Any]
        switch format {
        case .png:
            fileType = .png
            properties = [:]
        case .jpeg:
            fileType = .jpeg
            properties = [.compressionFactor: 0.92]
        }

        guard let data = bitmap.representation(using: fileType, properties: properties) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: target, options: .atomic)
    }

    static func writeImagePDF(from source: URL, to target: URL) throws {
        guard let image = NSImage(contentsOf: source) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var mediaBox = CGRect(origin: .zero, size: image.size)
        guard let consumer = CGDataConsumer(url: target as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
    }

    static func writeDocx(text: String, to target: URL) throws {
        let font = NSFont(name: "PingFang SC", size: 14) ?? .systemFont(ofSize: 14)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.textColor
            ]
        )
        let data = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        )
        try data.write(to: target, options: .atomic)
    }

    static func readDocumentText(from url: URL) -> String? {
        DocumentTextExtractor.readText(from: url)
    }

    static func openPreview(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @MainActor
    static func isTextInputActive() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is NSTextView || responder is NSTextField {
            return true
        }
        return String(describing: type(of: responder)).contains("Text")
    }

    @MainActor
    static func zoomKeyWindow() {
        NSApp.keyWindow?.zoom(nil)
    }

    static func imageInfo(for url: URL) -> (width: Int, height: Int, fileSize: Int64, format: String) {
        fileInfo(for: url, assetKind: assetKind(for: url))
    }

    static func fileInfo(for url: URL, assetKind: AssetKind) -> (width: Int, height: Int, fileSize: Int64, format: String) {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let fileSize = attributes[.size] as? Int64 ?? 0
        let format = url.pathExtension.uppercased()
        if assetKind == .video, let videoSize = videoSize(for: url) {
            return (videoSize.width, videoSize.height, fileSize, format.isEmpty ? "MOV" : format)
        }
        if assetKind == .image, let image = NSImage(contentsOf: url), let representation = image.representations.first {
            return (representation.pixelsWide, representation.pixelsHigh, fileSize, format)
        }
        return (0, 0, fileSize, format.isEmpty ? "FILE" : format)
    }

    static func assetKind(for url: URL) -> AssetKind {
        let ext = url.pathExtension.lowercased()
        let catalogKind = AssetFormatCatalog.support(forFileExtension: ext).assetKind
        if catalogKind != .unknown {
            return catalogKind
        }
        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            if contentType.conforms(to: .image) { return .image }
            if contentType.conforms(to: .movie) || contentType.conforms(to: .video) { return .video }
            if contentType.conforms(to: .audio) { return .audio }
            if contentType.conforms(to: .json) { return .json }
            if contentType.conforms(to: .text) {
                return AssetKind.infer(fileExtension: ext) == .markdown ? .markdown : .text
            }
            if contentType.conforms(to: .pdf) {
                return .document
            }
        }
        return AssetKind.infer(fileExtension: ext)
    }

    private static func videoSize(for url: URL) -> (width: Int, height: Int)? {
        guard AssetFormatCatalog.support(forFileExtension: url.pathExtension).assetKind == .video else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        let transformedSize = track.naturalSize.applying(track.preferredTransform)
        let width = Int(abs(transformedSize.width).rounded())
        let height = Int(abs(transformedSize.height).rounded())
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }
}
