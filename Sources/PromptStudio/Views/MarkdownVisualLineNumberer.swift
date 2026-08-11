import AppKit

struct MarkdownVisualLineFragment {
    let number: Int
    let usedRect: NSRect
}

enum MarkdownVisualLineNumberer {
    static func fragments(
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        intersecting visibleRect: NSRect
    ) -> [MarkdownVisualLineFragment] {
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var fragments: [MarkdownVisualLineFragment] = []
        var visualLineNumber = 0

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, usedRect, _, _, _ in
            visualLineNumber += 1
            guard lineRect.intersects(visibleRect) else { return }
            fragments.append(
                MarkdownVisualLineFragment(
                    number: visualLineNumber,
                    usedRect: usedRect
                )
            )
        }
        return fragments
    }
}
