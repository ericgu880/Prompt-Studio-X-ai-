import AVKit
import SwiftUI
import PromptStudioCore

struct AudioPreviewPlayer: View {
    let item: PromptItem

    var body: some View {
        Group {
            if FileManager.default.fileExists(atPath: item.assetPath) {
                VStack(spacing: 22) {
                    Spacer(minLength: 0)

                    VStack(spacing: 14) {
                        AssetMediaView(item: item, contentMode: .fill)
                            .frame(width: 104, height: 104)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))

                        Text(item.title)
                            .font(StudioFont.font(15, weight: .semibold))
                            .foregroundStyle(StudioColor.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)

                        HStack(spacing: 8) {
                            audioChip(item.format.isEmpty ? "AUDIO" : item.format.uppercased())
                            audioChip(fileSizeText(item.fileSize))
                        }
                    }

                    NativeAudioPlayer(path: item.assetPath)
                        .frame(height: 74)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
                        .frame(maxWidth: 560)

                    Spacer(minLength: 0)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(StudioColor.panel)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "waveform.slash")
                        .font(StudioFont.symbol(34))
                    Text("音频文件不存在")
                        .font(StudioFont.font(14))
                }
                .foregroundStyle(StudioColor.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .studioPanel(radius: 8)
            }
        }
    }

    private func audioChip(_ text: String) -> some View {
        Text(text)
            .font(StudioFont.caption(11))
            .foregroundStyle(StudioColor.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(StudioColor.control))
            .overlay(Capsule().stroke(StudioColor.hairline, lineWidth: 1))
    }

    private func fileSizeText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct NativeAudioPlayer: NSViewRepresentable {
    let path: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        context.coordinator.configure(view, path: path)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        context.coordinator.configure(nsView, path: path)
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.stop()
        nsView.player = nil
    }

    final class Coordinator {
        private var currentPath: String?
        private var player: AVPlayer?

        @MainActor
        func configure(_ view: AVPlayerView, path: String) {
            guard currentPath != path else { return }
            stop()
            currentPath = path
            let player = AVPlayer(url: URL(fileURLWithPath: path))
            self.player = player
            view.player = player
            player.play()
        }

        @MainActor
        func stop() {
            player?.pause()
            player = nil
            currentPath = nil
        }
    }
}
