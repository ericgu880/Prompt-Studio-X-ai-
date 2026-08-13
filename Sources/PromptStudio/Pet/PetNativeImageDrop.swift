import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum PetNativeImageDropSupport {
    static let acceptedPasteboardTypes: [NSPasteboard.PasteboardType] = {
        var values = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        values.append(contentsOf: [.fileURL, .URL, .png, .tiff])
        return Array(Set(values))
    }()

    static func canAccept(pasteboardTypeIdentifiers: [String]) -> Bool {
        let offered = Set(pasteboardTypeIdentifiers)
        return acceptedPasteboardTypes.contains { offered.contains($0.rawValue) }
    }

    /// Browser image drags are transferred through the extension's bounded,
    /// tokenized byte channel. AppKit may also advertise the same drag as a
    /// file promise or URL; importing that second representation would cancel
    /// the extension capture ID before its final hit-test can save it.
    static func shouldImportNativeDrop(hasActiveExtensionDrag: Bool) -> Bool {
        !hasActiveExtensionDrag
    }

    static func stageLocalFile(_ sourceURL: URL, in stagingRoot: URL) throws -> URL {
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let extensionValue = sourceURL.pathExtension.isEmpty ? "img" : sourceURL.pathExtension.lowercased()
        let destination = stagingRoot.appendingPathComponent("native-\(UUID().uuidString).\(extensionValue)")
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    static func candidate(
        for stagedURL: URL,
        sourceURL: URL? = nil,
        captureID: String = "native-image-\(UUID().uuidString)"
    ) throws -> PetImageCaptureCandidate {
        let data = try Data(contentsOf: stagedURL, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let imageSource = CGImageSourceCreateWithData(data as CFData, nil)
        let properties = imageSource.flatMap {
            CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
        }
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        let mimeType = UTType(filenameExtension: stagedURL.pathExtension)?.preferredMIMEType
        return PetImageCaptureCandidate(
            captureID: captureID,
            resourceURL: sourceURL?.absoluteString,
            originalFileName: sourceURL?.lastPathComponent.isEmpty == false
                ? (sourceURL?.lastPathComponent ?? stagedURL.lastPathComponent)
                : stagedURL.lastPathComponent,
            domSourceKind: "image",
            acquisitionMethod: "loadedBytes",
            mimeType: mimeType,
            byteCount: Int64(data.count),
            sha256: digest,
            pixelWidth: width,
            pixelHeight: height,
            capturedAt: Date()
        )
    }

    static func imageData(from pasteboard: NSPasteboard) -> Data? {
        if let data = pasteboard.data(forType: .png), !data.isEmpty { return data }
        if let data = pasteboard.data(forType: .tiff), !data.isEmpty { return data }
        return nil
    }
}

@MainActor
final class PetNativeDropView: NSView {
    var shouldImportDrop: (() -> Bool)?
    var onDropFile: ((URL, URL?) -> Void)?
    var onDropData: ((Data, String) -> Void)?
    var onDropRemoteURL: ((URL) -> Void)?

    init(contentView: NSView) {
        super.init(frame: contentView.frame)
        addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        registerForDraggedTypes(PetNativeImageDropSupport.acceptedPasteboardTypes)
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        PetNativeImageDropSupport.canAccept(
            pasteboardTypeIdentifiers: sender.draggingPasteboard.types?.map(\.rawValue) ?? []
        ) ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        !draggingEntered(sender).isEmpty
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        // Consume the AppKit half of a browser drag without starting a second
        // capture. The extension will receive dragend and complete the active
        // capture using its original ID and trusted bytes.
        if shouldImportDrop?() == false { return true }
        let pasteboard = sender.draggingPasteboard
        let sourceURL = pasteboard.string(forType: .URL).flatMap(URL.init(string:))
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           let receiver = receivers.first {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("PromptStudioPetPromises", isDirectory: true)
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: .main) { [weak self] url, error in
                guard error == nil else { return }
                self?.onDropFile?(url, sourceURL)
            }
            return true
        }
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], let url = urls.first {
            onDropFile?(url, sourceURL)
            return true
        }
        if let data = PetNativeImageDropSupport.imageData(from: pasteboard) {
            onDropData?(data, pasteboard.availableType(from: [.png, .tiff])?.rawValue ?? "public.image")
            return true
        }
        if let sourceURL, ["http", "https"].contains(sourceURL.scheme?.lowercased() ?? "") {
            onDropRemoteURL?(sourceURL)
            return true
        }
        return false
    }
}
