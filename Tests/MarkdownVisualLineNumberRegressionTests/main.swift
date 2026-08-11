import AppKit

@MainActor
private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(1)
    }
}

MainActor.assumeIsolated {
    let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    let text = "This deliberately long Markdown paragraph must wrap across several visible rows.\nSecond line."
    let storage = NSTextStorage(
        attributedString: NSAttributedString(string: text, attributes: [.font: font])
    )
    let layoutManager = NSLayoutManager()
    let textContainer = NSTextContainer(size: NSSize(width: 92, height: CGFloat.greatestFiniteMagnitude))
    textContainer.lineFragmentPadding = 0
    layoutManager.addTextContainer(textContainer)
    storage.addLayoutManager(layoutManager)
    layoutManager.ensureLayout(for: textContainer)

    let fragments = MarkdownVisualLineNumberer.fragments(
        layoutManager: layoutManager,
        textContainer: textContainer,
        intersecting: NSRect(x: 0, y: 0, width: 92, height: 10_000)
    )
    let numbers = fragments.map(\.number)

    require(fragments.count > 2, "The fixture must wrap into more than two visual lines.")
    require(
        numbers == Array(1...fragments.count),
        "Every wrapped visual line must have a continuous line number. actual=\(numbers)"
    )

    print("MarkdownVisualLineNumberRegressionTests passed")
}
