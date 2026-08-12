import Foundation
import Combine

struct PetPreferences: Codable, Equatable, Sendable {
    static let defaults = PetPreferences(
        showOnLaunch: true,
        captureEnabled: true,
        soundEnabled: false,
        defaultFolderID: "folder-capture-inbox",
        clearSourceAfterCapture: false,
        hostRegistrationEnabled: true
    )

    var showOnLaunch: Bool
    var captureEnabled: Bool
    var soundEnabled: Bool
    var defaultFolderID: String
    var clearSourceAfterCapture: Bool
    var hostRegistrationEnabled: Bool

    init(
        showOnLaunch: Bool = true,
        captureEnabled: Bool = true,
        soundEnabled: Bool = false,
        defaultFolderID: String = "folder-capture-inbox",
        clearSourceAfterCapture: Bool = false,
        hostRegistrationEnabled: Bool = true
    ) {
        self.showOnLaunch = showOnLaunch
        self.captureEnabled = captureEnabled
        self.soundEnabled = soundEnabled
        self.defaultFolderID = defaultFolderID
        self.clearSourceAfterCapture = clearSourceAfterCapture
        self.hostRegistrationEnabled = hostRegistrationEnabled
    }
}

@MainActor
final class PetPreferencesStore: ObservableObject {
    static let shared = PetPreferencesStore()

    static let userDefaultsKey = "PromptStudio.petPreferences"

    @Published private(set) var value: PetPreferences

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        value = Self.load(from: userDefaults)
    }

    func update(_ value: PetPreferences, persist: Bool = true) {
        self.value = value
        if persist {
            Self.save(value, to: userDefaults)
            NotificationCenter.default.post(name: .petPreferencesDidChange, object: value)
        }
    }

    func reset() {
        update(.defaults)
    }

    static func load(from userDefaults: UserDefaults = .standard) -> PetPreferences {
        guard let data = userDefaults.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode(PetPreferences.self, from: data) else {
            return .defaults
        }
        return decoded
    }

    static func save(_ value: PetPreferences, to userDefaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        userDefaults.set(data, forKey: userDefaultsKey)
    }
}
