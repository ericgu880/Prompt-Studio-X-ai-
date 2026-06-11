import AppKit
import SwiftUI

struct TransparentOverlayScrollView<Content: View>: NSViewRepresentable {
    let content: Content
    let resetID: AnyHashable?

    init(resetID: AnyHashable? = nil, @ViewBuilder content: () -> Content) {
        self.resetID = resetID
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(resetID: resetID)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        configure(scrollView)

        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let documentView = TransparentScrollDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = true
        documentView.wantsLayer = true
        documentView.layer?.backgroundColor = NSColor.clear.cgColor
        documentView.hostingView = hostingView
        documentView.pendingTopScrollPasses = 3
        documentView.addSubview(hostingView)
        scrollView.documentView = documentView

        resizeDocumentView(in: scrollView)
        scheduleResizeAndTopScroll(for: scrollView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        configure(scrollView)
        if context.coordinator.resetID != resetID {
            context.coordinator.resetID = resetID
            (scrollView.documentView as? TransparentScrollDocumentView)?.pendingTopScrollPasses = 3
        }
        (scrollView.documentView?.subviews.first as? NSHostingView<Content>)?.rootView = content
        scrollView.documentView?.layer?.backgroundColor = NSColor.clear.cgColor
        (scrollView.documentView?.subviews.first as? NSView)?.layer?.backgroundColor = NSColor.clear.cgColor
        resizeDocumentView(in: scrollView)
        scheduleResizeAndTopScroll(for: scrollView)
    }

    private func configure(_ scrollView: NSScrollView) {
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.wantsLayer = true
        scrollView.layer?.backgroundColor = NSColor.clear.cgColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .light
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .allowed
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.scrollerInsets = NSEdgeInsetsZero
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layer?.backgroundColor = NSColor.clear.cgColor
        if !(scrollView.verticalScroller is TransparentOverlayScroller) {
            scrollView.verticalScroller = TransparentOverlayScroller()
        }
    }

    private func resizeDocumentView(in scrollView: NSScrollView) {
        guard let documentView = scrollView.documentView as? TransparentScrollDocumentView,
              let hostingView = documentView.hostingView else { return }

        let width = max(1, scrollView.contentView.bounds.width)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: max(1, hostingView.frame.height))
        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let contentHeight = max(1, ceil(fittingSize.height))
        let documentHeight = max(scrollView.contentView.bounds.height, contentHeight)
        documentView.hostedContentHeight = contentHeight
        documentView.frame = NSRect(x: 0, y: 0, width: width, height: documentHeight)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func scrollToTop(in scrollView: NSScrollView) {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func scheduleResizeAndTopScroll(for scrollView: NSScrollView) {
        DispatchQueue.main.async {
            resizeDocumentView(in: scrollView)
            guard let documentView = scrollView.documentView as? TransparentScrollDocumentView,
                  documentView.pendingTopScrollPasses > 0,
                  scrollView.contentView.bounds.width > 1 else { return }
            scrollToTop(in: scrollView)
            documentView.pendingTopScrollPasses -= 1
            if documentView.pendingTopScrollPasses > 0 {
                scheduleResizeAndTopScroll(for: scrollView)
            }
        }
    }

    final class Coordinator {
        var resetID: AnyHashable?

        init(resetID: AnyHashable?) {
            self.resetID = resetID
        }
    }
}

private final class TransparentScrollDocumentView: NSView {
    weak var hostingView: NSView?
    var hostedContentHeight: CGFloat = 1
    var pendingTopScrollPasses = 0

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        hostingView?.frame = NSRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: min(bounds.height, max(1, hostedContentHeight))
        )
    }
}
