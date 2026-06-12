import AppKit

@MainActor
enum PromptTextMetrics {
    private static let cache = NSCache<NSString, NSNumber>()

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
        let cacheKey = [
            text.count.description,
            text.hashValue.description,
            Int(textWidth.rounded()).description,
            font.fontName,
            font.pointSize.description,
            lineSpacing.description,
            verticalPadding.description,
            minHeight.description
        ].joined(separator: "|") as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return CGFloat(truncating: cached)
        }

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
        let height = max(minHeight, ceil(layoutManager.usedRect(for: textContainer).height) + verticalPadding * 2)
        cache.setObject(NSNumber(value: Double(height)), forKey: cacheKey)
        return height
    }
}
