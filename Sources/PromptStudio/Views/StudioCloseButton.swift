import SwiftUI

enum StudioCloseButtonMetrics {
    static let diameter: CGFloat = 34
    static let iconSize: CGFloat = 12
    static let topInset: CGFloat = 24
    static let trailingInset: CGFloat = 24
}

struct StudioCloseButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var help = "关闭"
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(StudioFont.symbol(StudioCloseButtonMetrics.iconSize, weight: .semibold))
                .frame(
                    width: StudioCloseButtonMetrics.diameter,
                    height: StudioCloseButtonMetrics.diameter
                )
                .background(
                    Circle().fill(isHovered ? StudioColor.selection : StudioColor.control.opacity(0.92))
                )
                .overlay(
                    Circle().stroke(
                        isHovered ? StudioColor.primaryAction.opacity(0.42) : StudioColor.hairline,
                        lineWidth: 1
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(
            width: StudioCloseButtonMetrics.diameter,
            height: StudioCloseButtonMetrics.diameter
        )
        .contentShape(Circle())
        .onHover { isHovered = $0 }
        .scaleEffect(reduceMotion ? 1 : (isHovered ? 1.04 : 1))
        .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: isHovered)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct StudioTopTrailingCloseButtonModifier: ViewModifier {
    let isPresented: Bool
    let help: String
    let action: () -> Void

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if isPresented {
                StudioCloseButton(help: help, action: action)
                    .padding(.top, StudioCloseButtonMetrics.topInset)
                    .padding(.trailing, StudioCloseButtonMetrics.trailingInset)
                    .ignoresSafeArea(.container, edges: [.top, .trailing])
            }
        }
    }
}

extension View {
    func studioTopTrailingCloseButton(
        isPresented: Bool = true,
        help: String = "关闭",
        action: @escaping () -> Void
    ) -> some View {
        modifier(
            StudioTopTrailingCloseButtonModifier(
                isPresented: isPresented,
                help: help,
                action: action
            )
        )
    }
}
