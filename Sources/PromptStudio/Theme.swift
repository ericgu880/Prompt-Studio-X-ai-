import SwiftUI

enum StudioColor {
    static let appBackground = Color(red: 0.060, green: 0.060, blue: 0.060)
    static let sidebar = Color(red: 0.245, green: 0.245, blue: 0.245)
    static let panel = Color(red: 0.120, green: 0.120, blue: 0.120)
    static let panelRaised = Color(red: 0.175, green: 0.175, blue: 0.175)
    static let control = Color(red: 0.150, green: 0.150, blue: 0.150)
    static let controlPressed = Color(red: 0.210, green: 0.210, blue: 0.210)
    static let selection = Color.white.opacity(0.11)
    static let hairline = Color.white.opacity(0.11)
    static let text = Color.white.opacity(0.94)
    static let secondaryText = Color.white.opacity(0.66)
    static let tertiaryText = Color.white.opacity(0.43)
    static let primaryAction = Color.white.opacity(0.94)
    static let primaryActionText = Color.black.opacity(0.86)
    static let blue = Color(red: 0.560, green: 0.720, blue: 0.920)
    static let blueSoft = Color(red: 0.220, green: 0.270, blue: 0.330)
    static let orange = Color(red: 1.0, green: 0.48, blue: 0.10)
}

extension View {
    func studioPanel(radius: CGFloat = 12) -> some View {
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
}

struct CapsuleButtonStyle: ButtonStyle {
    var filled = false
    var accent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(filled ? StudioColor.primaryActionText : StudioColor.text)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(
                Capsule()
                    .fill(filled ? StudioColor.primaryAction : (accent ? StudioColor.selection : StudioColor.control))
            )
            .overlay(
                Capsule()
                    .stroke(accent ? StudioColor.blue : StudioColor.hairline, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct IconCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(StudioColor.text)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.black.opacity(0.58)))
            .overlay(Circle().stroke(StudioColor.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
