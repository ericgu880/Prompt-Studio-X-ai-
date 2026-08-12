import Foundation
import SwiftUI
import PromptStudioCore

/// The app-level intent for changing a prompt's primary asset. Keeping the
/// three states explicit prevents an edit with no upload from accidentally
/// clearing an existing file.
enum PrimaryAssetUpdate: Equatable {
    case unchanged
    case replace(URL)
    case remove
}

extension PromptItem {
    var hasAvailablePrimaryAsset: Bool {
        primaryAssetState(using: { FileManager.default.fileExists(atPath: $0) }) == .available
    }
}

/// Shared cover for generated media prompts that have no file yet.
struct PromptVirtualCover: View, Equatable {
    let type: PromptType

    var body: some View {
        ZStack {
            StudioColor.panelRaised
            VStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(StudioColor.text)
                Text("尚未添加主素材")
                    .font(StudioFont.font(12, weight: .medium))
                    .foregroundStyle(StudioColor.secondaryText)
                Text(type.displayName)
                    .font(StudioFont.font(10))
                    .foregroundStyle(StudioColor.tertiaryText)
            }
            .multilineTextAlignment(.center)
            .padding(12)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(type.displayName)，尚未添加主素材")
    }

    private var iconName: String {
        switch type {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .text: "doc.text"
        }
    }
}
