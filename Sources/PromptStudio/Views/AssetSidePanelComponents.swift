import AppKit
import SwiftUI
import PromptStudioCore

struct SidePanelSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(StudioFont.caption(12))
            .foregroundStyle(StudioColor.secondaryText)
            .tracking(1.2)
    }
}

struct SidePanelChipFlow: View {
    let texts: [String]
    var spacing: CGFloat = 8

    var body: some View {
        SidePanelFlowLayout(spacing: spacing) {
            ForEach(texts, id: \.self) { text in
                SidePanelChip(text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SidePanelChip: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(StudioFont.font(11))
            .foregroundStyle(StudioColor.secondaryText)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(StudioColor.control))
            .overlay(Capsule().stroke(StudioColor.hairline, lineWidth: 1))
    }
}

struct SidePanelReferenceSection: View {
    let references: [ReferenceAsset]
    var title: String = "参考资产"
    var limit: Int = 8

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(62), spacing: 8), count: 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SidePanelSectionTitle(title: title)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(references.prefix(limit)) { reference in
                    ReferenceAssetPreview(reference: reference)
                        .frame(width: 62, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(StudioColor.hairline, lineWidth: 1))
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SidePanelActionRow: View {
    let actions: [SidePanelAction]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(actions) { action in
                SidePanelActionButton(action: action)
            }
        }
    }
}

struct SidePanelAction: Identifiable {
    let id = UUID()
    let icon: LucideIcon.Kind
    let help: String
    let action: () -> Void
}

struct SidePanelActionButton: View {
    let action: SidePanelAction

    var body: some View {
        Button(action: action.action) {
            LucideIcon(kind: action.icon)
                .frame(width: 14, height: 14)
        }
        .buttonStyle(IconCircleButtonStyle())
        .help(action.help)
        .accessibilityLabel(action.help)
    }
}

struct SidePanelPromptTextBox: View {
    let text: String
    let maxHeight: CGFloat
    var resetID: AnyHashable?
    var isPlaceholder = false
    var isInteractive = false
    var isHovered = false
    var copyFeedback = false
    var idleHint: String = "点击提示词复制"
    var doneHint: String = "已复制提示词"
    var onCopyAll: (() -> Void)?
    var onCopySelection: ((String) -> Void)?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = measuredHeight(width: width)
            let availableHeight = max(72, maxHeight)
            let usesScroll = height > availableHeight - 32
            let boxHeight = usesScroll ? availableHeight : height

            Group {
                if usesScroll {
                    SidePanelPromptScrollableTextView(
                        text: text,
                        isPlaceholder: isPlaceholder,
                        resetID: resetID,
                        onCopyAll: onCopyAll,
                        onCopySelection: onCopySelection
                    )
                    .frame(height: availableHeight)
                } else {
                    SidePanelPromptTextView(
                        text: text,
                        isPlaceholder: isPlaceholder,
                        onCopyAll: onCopyAll,
                        onCopySelection: onCopySelection
                    )
                    .frame(height: height, alignment: .top)
                }
            }
            .frame(height: boxHeight, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .top)
            .background(Color(hex: 0x2D2D2D))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(hex: 0x3E3E3E), lineWidth: 1)
            )
            .overlay {
                if isInteractive {
                    SidePanelPointingHandCursorArea()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isHovered && isInteractive {
                    HStack(spacing: 5) {
                        LucideIcon(kind: .copy)
                            .frame(width: 12, height: 12)
                        Text(copyFeedback ? doneHint : idleHint)
                    }
                    .font(StudioFont.font(11))
                    .foregroundStyle(StudioColor.secondaryText)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Capsule().fill(StudioColor.control.opacity(0.94)))
                    .padding(8)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity)
    }

    private func measuredHeight(width: CGFloat) -> CGFloat {
        let measurementWidth = max(1, width - 36)
        return PromptTextMetrics.height(
            for: text,
            width: measurementWidth,
            font: NSFont.systemFont(ofSize: 13, weight: .regular),
            lineSpacing: 4,
            horizontalPadding: 14,
            verticalPadding: 14
        ) + 24
    }
}

struct SidePanelPromptTextView: NSViewRepresentable {
    let text: String
    var isPlaceholder: Bool = false
    var onCopyAll: (() -> Void)?
    var onCopySelection: ((String) -> Void)?

    func makeNSView(context: Context) -> SidePanelPromptTextContainer {
        let view = SidePanelPromptTextContainer()
        updateContainer(view)
        return view
    }

    func updateNSView(_ nsView: SidePanelPromptTextContainer, context: Context) {
        updateContainer(nsView)
    }

    private func updateContainer(_ view: SidePanelPromptTextContainer) {
        view.onCopyAll = onCopyAll
        view.onCopySelection = onCopySelection
        view.update(text: text, isPlaceholder: isPlaceholder)
    }
}

struct SidePanelPromptScrollableTextView: NSViewRepresentable {
    let text: String
    var isPlaceholder = false
    var resetID: AnyHashable?
    var onCopyAll: (() -> Void)?
    var onCopySelection: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(resetID: resetID, text: text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = HoverRevealScrollView()
        configure(scrollView)

        let documentView = SidePanelPromptTextContainer()
        documentView.update(text: text, isPlaceholder: isPlaceholder)
        documentView.onCopyAll = onCopyAll
        documentView.onCopySelection = onCopySelection
        scrollView.documentView = documentView
        resize(documentView, in: scrollView)
        scrollToTop(scrollView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        configure(scrollView)

        let documentView: SidePanelPromptTextContainer
        if let existing = scrollView.documentView as? SidePanelPromptTextContainer {
            documentView = existing
        } else {
            let replacement = SidePanelPromptTextContainer()
            scrollView.documentView = replacement
            documentView = replacement
        }

        let shouldResetScroll = context.coordinator.resetID != resetID || context.coordinator.text != text
        context.coordinator.resetID = resetID
        context.coordinator.text = text

        documentView.onCopyAll = onCopyAll
        documentView.onCopySelection = onCopySelection
        documentView.update(text: text, isPlaceholder: isPlaceholder)
        resize(documentView, in: scrollView)

        DispatchQueue.main.async {
            resize(documentView, in: scrollView)
            if shouldResetScroll {
                scrollToTop(scrollView)
            }
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
        (scrollView as? HoverRevealScrollView)?.setRevealScrollerOnHover(true)
    }

    private func resize(_ documentView: SidePanelPromptTextContainer, in scrollView: NSScrollView) {
        let width = max(1, scrollView.contentView.bounds.width)
        let height = max(scrollView.contentView.bounds.height, documentView.fittingHeight(for: width))
        documentView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func scrollToTop(_ scrollView: NSScrollView) {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    final class Coordinator {
        var resetID: AnyHashable?
        var text: String

        init(resetID: AnyHashable?, text: String) {
            self.resetID = resetID
            self.text = text
        }
    }
}

final class SidePanelPromptTextContainer: NSView {
    var onCopyAll: (() -> Void)? {
        didSet { textView.onCopyAll = onCopyAll }
    }
    var onCopySelection: ((String) -> Void)? {
        didSet { textView.onCopySelection = onCopySelection }
    }

    private let textView = SidePanelCopyingPromptTextView()
    private let font = NSFont.systemFont(ofSize: 13, weight: .regular)
    private let textInset = NSSize(width: 14, height: 14)
    private var currentText = ""
    private var currentPlaceholderState = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override var intrinsicContentSize: NSSize {
        let width = bounds.width > 1 ? bounds.width : 260
        return NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight(for: width))
    }

    func fittingHeight(for width: CGFloat) -> CGFloat {
        measuredHeight(for: width)
    }

    override func layout() {
        super.layout()
        textView.frame = bounds
        textView.textContainer?.containerSize = NSSize(
            width: max(1, bounds.width - textInset.width * 2),
            height: CGFloat.greatestFiniteMagnitude
        )
        invalidateIntrinsicContentSize()
    }

    func update(text: String, isPlaceholder: Bool) {
        textView.onCopyAll = onCopyAll
        textView.onCopySelection = onCopySelection
        textView.usesCopyInteraction = onCopyAll != nil || onCopySelection != nil

        guard text != currentText || isPlaceholder != currentPlaceholderState else {
            invalidateIntrinsicContentSize()
            return
        }

        currentText = text
        currentPlaceholderState = isPlaceholder
        let textColor = isPlaceholder ? NSColor(sidePanelHex: 0x7D8187) : NSColor(sidePanelHex: 0xFFFFFF)
        textView.textStorage?.setAttributedString(attributedString(for: text, color: textColor))
        textView.scroll(.zero)
        invalidateIntrinsicContentSize()
        window?.invalidateCursorRects(for: textView)
    }

    private func setup() {
        wantsLayer = false
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.textContainerInset = textInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width, .height]
        addSubview(textView)
    }

    private func measuredHeight(for width: CGFloat) -> CGFloat {
        let textWidth = max(1, width - textInset.width * 2)
        let storage = NSTextStorage(attributedString: textView.attributedString())
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        return max(44, ceil(usedRect.height) + textInset.height * 2)
    }

    private func attributedString(for text: String, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.alignment = .left
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }
}

private final class SidePanelCopyingPromptTextView: NSTextView {
    var onCopyAll: (() -> Void)?
    var onCopySelection: ((String) -> Void)?
    var usesCopyInteraction = false
    private var mouseDownLocation: NSPoint = .zero

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        guard usesCopyInteraction else {
            super.resetCursorRects()
            return
        }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        if usesCopyInteraction {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if usesCopyInteraction {
            NSCursor.pointingHand.set()
        } else {
            super.mouseMoved(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)

        guard usesCopyInteraction else { return }
        if let selectedText {
            onCopySelection?(selectedText)
        } else if event.clickCount == 1, didClickWithoutDragging() {
            onCopyAll?()
        }
    }

    override func autoscroll(with event: NSEvent) -> Bool {
        super.autoscroll(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if let scrollView = ancestorScrollView {
            scrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    private func didClickWithoutDragging() -> Bool {
        guard let window else { return true }
        let mouseUpLocation = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let deltaX = mouseUpLocation.x - mouseDownLocation.x
        let deltaY = mouseUpLocation.y - mouseDownLocation.y
        return hypot(deltaX, deltaY) < 3
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

    private var ancestorScrollView: NSScrollView? {
        var current = superview
        while let view = current {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }
            current = view.superview
        }
        return nil
    }
}

private struct SidePanelPointingHandCursorArea: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorView {
        CursorView()
    }

    func updateNSView(_ nsView: CursorView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    final class CursorView: NSView {
        override var isFlipped: Bool { true }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .pointingHand)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

private extension NSColor {
    convenience init(sidePanelHex hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xff) / 255.0,
            green: CGFloat((hex >> 8) & 0xff) / 255.0,
            blue: CGFloat(hex & 0xff) / 255.0,
            alpha: alpha
        )
    }
}

private struct SidePanelFlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    init(spacing: CGFloat, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        SidePanelWrappingLayout(spacing: spacing) {
            content
        }
    }
}

private struct SidePanelWrappingLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        guard maxWidth.isFinite else {
            let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            let width = sizes.reduce(CGFloat.zero) { $0 + $1.width } + CGFloat(max(0, sizes.count - 1)) * spacing
            let height = sizes.map(\.height).max() ?? 0
            return CGSize(width: width, height: height)
        }

        var currentX: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if currentX > 0, currentX + spacing + size.width > maxWidth {
                totalHeight += currentRowHeight + spacing
                currentX = 0
                currentRowHeight = 0
            }

            if currentX > 0 {
                currentX += spacing
            }
            currentX += min(size.width, maxWidth)
            currentRowHeight = max(currentRowHeight, size.height)
        }

        totalHeight += currentRowHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var currentX = bounds.minX
        var currentY = bounds.minY
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if currentX > bounds.minX, currentX + spacing + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += currentRowHeight + spacing
                currentRowHeight = 0
            }

            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(width: min(size.width, maxWidth), height: size.height)
            )
            currentX += min(size.width, maxWidth) + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
    }
}
