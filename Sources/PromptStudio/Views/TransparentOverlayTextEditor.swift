import AppKit
import SwiftUI

struct TransparentOverlayTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var textColor: NSColor
    var insertionPointColor: NSColor
    var textContainerInset: NSSize
    var lineSpacing: CGFloat
    var onPaste: ((String) -> Bool)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView(frame: .zero)
        configure(scrollView)

        let textView = PasteInterceptingTextView(frame: .zero)
        textView.onPaste = { [weak coordinator = context.coordinator] text in
            coordinator?.parent.onPaste?(text) ?? false
        }
        textView.delegate = context.coordinator
        textView.string = text
        configure(textView)
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        configure(scrollView)
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if let textView = textView as? PasteInterceptingTextView {
            textView.onPaste = { [weak coordinator = context.coordinator] text in
                coordinator?.parent.onPaste?(text) ?? false
            }
        }
        configure(textView)
        if textView.string != text {
            textView.string = text
        }
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

    private func configure(_ textView: NSTextView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = textColor
        textView.font = font
        textView.insertionPointColor = insertionPointColor
        textView.textContainerInset = textContainerInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: textView.enclosingScrollView?.contentSize.width ?? 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]
        textView.defaultParagraphStyle = paragraph
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TransparentOverlayTextEditor

        init(_ parent: TransparentOverlayTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

private final class PasteInterceptingTextView: NSTextView {
    var onPaste: ((String) -> Bool)?

    override func paste(_ sender: Any?) {
        let hasFiles = NSPasteboard.general.readObjects(forClasses: [NSURL.self])?.isEmpty == false
        guard !hasFiles,
              let text = NSPasteboard.general.string(forType: .string),
              onPaste?(text) == true else {
            super.paste(sender)
            return
        }
    }
}
