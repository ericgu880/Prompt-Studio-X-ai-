import SwiftUI
import PromptStudioCore

enum ReferenceAssetPreviewMode: Equatable {
    case original
    case thumbnail(libraryURL: URL)
}

struct ReferenceAssetPreview: View {
    let referenceID: String
    let path: String
    let type: String
    var contentMode: ContentMode = .fill
    var mode: ReferenceAssetPreviewMode = .original

    init(
        reference: ReferenceAsset,
        contentMode: ContentMode = .fill,
        mode: ReferenceAssetPreviewMode = .original
    ) {
        self.referenceID = reference.id
        self.path = reference.path
        self.type = reference.type
        self.contentMode = contentMode
        self.mode = mode
    }

    init(path: String, type: String = "", contentMode: ContentMode = .fill) {
        self.referenceID = path
        self.path = path
        self.type = type
        self.contentMode = contentMode
        self.mode = .original
    }

    @ViewBuilder
    var body: some View {
        if assetKind == .image {
            switch mode {
            case .original:
                ThumbnailImage(path: path, contentMode: contentMode)
            case .thumbnail(let libraryURL):
                ReferenceThumbnailImage(
                    reference: ReferenceAsset(id: referenceID, type: type, path: path, label: ""),
                    libraryURL: libraryURL,
                    contentMode: contentMode
                )
            }
        } else {
            ZStack {
                StudioColor.panelRaised
                VStack(spacing: 8) {
                    Image(systemName: symbolName)
                        .font(StudioFont.symbol(24))
                        .foregroundStyle(StudioColor.text)
                    Text(displayType)
                        .font(StudioFont.caption(10))
                        .foregroundStyle(StudioColor.secondaryText)
                        .lineLimit(1)
                }
            }
        }
    }

    private var assetKind: AssetKind {
        AssetFormatCatalog.support(forFileExtension: fileExtension).assetKind
    }

    private var fileExtension: String {
        let ext = URL(fileURLWithPath: path).pathExtension
        return ext.isEmpty ? type : ext
    }

    private var displayType: String {
        fileExtension.isEmpty ? assetKind.displayName.uppercased() : fileExtension.uppercased()
    }

    private var symbolName: String {
        switch assetKind {
        case .video:
            "film"
        case .audio:
            "waveform"
        case .image:
            "photo"
        default:
            "doc"
        }
    }
}

private struct ReferenceThumbnailImage: View {
    let reference: ReferenceAsset
    let libraryURL: URL
    let contentMode: ContentMode
    @State private var thumbnailURL: URL?
    @State private var thumbnailVersion: TimeInterval = 0

    var body: some View {
        Group {
            if let thumbnailURL {
                ThumbnailImage(
                    path: thumbnailURL.path,
                    contentVersion: thumbnailVersion,
                    contentMode: contentMode
                )
            } else {
                ZStack {
                    StudioColor.panelRaised
                    Image(systemName: "photo")
                        .font(StudioFont.symbol(20))
                        .foregroundStyle(StudioColor.tertiaryText)
                }
                .onAppear {
                    DebugPerformanceProbe.record("reference.thumbnail.placeholder")
                }
            }
        }
        .task(id: requestID) {
            thumbnailURL = nil
            let service = ReferenceThumbnailService.shared(libraryURL: libraryURL)
            let resolved = await service.request(reference, priority: .userInitiated)
            guard !Task.isCancelled else { return }
            thumbnailURL = resolved
            thumbnailVersion = resolved.flatMap(Self.modificationVersion) ?? 0
        }
    }

    private var requestID: String {
        "\(libraryURL.standardizedFileURL.path)|\(reference.id)|\(reference.path)"
    }

    private static func modificationVersion(_ thumbnailURL: URL) -> TimeInterval? {
        let values = try? FileManager.default.attributesOfItem(atPath: thumbnailURL.path)
        return (values?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
    }
}
