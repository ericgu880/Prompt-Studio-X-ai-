import Foundation

enum LicenseRecoveryOption: String, Codable, Sendable {
    case preserveAndMigrate
    case newIdentityAndReactivate
}

enum LicenseRecoveryPhase: Equatable, Sendable {
    case notRequired
    case choiceRequired
    case working(LicenseRecoveryOption)
    case reactivationRequired
    case completed
    case failed(option: LicenseRecoveryOption, message: String)
}

struct LicenseRecoveryMarker: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable {
        case migratedExisting
        case newIdentity
    }

    let version: Int
    let mode: Mode
    let createdAt: Date
    let blocksTrialBootstrap: Bool
}

struct LicenseVaultReference: Codable, Equatable, Sendable {
    let id: UUID
    let service: String
    let account: String
}

struct LicenseVaultLocatorState: Codable, Equatable, Sendable {
    var active: LicenseVaultReference?
    var pending: LicenseVaultReference?

    static let empty = LicenseVaultLocatorState(active: nil, pending: nil)
}

protocol LicenseVaultLocatorStore: Sendable {
    func load() throws -> LicenseVaultLocatorState
    func save(_ state: LicenseVaultLocatorState) throws
}

final class UserDefaultsLicenseVaultLocator: LicenseVaultLocatorStore, @unchecked Sendable {
    private static let storageKey = "PromptStudioLicenseVaultLocatorState.v1"

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.defaults = defaults
        self.encoder = encoder
        self.decoder = decoder
    }

    func load() throws -> LicenseVaultLocatorState {
        try withLock {
            guard let storedValue = defaults.object(forKey: Self.storageKey) else {
                return .empty
            }
            guard let data = storedValue as? Data else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: [],
                        debugDescription: "License vault locator state is not encoded data"
                    )
                )
            }
            return try decoder.decode(LicenseVaultLocatorState.self, from: data)
        }
    }

    func save(_ state: LicenseVaultLocatorState) throws {
        try withLock {
            let data = try encoder.encode(state)
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
