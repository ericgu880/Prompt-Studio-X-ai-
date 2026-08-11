import AppKit

@MainActor
private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(1)
    }
}

MainActor.assumeIsolated {
    let viewportSize = NSSize(width: 120, height: 100)
    let scrollView = HoverRevealScrollView(frame: NSRect(origin: .zero, size: viewportSize))
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.scrollerStyle = .overlay
    scrollView.verticalScroller = TransparentOverlayScroller()

    let documentView = NSView(frame: NSRect(x: 0, y: 0, width: viewportSize.width, height: 80))
    scrollView.documentView = documentView

    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: viewportSize),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = scrollView
    scrollView.frame = NSRect(origin: .zero, size: viewportSize)
    scrollView.layoutSubtreeIfNeeded()
    scrollView.setRevealScrollerOnHover(true)

    let pointerInside = scrollView.contentView.convert(
        NSPoint(x: scrollView.contentView.bounds.midX, y: scrollView.contentView.bounds.midY),
        to: nil
    )
    scrollView.syncPointerState(windowPoint: pointerInside, isActive: true)
    require(
        (scrollView.verticalScroller?.alphaValue ?? 0) <= 0.01,
        "Short Markdown content must not reveal a vertical scroller on Hover. " +
            "documentHeight=\(documentView.bounds.height) viewportHeight=\(scrollView.contentView.bounds.height)"
    )

    documentView.frame.size.height = 180
    scrollView.reflectScrolledClipView(scrollView.contentView)
    scrollView.syncPointerState(windowPoint: pointerInside, isActive: true)
    require(
        (scrollView.verticalScroller?.alphaValue ?? 0) > 0.01,
        "Overflowing Markdown content must reveal its vertical scroller on Hover."
    )

    documentView.frame.size.height = 80
    scrollView.reflectScrolledClipView(scrollView.contentView)
    scrollView.syncPointerState(windowPoint: pointerInside, isActive: true)
    require(
        (scrollView.verticalScroller?.alphaValue ?? 0) <= 0.01,
        "The vertical scroller must hide after Markdown content shrinks below one viewport."
    )

    print("HoverRevealScrollerRegressionTests passed")
}
