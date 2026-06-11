import AppKit

enum PromptTextMetrics {
    static func height(
        for text: String,
        width: CGFloat,
        font: NSFont,
        lineSpacing: CGFloat,
        horizontalPadding: CGFloat,
        verticalPadding: CGFloat,
        minHeight: CGFloat = 44
    ) -> CGFloat {
        let textWidth = max(1, width - horizontalPadding * 2)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let storage = NSTextStorage(
            string: text,
            attributes: [
                .font: font,
                .paragraphStyle: paragraph
            ]
        )
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)
        return max(minHeight, ceil(layoutManager.usedRect(for: textContainer).height) + verticalPadding * 2)
    }
}
