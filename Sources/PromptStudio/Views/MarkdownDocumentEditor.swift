import AppKit
import SwiftUI
import PromptStudioCore

@MainActor
struct MarkdownDocumentEditor: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let scrollResetID: String?
    let contentFontSize: CGFloat
    let syntaxMode: TextSyntaxMode
    let revealsScrollerOnHover: Bool
    let onCopyAll: (() -> Void)?
    let onCopySelection: ((String) -> Void)?

    init(
        text: Binding<String>,
        isEditable: Bool,
        scrollResetID: String? = nil,
        contentFontSize: CGFloat = 14,
        syntaxMode: TextSyntaxMode = .markdown,
        revealsScrollerOnHover: Bool = false,
        onCopyAll: (() -> Void)? = nil,
        onCopySelection: ((String) -> Void)? = nil
    ) {
        self._text = text
        self.isEditable = isEditable
        self.scrollResetID = scrollResetID
        self.contentFontSize = contentFontSize
        self.syntaxMode = syntaxMode
        self.revealsScrollerOnHover = revealsScrollerOnHover
        self.onCopyAll = onCopyAll
        self.onCopySelection = onCopySelection
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> MarkdownEditorContainerView {
        let containerView = MarkdownEditorContainerView(
            contentFontSize: contentFontSize,
            revealsScrollerOnHover: revealsScrollerOnHover
        )
        let textView = containerView.textView
        textView.delegate = context.coordinator
        textView.string = text
        textView.isEditable = isEditable
        containerView.setCopyHandlers(onCopyAll: onCopyAll, onCopySelection: onCopySelection, isEditable: isEditable)
        TextSyntaxHighlighter.apply(to: textView, mode: syntaxMode, contentFontSize: contentFontSize)
        if let scrollResetID {
            context.coordinator.lastScrollResetID = scrollResetID
            containerView.scrollToTop()
        }
        context.coordinator.lastSyntaxMode = syntaxMode
        return containerView
    }

    func updateNSView(_ containerView: MarkdownEditorContainerView, context: Context) {
        context.coordinator.parent = self
        let textView = containerView.textView
        textView.isEditable = isEditable
        textView.insertionPointColor = MarkdownEditorPalette.strongText
        containerView.setRevealScrollerOnHover(revealsScrollerOnHover)
        containerView.setCopyHandlers(onCopyAll: onCopyAll, onCopySelection: onCopySelection, isEditable: isEditable)
        let fontSizeChanged = containerView.updateContentFontSize(contentFontSize)
        let syntaxModeChanged = context.coordinator.lastSyntaxMode != syntaxMode
        context.coordinator.lastSyntaxMode = syntaxMode
        var shouldResetScroll = false

        if let scrollResetID, context.coordinator.lastScrollResetID != scrollResetID {
            context.coordinator.lastScrollResetID = scrollResetID
            shouldResetScroll = true
        }

        if textView.string != text {
            context.coordinator.isApplyingExternalChange = true
            textView.string = text
            TextSyntaxHighlighter.apply(to: textView, mode: syntaxMode, contentFontSize: contentFontSize)
            context.coordinator.isApplyingExternalChange = false
            shouldResetScroll = scrollResetID != nil
        } else if fontSizeChanged || syntaxModeChanged {
            TextSyntaxHighlighter.apply(to: textView, mode: syntaxMode, contentFontSize: contentFontSize)
        }

        containerView.gutterView.needsDisplay = true
        if shouldResetScroll {
            containerView.scrollToTop()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownDocumentEditor
        var isApplyingExternalChange = false
        var lastScrollResetID: String?
        var lastSyntaxMode: TextSyntaxMode?

        init(_ parent: MarkdownDocumentEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if !isApplyingExternalChange {
                parent.text = textView.string
            }
            let selectedRanges = textView.selectedRanges
            TextSyntaxHighlighter.apply(to: textView, mode: parent.syntaxMode, contentFontSize: parent.contentFontSize)
            textView.selectedRanges = selectedRanges
            (textView.enclosingScrollView?.superview as? MarkdownEditorContainerView)?.gutterView.needsDisplay = true
        }
    }
}

@MainActor
final class MarkdownEditorContainerView: NSView {
    let textView: CopyingMarkdownTextView
    let scrollView: NSScrollView
    let gutterView: MarkdownLineNumberGutterView

    private let gutterWidth: CGFloat = 44
    private(set) var contentFontSize: CGFloat

    init(
        contentFontSize: CGFloat = 14,
        revealsScrollerOnHover: Bool = false,
        frame frameRect: NSRect = .zero
    ) {
        self.contentFontSize = contentFontSize
        let textView = CopyingMarkdownTextView(frame: .zero)
        self.textView = textView
        self.scrollView = HoverRevealScrollView(frame: .zero)
        self.gutterView = MarkdownLineNumberGutterView(textView: textView, contentFontSize: contentFontSize)
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = MarkdownEditorPalette.background.cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = MarkdownEditorPalette.border.cgColor

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScroller = TransparentOverlayScroller()
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .light
        scrollView.verticalScrollElasticity = .allowed
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.scrollerInsets = NSEdgeInsetsZero
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layer?.backgroundColor = NSColor.clear.cgColor
        scrollView.contentView.postsBoundsChangedNotifications = true
        setRevealScrollerOnHover(revealsScrollerOnHover)

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 14, height: 24)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textColor = MarkdownEditorPalette.text
        textView.font = MarkdownEditorPalette.bodyFont(size: contentFontSize)
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

    func updateContentFontSize(_ size: CGFloat) -> Bool {
        guard contentFontSize != size else { return false }
        contentFontSize = size
        gutterView.contentFontSize = size
        textView.font = MarkdownEditorPalette.bodyFont(size: size)
        textView.needsDisplay = true
        gutterView.needsDisplay = true
        return true
    }

    func setCopyHandlers(onCopyAll: (() -> Void)?, onCopySelection: ((String) -> Void)?, isEditable: Bool) {
        textView.onCopyAll = isEditable ? nil : onCopyAll
        textView.onCopySelection = isEditable ? nil : onCopySelection
        textView.usesPointingHandCursor = !isEditable && onCopyAll != nil
        textView.window?.invalidateCursorRects(for: textView)
    }

    func setRevealScrollerOnHover(_ enabled: Bool) {
        (scrollView as? HoverRevealScrollView)?.setRevealScrollerOnHover(enabled)
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

    func scrollToTop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            gutterView.needsDisplay = true
        }
    }
}

@MainActor
final class CopyingMarkdownTextView: NSTextView {
    var onCopyAll: (() -> Void)?
    var onCopySelection: ((String) -> Void)?
    var usesPointingHandCursor = false

    override func resetCursorRects() {
        if usesPointingHandCursor {
            addCursorRect(bounds, cursor: .pointingHand)
        } else {
            super.resetCursorRects()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if usesPointingHandCursor {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if usesPointingHandCursor {
            NSCursor.pointingHand.set()
        } else {
            super.mouseMoved(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard usesPointingHandCursor else { return }
        if let selectedText {
            onCopySelection?(selectedText)
        } else if event.clickCount == 1 {
            onCopyAll?()
        }
    }

    private var selectedText: String? {
        let range = selectedRange()
        guard range.length > 0,
              let swiftRange = Range(range, in: string) else {
            return nil
        }
        let text = String(string[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

@MainActor
final class MarkdownLineNumberGutterView: NSView {
    weak var textView: NSTextView?
    var contentFontSize: CGFloat

    init(textView: NSTextView, contentFontSize: CGFloat) {
        self.textView = textView
        self.contentFontSize = contentFontSize
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
        let bodyFont = MarkdownEditorPalette.bodyFont(size: contentFontSize)
        let lineHeight = bodyFont.ascender - bodyFont.descender + bodyFont.leading
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
private enum TextSyntaxHighlighter {
    static func apply(to textView: NSTextView, mode: TextSyntaxMode, contentFontSize: CGFloat) {
        guard let storage = textView.textStorage else { return }
        let string = storage.string as NSString
        let fullRange = NSRange(location: 0, length: string.length)
        guard fullRange.length > 0 else { return }

        storage.beginEditing()
        storage.setAttributes(MarkdownEditorPalette.baseAttributes(size: contentFontSize), range: fullRange)
        for rule in TextSyntaxRules.rules(for: mode, text: storage.string) {
            apply(rule: rule, to: storage, attributes: attributes(for: rule.token, size: contentFontSize))
        }
        storage.endEditing()
    }

    private static func apply(
        rule: TextSyntaxRule,
        to storage: NSTextStorage,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else { return }
        let range = NSRange(location: 0, length: (storage.string as NSString).length)
        regex.enumerateMatches(in: storage.string, range: range) { match, _, _ in
            guard let match else { return }
            let targetRange = rule.captureGroup > 0 && rule.captureGroup < match.numberOfRanges
                ? match.range(at: rule.captureGroup)
                : match.range
            guard targetRange.location != NSNotFound, targetRange.length > 0 else { return }
            storage.addAttributes(attributes, range: targetRange)
        }
    }

    private static func attributes(for token: TextSyntaxToken, size: CGFloat) -> [NSAttributedString.Key: Any] {
        switch token {
        case .heading, .jsonKey, .yamlKey, .xmlTag, .timestamp, .infoLevel, .sourceKeyword:
            return MarkdownEditorPalette.headingAttributes(size: size)
        case .quoteMarker, .inlineCode, .string, .url, .path:
            return MarkdownEditorPalette.codeAttributes(size: size)
        case .listMarker, .number, .punctuation, .xmlAttribute, .warningLevel:
            return MarkdownEditorPalette.listMarkerAttributes(size: size)
        case .negativeConstraint, .literal, .errorLevel:
            return MarkdownEditorPalette.negativeConstraintAttributes(size: size)
        case .bold:
            return MarkdownEditorPalette.boldAttributes(size: size)
        case .comment, .muted:
            return MarkdownEditorPalette.mutedAttributes(size: size)
        }
    }
}

@MainActor
private enum MarkdownEditorPalette {
    static let background = NSColor(hex: 0x141414)
    static let border = NSColor(hex: 0x363A3F)
    static let strongText = NSColor(hex: 0xFFFFFF)
    static let text = NSColor(hex: 0xFFFFFF)
    static let mutedText = NSColor(hex: 0xBDBEC0)
    static let red = NSColor(hex: 0xFF5F57)
    static let orange = NSColor(hex: 0xFF9F0A)
    static let green = NSColor(hex: 0x37DD61)
    static let blue = NSColor(hex: 0x41CBE0)
    static let white = NSColor(hex: 0xEEEEEE)

    static let lineNumberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    static func bodyFont(size: CGFloat) -> NSFont {
        NSFont(name: "PingFangSC-Regular", size: size) ?? .systemFont(ofSize: size)
    }

    static func semanticFont(size: CGFloat) -> NSFont {
        bodyFont(size: size)
    }

    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.paragraphSpacing = 2
        return style
    }()

    static func baseAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        attributes(font: bodyFont(size: size), color: text)
    }

    static func headingAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        attributes(font: semanticFont(size: size), color: blue)
    }

    static func mutedAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        attributes(font: bodyFont(size: size), color: mutedText)
    }

    static func quoteMarkerAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        attributes(font: semanticFont(size: size), color: green)
    }

    static func listMarkerAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        attributes(font: semanticFont(size: size), color: orange)
    }

    static func codeAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        attributes(font: semanticFont(size: size), color: green)
    }

    static func negativeConstraintAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        attributes(font: semanticFont(size: size), color: red)
    }

    static func boldAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        attributes(font: semanticFont(size: size), color: white)
    }

    private static func attributes(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
    }

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
