import SwiftUI
import PromptStudioCore
import AppKit

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

enum ReferenceZoomDirection {
    case `in`
    case out
}

struct ReferenceZoomCursorModifier: ViewModifier {
    let direction: ReferenceZoomDirection
    @State private var isCursorPushed = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering, !isCursorPushed {
                    ReferenceZoomCursor.cursor(for: direction).push()
                    isCursorPushed = true
                } else if !hovering, isCursorPushed {
                    NSCursor.pop()
                    isCursorPushed = false
                }
            }
            .onDisappear {
                if isCursorPushed {
                    NSCursor.pop()
                    isCursorPushed = false
                }
            }
    }
}

struct ReferenceAssetLightbox: View {
    let reference: ReferenceAsset
    let onDismiss: () -> Void
    @StateObject private var loader = ReferenceOriginalImageLoader()

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .blur(radius: 18, opaque: true)
                .ignoresSafeArea()

            Color.black.opacity(0.72)
                .ignoresSafeArea()

            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(42)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .modifier(ReferenceZoomCursorModifier(direction: .out))
                    .onTapGesture {
                        onDismiss()
                    }
                    .accessibilityLabel("缩小参考图")
                    .accessibilityHint("点击返回")
            } else if loader.hasFinishedLoading {
                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(StudioFont.symbol(34))
                    Text("参考图无法打开")
                        .font(StudioFont.font(14, weight: .medium))
                }
                .foregroundStyle(StudioColor.secondaryText)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(StudioColor.text)
            }
        }
        .background {
            ReferenceLightboxEscapeMonitor(onEscape: onDismiss)
        }
        .task(id: reference.path) {
            await loader.load(reference.path)
        }
        .transition(.opacity)
    }
}

@MainActor
private final class ReferenceOriginalImageLoader: ObservableObject {
    @Published var image: NSImage?
    @Published var hasFinishedLoading = false

    func load(_ path: String) async {
        image = nil
        hasFinishedLoading = false
        let loaded = await Task.detached(priority: .userInitiated) {
            ReferenceLoadedImage(image: NSImage(contentsOfFile: path))
        }.value
        guard !Task.isCancelled else { return }
        image = loaded.image
        hasFinishedLoading = true
    }
}

private struct ReferenceLoadedImage: @unchecked Sendable {
    let image: NSImage?
}

private enum ReferenceZoomCursor {
    static func cursor(for direction: ReferenceZoomDirection) -> NSCursor {
        switch direction {
        case .in: zoomIn
        case .out: zoomOut
        }
    }

    private static let zoomIn = makeCursor(symbol: .plus)
    private static let zoomOut = makeCursor(symbol: .minus)

    private enum Symbol {
        case plus
        case minus
    }

    private static func makeCursor(symbol: Symbol) -> NSCursor {
        let size = NSSize(width: 32, height: 32)
        let image = NSImage(size: size, flipped: false) { _ in
            let lensRect = NSRect(x: 3, y: 8, width: 20, height: 20)
            NSColor.black.withAlphaComponent(0.82).setFill()
            NSBezierPath(ovalIn: lensRect).fill()

            NSColor.white.withAlphaComponent(0.92).setStroke()
            let lens = NSBezierPath(ovalIn: lensRect.insetBy(dx: 1, dy: 1))
            lens.lineWidth = 1.5
            lens.stroke()

            let handle = NSBezierPath()
            handle.move(to: NSPoint(x: 21, y: 10))
            handle.line(to: NSPoint(x: 29, y: 2))
            handle.lineWidth = 3
            handle.lineCapStyle = .round
            handle.stroke()

            let mark = NSBezierPath()
            mark.move(to: NSPoint(x: 8, y: 18))
            mark.line(to: NSPoint(x: 18, y: 18))
            if symbol == .plus {
                mark.move(to: NSPoint(x: 13, y: 13))
                mark.line(to: NSPoint(x: 13, y: 23))
            }
            mark.lineWidth = 2
            mark.lineCapStyle = .round
            mark.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 13, y: 18))
    }
}

private struct ReferenceLightboxEscapeMonitor: NSViewRepresentable {
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEscape: onEscape)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
    }

    final class Coordinator: @unchecked Sendable {
        var onEscape: () -> Void
        private var monitor: Any?

        init(onEscape: @escaping () -> Void) {
            self.onEscape = onEscape
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event }
                self?.onEscape()
                return nil
            }
        }
    }
}
