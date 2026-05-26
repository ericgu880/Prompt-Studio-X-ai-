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
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([url as NSURL])
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
            panel.allowedContentTypes = [.png, .jpeg, .webP, .gif]
        case .video:
            panel.allowedContentTypes = [.movie]
        case .text:
            panel.allowedContentTypes = [.text, .json, .commaSeparatedText]
        case nil:
            panel.allowedContentTypes = [.png, .jpeg, .webP, .gif, .movie, .text, .json, .commaSeparatedText]
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
    static func chooseExportDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择导出目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
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

    static func openPreview(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @MainActor
    static func zoomKeyWindow() {
        NSApp.keyWindow?.zoom(nil)
    }

    static func imageInfo(for url: URL) -> (width: Int, height: Int, fileSize: Int64, format: String) {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let fileSize = attributes[.size] as? Int64 ?? 0
        let format = url.pathExtension.uppercased()
        if let videoSize = videoSize(for: url) {
            return (videoSize.width, videoSize.height, fileSize, format.isEmpty ? "MOV" : format)
        }
        if let image = NSImage(contentsOf: url), let representation = image.representations.first {
            return (representation.pixelsWide, representation.pixelsHigh, fileSize, format)
        }
        return (1920, 1080, fileSize, format.isEmpty ? "PNG" : format)
    }

    private static func videoSize(for url: URL) -> (width: Int, height: Int)? {
        guard ["mp4", "mov", "webm", "m4v"].contains(url.pathExtension.lowercased()) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        let transformedSize = track.naturalSize.applying(track.preferredTransform)
        let width = Int(abs(transformedSize.width).rounded())
        let height = Int(abs(transformedSize.height).rounded())
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }
}
