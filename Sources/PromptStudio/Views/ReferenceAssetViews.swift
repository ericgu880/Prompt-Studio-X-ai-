import SwiftUI
import PromptStudioCore

struct ReferenceAssetPreview: View {
    let path: String
    let type: String
    var contentMode: ContentMode = .fill

    init(reference: ReferenceAsset, contentMode: ContentMode = .fill) {
        self.path = reference.path
        self.type = reference.type
        self.contentMode = contentMode
    }

    init(path: String, type: String = "", contentMode: ContentMode = .fill) {
        self.path = path
        self.type = type
        self.contentMode = contentMode
    }

    var body: some View {
        if assetKind == .image {
            ThumbnailImage(path: path, contentMode: contentMode)
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

