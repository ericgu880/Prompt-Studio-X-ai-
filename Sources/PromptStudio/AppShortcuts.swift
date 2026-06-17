import AppKit
import SwiftUI

enum AppShortcutAction: String, CaseIterable, Codable, Identifiable {
    case newPrompt
    case copyContent
    case preview
    case navigateBack
    case navigateForward

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newPrompt:
            "新建 Prompt"
        case .copyContent:
            "复制内容"
        case .preview:
            "沉浸预览"
        case .navigateBack:
            "返回上一步"
        case .navigateForward:
            "前进一步"
        }
    }

    var detail: String {
        switch self {
        case .newPrompt:
            "打开新建 Prompt 页面"
        case .copyContent:
            "复制当前输入或选中的文件"
        case .preview:
            "打开或关闭预览"
        case .navigateBack:
            "非输入状态回到上一步"
        case .navigateForward:
            "非输入状态前进一步"
        }
    }
}

struct AppShortcutModifierSet: OptionSet, Codable, Hashable {
    let rawValue: Int

    static let command = AppShortcutModifierSet(rawValue: 1 << 0)
    static let shift = AppShortcutModifierSet(rawValue: 1 << 1)
    static let option = AppShortcutModifierSet(rawValue: 1 << 2)
    static let control = AppShortcutModifierSet(rawValue: 1 << 3)

    var eventModifiers: EventModifiers {
        var modifiers = EventModifiers()
        if contains(.command) { modifiers.insert(.command) }
        if contains(.shift) { modifiers.insert(.shift) }
        if contains(.option) { modifiers.insert(.option) }
        if contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    var displayText: String {
        var value = ""
        if contains(.control) { value += "⌃" }
        if contains(.option) { value += "⌥" }
        if contains(.shift) { value += "⇧" }
        if contains(.command) { value += "⌘" }
        return value
    }

    var hasActivationModifier: Bool {
        contains(.command) || contains(.option) || contains(.control)
    }

    static func from(_ flags: NSEvent.ModifierFlags) -> AppShortcutModifierSet {
        let filtered = flags.intersection([.command, .shift, .option, .control])
        var result = AppShortcutModifierSet()
        if filtered.contains(.command) { result.insert(.command) }
        if filtered.contains(.shift) { result.insert(.shift) }
        if filtered.contains(.option) { result.insert(.option) }
        if filtered.contains(.control) { result.insert(.control) }
        return result
    }
}

struct AppShortcutBinding: Codable, Equatable, Hashable {
    var key: String
    var modifiers: AppShortcutModifierSet

    var keyEquivalent: KeyEquivalent {
        if key == Self.spaceKey {
            return .space
        }
        return KeyEquivalent(Character(displayKey.lowercased()))
    }

    var eventModifiers: EventModifiers {
        modifiers.eventModifiers
    }

    var displayText: String {
        "\(modifiers.displayText)\(displayKey)"
    }

    func matches(_ event: NSEvent) -> Bool {
        guard let eventKey = Self.keyString(for: event) else { return false }
        return key == eventKey && modifiers == AppShortcutModifierSet.from(event.modifierFlags)
    }

    static func defaultBinding(for action: AppShortcutAction) -> AppShortcutBinding {
        switch action {
        case .newPrompt:
            AppShortcutBinding(key: "n", modifiers: [.command])
        case .copyContent:
            AppShortcutBinding(key: "c", modifiers: [.command])
        case .preview:
            AppShortcutBinding(key: spaceKey, modifiers: [])
        case .navigateBack:
            AppShortcutBinding(key: "z", modifiers: [.command])
        case .navigateForward:
            AppShortcutBinding(key: "z", modifiers: [.command, .shift])
        }
    }

    static func from(event: NSEvent) -> AppShortcutBinding? {
        guard event.keyCode != 53, let key = keyString(for: event) else {
            return nil
        }
        return AppShortcutBinding(key: key, modifiers: AppShortcutModifierSet.from(event.modifierFlags))
    }

    static func keyString(for event: NSEvent) -> String? {
        if event.keyCode == 49 {
            return spaceKey
        }
        guard let characters = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines),
              let first = characters.lowercased().first else {
            return nil
        }
        return String(first)
    }

    private var displayKey: String {
        if key == Self.spaceKey {
            return "Space"
        }
        return key.uppercased()
    }

    private static let spaceKey = "space"
}

@MainActor
final class AppShortcutStore: ObservableObject {
    static let storageKey = "promptStudio.customShortcuts.v1"

    @Published private(set) var bindings: [AppShortcutAction: AppShortcutBinding]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.bindings = Self.loadBindings(from: defaults)
    }

    func binding(for action: AppShortcutAction) -> AppShortcutBinding {
        bindings[action] ?? AppShortcutBinding.defaultBinding(for: action)
    }

    func save(_ draft: [AppShortcutAction: AppShortcutBinding]) {
        let normalized = Self.normalized(draft)
        bindings = normalized
        let payload = AppShortcutAction.allCases.map { StoredShortcut(action: $0, binding: normalized[$0]!) }
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    func resetToDefaults() {
        save(Self.defaultBindings())
    }

    static func defaultBindings() -> [AppShortcutAction: AppShortcutBinding] {
        Dictionary(uniqueKeysWithValues: AppShortcutAction.allCases.map { ($0, AppShortcutBinding.defaultBinding(for: $0)) })
    }

    static func validationMessages(for draft: [AppShortcutAction: AppShortcutBinding]) -> [String] {
        var messages: [String] = []
        let normalized = normalized(draft)
        for action in AppShortcutAction.allCases {
            let binding = normalized[action]!
            if binding.key.isEmpty {
                messages.append("\(action.title) 不能为空。")
            }
            if !binding.modifiers.hasActivationModifier && !(action == .preview && binding.key == "space") {
                messages.append("\(action.title) 需要包含 ⌘ / ⌥ / ⌃ 中至少一个修饰键。")
            }
        }

        let grouped = Dictionary(grouping: AppShortcutAction.allCases) { action in
            let binding = normalized[action]!
            return "\(binding.modifiers.rawValue):\(binding.key)"
        }
        for actions in grouped.values where actions.count > 1 {
            messages.append(actions.map(\.title).joined(separator: "、") + " 不能使用同一个快捷键。")
        }
        return messages
    }

    private let defaults: UserDefaults

    private static func loadBindings(from defaults: UserDefaults) -> [AppShortcutAction: AppShortcutBinding] {
        guard let data = defaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode([StoredShortcut].self, from: data) else {
            return defaultBindings()
        }
        return normalized(Dictionary(uniqueKeysWithValues: stored.map { ($0.action, $0.binding) }))
    }

    private static func normalized(_ bindings: [AppShortcutAction: AppShortcutBinding]) -> [AppShortcutAction: AppShortcutBinding] {
        var result = defaultBindings()
        for action in AppShortcutAction.allCases {
            if let binding = bindings[action] {
                result[action] = binding
            }
        }
        return result
    }

    private struct StoredShortcut: Codable {
        let action: AppShortcutAction
        let binding: AppShortcutBinding
    }
}
