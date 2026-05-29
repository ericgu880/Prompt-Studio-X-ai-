import AppKit
import SwiftUI

@MainActor
struct MarkdownDocumentEditor: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> MarkdownEditorContainerView {
        let containerView = MarkdownEditorContainerView()
        let textView = containerView.textView
        textView.delegate = context.coordinator
        textView.string = text
        textView.isEditable = isEditable
        MarkdownSyntaxHighlighter.apply(to: textView)
        return containerView
    }

    func updateNSView(_ containerView: MarkdownEditorContainerView, context: Context) {
        context.coordinator.parent = self
        let textView = containerView.textView
        textView.isEditable = isEditable
        textView.insertionPointColor = MarkdownEditorPalette.text

        if textView.string != text {
            context.coordinator.isApplyingExternalChange = true
            textView.string = text
            MarkdownSyntaxHighlighter.apply(to: textView)
            context.coordinator.isApplyingExternalChange = false
        }

        containerView.gutterView.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownDocumentEditor
        var isApplyingExternalChange = false

        init(_ parent: MarkdownDocumentEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if !isApplyingExternalChange {
                parent.text = textView.string
            }
            let selectedRanges = textView.selectedRanges
            MarkdownSyntaxHighlighter.apply(to: textView)
            textView.selectedRanges = selectedRanges
            (textView.enclosingScrollView?.superview as? MarkdownEditorContainerView)?.gutterView.needsDisplay = true
        }
    }
}

@MainActor
final class MarkdownEditorContainerView: NSView {
    let textView: NSTextView
    let scrollView: NSScrollView
    let gutterView: MarkdownLineNumberGutterView

    private let gutterWidth: CGFloat = 44

    override init(frame frameRect: NSRect) {
        let textView = NSTextView(frame: .zero)
        self.textView = textView
        self.scrollView = NSScrollView(frame: .zero)
        self.gutterView = MarkdownLineNumberGutterView(textView: textView)
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = MarkdownEditorPalette.background.cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = MarkdownEditorPalette.border.cgColor

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textColor = MarkdownEditorPalette.text
        textView.font = MarkdownEditorPalette.bodyFont
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.usesFindBar = true
        textView.isSelectable = true

        scrollView.documentView = textView
        addSubview(gutterView)
        addSubview(scrollView)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        gutterView.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        scrollView.frame = NSRect(
            x: gutterWidth,
            y: 0,
            width: max(0, bounds.width - gutterWidth),
            height: bounds.height
        )
        textView.frame.size.width = scrollView.contentSize.width
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        gutterView.needsDisplay = true
    }

    @objc private func scrollBoundsDidChange() {
        gutterView.needsDisplay = true
    }
}

@MainActor
final class MarkdownLineNumberGutterView: NSView {
    weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = MarkdownEditorPalette.background.cgColor
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        MarkdownEditorPalette.background.setFill()
        bounds.fill()

        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let lineHeight = MarkdownEditorPalette.bodyFont.ascender - MarkdownEditorPalette.bodyFont.descender + MarkdownEditorPalette.bodyFont.leading
        let text = textView.string as NSString
        var drawnLines = Set<Int>()

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, glyphRange, _ in
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let lineNumber = text.markdownLineNumber(at: charRange.location)
            guard drawnLines.insert(lineNumber).inserted else { return }

            let y = usedRect.minY + textView.textContainerInset.height - visibleRect.minY
            let rect = NSRect(x: 0, y: y, width: self.bounds.width - 8, height: lineHeight)
            let label = "\(lineNumber)" as NSString
            label.draw(in: rect, withAttributes: MarkdownEditorPalette.lineNumberAttributes)
        }
    }
}

@MainActor
private enum MarkdownSyntaxHighlighter {
    static func apply(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let string = storage.string as NSString
        let fullRange = NSRange(location: 0, length: string.length)
        guard fullRange.length > 0 else { return }

        storage.beginEditing()
        storage.setAttributes(MarkdownEditorPalette.baseAttributes, range: fullRange)
        apply(pattern: #"(?m)^\s{0,6}#{1,6}\s.*$"#, to: storage, attributes: MarkdownEditorPalette.headingAttributes)
        apply(pattern: #"(?m)^\s*[-*_]{3,}\s*$"#, to: storage, attributes: MarkdownEditorPalette.mutedAttributes)
        apply(pattern: #"(?m)^\s*(?:\d+\.|[-*])"#, to: storage, attributes: MarkdownEditorPalette.listMarkerAttributes)
        apply(pattern: #"`[^`]+`"#, to: storage, attributes: MarkdownEditorPalette.codeAttributes)
        apply(pattern: #"[A-Za-z0-9_\-./\p{Han}]+\.md"#, to: storage, attributes: MarkdownEditorPalette.codeAttributes)
        storage.endEditing()
    }

    private static func apply(pattern: String, to storage: NSTextStorage, attributes: [NSAttributedString.Key: Any]) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(location: 0, length: (storage.string as NSString).length)
        regex.enumerateMatches(in: storage.string, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttributes(attributes, range: match.range)
        }
    }
}

@MainActor
private enum MarkdownEditorPalette {
    static let background = NSColor(hex: 0x141414)
    static let border = NSColor(hex: 0x363A3F)
    static let text = NSColor(hex: 0xFFFFFF)
    static let secondaryText = NSColor(hex: 0xDADBDF)
    static let mutedText = NSColor(hex: 0x7D8187)
    static let heading = NSColor(hex: 0xFF6B70)
    static let code = NSColor(hex: 0x7EE787)

    static let bodyFont = NSFont(name: "PingFangSC-Regular", size: 13) ?? .systemFont(ofSize: 13)
    static let headingFont = NSFont(name: "PingFangSC-Semibold", size: 13) ?? .systemFont(ofSize: 13, weight: .semibold)
    static let lineNumberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.paragraphSpacing = 2
        return style
    }()

    static let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: bodyFont,
        .foregroundColor: text,
        .paragraphStyle: paragraphStyle
    ]
    static let headingAttributes: [NSAttributedString.Key: Any] = [
        .font: headingFont,
        .foregroundColor: heading,
        .paragraphStyle: paragraphStyle
    ]
    static let mutedAttributes: [NSAttributedString.Key: Any] = [
        .font: bodyFont,
        .foregroundColor: mutedText,
        .paragraphStyle: paragraphStyle
    ]
    static let listMarkerAttributes: [NSAttributedString.Key: Any] = [
        .font: headingFont,
        .foregroundColor: heading,
        .paragraphStyle: paragraphStyle
    ]
    static let codeAttributes: [NSAttributedString.Key: Any] = [
        .font: headingFont,
        .foregroundColor: code,
        .paragraphStyle: paragraphStyle
    ]
    static let lineNumberAttributes: [NSAttributedString.Key: Any] = [
        .font: lineNumberFont,
        .foregroundColor: mutedText,
        .paragraphStyle: {
            let style = NSMutableParagraphStyle()
            style.alignment = .right
            return style
        }()
    ]
}

private extension NSString {
    func markdownLineNumber(at characterIndex: Int) -> Int {
        guard length > 0 else { return 1 }
        let upperBound = min(max(characterIndex, 0), length)
        var line = 1
        for index in 0..<upperBound where character(at: index) == 10 {
            line += 1
        }
        return line
    }
}

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xff) / 255.0,
            green: CGFloat((hex >> 8) & 0xff) / 255.0,
            blue: CGFloat(hex & 0xff) / 255.0,
            alpha: alpha
        )
    }
}
