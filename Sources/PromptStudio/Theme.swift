import SwiftUI

enum StudioColor {
    static let appBackground = Color(red: 0.030, green: 0.040, blue: 0.055)
    static let sidebar = Color(red: 0.055, green: 0.078, blue: 0.098)
    static let panel = Color(red: 0.065, green: 0.086, blue: 0.106)
    static let panelRaised = Color(red: 0.085, green: 0.112, blue: 0.135)
    static let hairline = Color.white.opacity(0.09)
    static let text = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.40)
    static let blue = Color(red: 0.165, green: 0.445, blue: 0.900)
    static let blueSoft = Color(red: 0.125, green: 0.310, blue: 0.610)
    static let orange = Color(red: 1.0, green: 0.64, blue: 0.18)
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
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(filled ? Color.white : StudioColor.text)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(
                Capsule()
                    .fill(filled ? StudioColor.blue : StudioColor.panelRaised)
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
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.black.opacity(0.50)))
            .overlay(Circle().stroke(StudioColor.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
