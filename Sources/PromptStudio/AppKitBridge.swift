import AppKit
import AVFoundation
import Foundation
import PromptStudioCore
import UniformTypeIdentifiers

enum AppKitBridge {
    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @MainActor
    static func chooseImportFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "导入 PromptStudio 素材"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .webP, .gif, .movie, .text, .json, .commaSeparatedText]
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

    static func openPreview(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
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
