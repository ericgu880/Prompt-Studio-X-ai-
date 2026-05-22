import SwiftUI

enum StudioColor {
    static let appBackground = Color(hex: 0x0A0A0A)
    static let sidebar = Color(hex: 0x0A0A0A)
    static let panel = Color(hex: 0x191919)
    static let panelRaised = Color(hex: 0x1A1C20)
    static let control = Color(hex: 0x0A0A0A)
    static let controlPressed = Color(hex: 0x1A1C20)
    static let selection = Color(hex: 0x1A1C20)
    static let hairline = Color(hex: 0x212327)
    static let text = Color(hex: 0xFFFFFF)
    static let secondaryText = Color(hex: 0xDADBDF)
    static let tertiaryText = Color(hex: 0x7D8187)
    static let primaryAction = Color(hex: 0xFFFFFF)
    static let primaryActionText = Color(hex: 0x0A0A0A)
    static let blue = Color(hex: 0xA0C3EC)
    static let blueSoft = Color(hex: 0x0D1726)
    static let orange = Color(hex: 0xFF7A17)
    static let dusk = Color(hex: 0x7C3AED)
    static let twilight = Color(hex: 0xC4B5FD)
}

enum StudioMotion {
    enum Kind {
        case fast
        case standard
        case spring
    }

    static let fastDuration: TimeInterval = 0.12
    static let standardDuration: TimeInterval = 0.18
    static let springResponse: TimeInterval = 0.24

    static func animation(_ kind: Kind, reduceMotion: Bool) -> Animation {
        switch kind {
        case .fast:
            fast(reduceMotion: reduceMotion)
        case .standard:
            standard(reduceMotion: reduceMotion)
        case .spring:
            spring(reduceMotion: reduceMotion)
        }
    }

    static func fast(reduceMotion: Bool) -> Animation {
        .easeOut(duration: reduceMotion ? 0.08 : fastDuration)
    }

    static func standard(reduceMotion: Bool) -> Animation {
        .easeInOut(duration: reduceMotion ? 0.10 : standardDuration)
    }

    static func spring(reduceMotion: Bool) -> Animation {
        reduceMotion ? standard(reduceMotion: true) : .spring(response: springResponse, dampingFraction: 0.86)
    }

    static func toastTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.98))
    }

    static func contentTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985))
    }

    static func inspectorTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .opacity
        )
    }
}

extension View {
    func studioPanel(radius: CGFloat = 8) -> some View {
        background(StudioColor.panel)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(StudioColor.hairline, lineWidth: 1)
            )
    }

    func promptShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        keyboardShortcut(key, modifiers: modifiers)
    }

    func studioAnimation<Value: Equatable>(_ kind: StudioMotion.Kind = .standard, value: Value) -> some View {
        modifier(StudioAnimationModifier(kind: kind, value: value))
    }
}

private struct StudioAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: StudioMotion.Kind
    let value: Value

    func body(content: Content) -> some View {
        content.animation(StudioMotion.animation(kind, reduceMotion: reduceMotion), value: value)
    }
}

private struct StudioMotionScale: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let hovered: Bool
    let pressed: Bool
    let hoverScale: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion ? 1 : (pressed ? 0.985 : (hovered ? hoverScale : 1)))
            .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: hovered)
            .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: pressed)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255.0,
            green: Double((hex >> 8) & 0xff) / 255.0,
            blue: Double(hex & 0xff) / 255.0
        )
    }
}

struct CapsuleButtonStyle: ButtonStyle {
    var filled = false
    var accent = false

    func makeBody(configuration: Configuration) -> some View {
        CapsuleButtonBody(configuration: configuration, filled: filled, accent: accent)
    }
}

private struct CapsuleButtonBody: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let configuration: ButtonStyle.Configuration
    let filled: Bool
    let accent: Bool
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(filled ? StudioColor.primaryActionText : StudioColor.text)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(
                Capsule()
                    .fill(backgroundColor)
            )
            .overlay(
                Capsule()
                    .stroke(borderColor, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
            .onHover { isHovered = $0 }
            .modifier(StudioMotionScale(hovered: isHovered, pressed: configuration.isPressed, hoverScale: 1.012))
            .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: isHovered)
            .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: configuration.isPressed)
    }

    private var backgroundColor: Color {
        if filled {
            return isHovered && !configuration.isPressed ? StudioColor.secondaryText : StudioColor.primaryAction
        }
        if configuration.isPressed || accent || isHovered {
            return StudioColor.selection
        }
        return StudioColor.control
    }

    private var borderColor: Color {
        if accent || isHovered {
            return StudioColor.primaryAction.opacity(accent ? 0.72 : 0.42)
        }
        return StudioColor.hairline
    }
}

struct IconCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconCircleButtonBody(configuration: configuration)
    }
}

private struct IconCircleButtonBody: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let configuration: ButtonStyle.Configuration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(StudioColor.text)
            .frame(width: 28, height: 28)
            .background(Circle().fill(isHovered || configuration.isPressed ? StudioColor.selection : StudioColor.control))
            .overlay(Circle().stroke(isHovered ? StudioColor.primaryAction.opacity(0.42) : StudioColor.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.72 : 1)
            .contentShape(Circle())
            .onHover { isHovered = $0 }
            .modifier(StudioMotionScale(hovered: isHovered, pressed: configuration.isPressed, hoverScale: 1.04))
            .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: isHovered)
            .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

struct PanelHoverButtonStyle: ButtonStyle {
    var radius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        PanelHoverButtonBody(configuration: configuration, radius: radius)
    }
}

private struct PanelHoverButtonBody: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let configuration: ButtonStyle.Configuration
    let radius: CGFloat
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .background(isHovered || configuration.isPressed ? StudioColor.selection : StudioColor.control)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(isHovered ? StudioColor.primaryAction.opacity(0.42) : StudioColor.hairline, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.76 : 1)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { isHovered = $0 }
            .modifier(StudioMotionScale(hovered: isHovered, pressed: configuration.isPressed, hoverScale: 1.01))
            .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: isHovered)
            .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

struct TextHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TextHoverButtonBody(configuration: configuration)
    }
}

private struct TextHoverButtonBody: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let configuration: ButtonStyle.Configuration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(isHovered ? StudioColor.text : StudioColor.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(isHovered || configuration.isPressed ? StudioColor.selection : Color.clear))
            .overlay(Capsule().stroke(isHovered ? StudioColor.hairline : Color.clear, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.72 : 1)
            .contentShape(Capsule())
            .onHover { isHovered = $0 }
            .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: isHovered)
            .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}
