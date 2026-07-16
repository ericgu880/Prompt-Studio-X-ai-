import Foundation
import LocalAuthentication
import Security

protocol LicenseValueStore: AnyObject {
    func string(_ key: KeychainLicenseStore.Key) throws -> String?
    func data(_ key: KeychainLicenseStore.Key) throws -> Data?
    func save(_ value: String, for key: KeychainLicenseStore.Key) throws
    func save(_ value: Data, for key: KeychainLicenseStore.Key) throws
    func delete(_ key: KeychainLicenseStore.Key) throws
}

protocol LicenseStore: LicenseValueStore {
    func prepareForBackgroundAccess() throws
    func migrateLegacyItemsToVault() throws
    func createFreshVaultForReactivation(now: Date) throws
    func withInteractiveAuthentication(
        context: LAContext,
        _ operation: () throws -> Void
    ) throws
}

final class KeychainLicenseStore: LicenseStore {
    typealias CopyMatching = (
        CFDictionary,
        UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus
    typealias Update = (CFDictionary, CFDictionary) -> OSStatus
    typealias Add = (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus

    private let legacyService = "com.creatigo.promptstudio.license"
    private let vaultServices = (2...16).map { "com.creatigo.promptstudio.license.v\($0)" }
    private let vaultAccount = "promptstudio.licenseVault"
    private let copyMatching: CopyMatching
    private let update: Update
    private let add: Add
    private let locator: any LicenseVaultLocatorStore
    private let makeUUID: () -> UUID
    private let backgroundContext: LAContext
    private var interactiveContext: LAContext?
    private var preferredVaultService: String?
    private var discoveredLegacyKeys: [Key]?
    private var confirmedNoLegacyItems = false
    private static let currentMigrationVersion = 1

    enum Key: String, CaseIterable {
        case installId = "promptstudio.installId"
        case devicePrivateKey = "promptstudio.devicePrivateKey"
        case devicePublicKey = "promptstudio.devicePublicKey"
        case activationId = "promptstudio.activationId"
        case licenseCertificate = "promptstudio.licenseCertificate"
        case licenseRevocation = "promptstudio.licenseRevocation"
        case trialStartedAt = "promptstudio.trialStartedAt"
        case lastTrustedServerTime = "promptstudio.lastTrustedServerTime"
        case licenseRecoveryMarker = "promptstudio.licenseRecoveryMarker"
    }

    private struct Vault: Codable, Equatable {
        var migrationVersion: Int?
        var values: [String: Data]
    }

    private struct LocatedVault {
        let service: String
        var vault: Vault
    }

    private struct VaultRepairRead {
        let vault: Vault?
        let isCorrupted: Bool

        var itemExists: Bool { vault != nil || isCorrupted }
    }

    init(
        copyMatching: @escaping CopyMatching = SecItemCopyMatching,
        update: @escaping Update = SecItemUpdate,
        add: @escaping Add = SecItemAdd,
        locator: any LicenseVaultLocatorStore = UserDefaultsLicenseVaultLocator(),
        makeUUID: @escaping () -> UUID = UUID.init
    ) {
        self.copyMatching = copyMatching
        self.update = update
        self.add = add
        self.locator = locator
        self.makeUUID = makeUUID
        let context = LAContext()
        context.interactionNotAllowed = true
        self.backgroundContext = context
    }

    func prepareForBackgroundAccess() throws {
        preferredVaultService = nil
        let locatedVault: LocatedVault?
        do {
            locatedVault = try readPreferredVault()
        } catch LicenseError.keychainVaultCorrupted {
            throw LicenseError.keychainAccessRequired
        }
        if let locatedVault {
            if locatedVault.vault.migrationVersion == Self.currentMigrationVersion {
                return
            }
            throw LicenseError.keychainAccessRequired
        }
        if !(try discoverLegacyKeys()).isEmpty {
            throw LicenseError.keychainAccessRequired
        }
        confirmedNoLegacyItems = true
    }

    func migrateLegacyItemsToVault() throws {
        var highestExistingIndex: Int?
        var highestRead: VaultRepairRead?
        for index in vaultServices.indices.reversed() {
            let read = try readVaultForRepair(service: vaultServices[index])
            if read.itemExists {
                highestExistingIndex = index
                highestRead = read
                break
            }
        }

        guard let highestExistingIndex, let highestRead else {
            let values = try readAllLegacyValues()
            guard !values.isEmpty else {
                confirmedNoLegacyItems = true
                return
            }
            let vault = Vault(migrationVersion: Self.currentMigrationVersion, values: values)
            try writeAndVerify(vault, service: vaultServices[0])
            preferredVaultService = vaultServices[0]
            confirmedNoLegacyItems = true
            return
        }

        guard highestExistingIndex + 1 < vaultServices.count else {
            throw LicenseError.keychain(
                "License Vault 恢复槽已用尽。现有记录仍保留，请联系支持人员处理。"
            )
        }

        let values: [String: Data]
        if let vault = highestRead.vault,
           vault.migrationVersion == Self.currentMigrationVersion {
            values = vault.values
        } else {
            var validVaultsNewestFirst: [Vault] = []
            if let highestVault = highestRead.vault {
                validVaultsNewestFirst.append(highestVault)
            }
            if highestExistingIndex > 0 {
                for index in stride(from: highestExistingIndex - 1, through: 0, by: -1) {
                    if let lowerVault = try readVaultForRepair(
                        service: vaultServices[index]
                    ).vault {
                        validVaultsNewestFirst.append(lowerVault)
                        if lowerVault.migrationVersion == Self.currentMigrationVersion {
                            break
                        }
                    }
                }
            }

            let hasCompleteVault = validVaultsNewestFirst.contains {
                $0.migrationVersion == Self.currentMigrationVersion
            }
            var recoveredValues = hasCompleteVault ? [:] : try readAllLegacyValues()
            for vault in validVaultsNewestFirst.reversed() {
                recoveredValues.merge(vault.values) { _, newerValue in newerValue }
            }
            // The preferred generation is corrupt or incomplete. Every lower
            // generation (even a complete one) may predate an intentional
            // deactivation, so recover identity/trial state only and require the
            // server to issue a fresh activation.
            recoveredValues[Key.activationId.rawValue] = nil
            recoveredValues[Key.licenseCertificate.rawValue] = nil
            guard !recoveredValues.isEmpty else {
                throw LicenseError.keychainVaultCorrupted
            }
            values = recoveredValues
        }

        let reboundVault = Vault(
            migrationVersion: Self.currentMigrationVersion,
            values: values
        )
        try writeAndVerify(
            reboundVault,
            service: vaultServices[highestExistingIndex + 1]
        )
        preferredVaultService = vaultServices[highestExistingIndex + 1]
        confirmedNoLegacyItems = true
    }

    func createFreshVaultForReactivation(now: Date) throws {
        let id = makeUUID()
        let reference = LicenseVaultReference(
            id: id,
            service: "com.creatigo.promptstudio.license.vault.\(id.uuidString.lowercased())",
            account: vaultAccount
        )
        let marker = LicenseRecoveryMarker(
            version: 1,
            mode: .newIdentity,
            createdAt: now,
            blocksTrialBootstrap: true
        )
        let markerData: Data
        do {
            markerData = try JSONEncoder().encode(marker)
        } catch {
            throw LicenseError.keychain("License 恢复标记编码失败。")
        }
        let vault = Vault(
            migrationVersion: Self.currentMigrationVersion,
            values: [Key.licenseRecoveryMarker.rawValue: markerData]
        )

        var locatorState = try locator.load()
        locatorState.pending = reference
        try locator.save(locatorState)
        try addNewVaultAndVerify(vault, reference: reference)
        locatorState.active = reference
        locatorState.pending = nil
        try locator.save(locatorState)

        preferredVaultService = reference.service
        discoveredLegacyKeys = []
        confirmedNoLegacyItems = true
    }

    func withInteractiveAuthentication(
        context: LAContext,
        _ operation: () throws -> Void
    ) throws {
        let previousContext = interactiveContext
        interactiveContext = context
        defer { interactiveContext = previousContext }
        try operation()
    }

    func string(_ key: Key) throws -> String? {
        try data(key).flatMap { String(data: $0, encoding: .utf8) }
    }

    func data(_ key: Key) throws -> Data? {
        try readPreferredVault()?.vault.values[key.rawValue]
    }

    func save(_ value: String, for key: Key) throws {
        try save(Data(value.utf8), for: key)
    }

    func save(_ value: Data, for key: Key) throws {
        let locatedVault = try readPreferredVault()
        var vault = locatedVault?.vault ?? Vault(
            migrationVersion: confirmedNoLegacyItems ? Self.currentMigrationVersion : nil,
            values: [:]
        )
        vault.values[key.rawValue] = value
        let service = locatedVault?.service ?? vaultServices[0]
        try writeVault(vault, service: service)
        preferredVaultService = service
    }

    func delete(_ key: Key) throws {
        guard var locatedVault = try readPreferredVault() else { return }
        locatedVault.vault.values[key.rawValue] = nil
        try writeVault(locatedVault.vault, service: locatedVault.service)
    }

    private func readPreferredVault() throws -> LocatedVault? {
        var locatorState = try locator.load()
        if let active = locatorState.active {
            guard isValidRandomVaultReference(active) else {
                throw LicenseError.keychainVaultCorrupted
            }
            if locatorState.pending != nil {
                locatorState.pending = nil
                try locator.save(locatorState)
            }
            guard let vault = try readVault(
                service: active.service,
                account: active.account
            ) else {
                throw LicenseError.keychainVaultCorrupted
            }
            preferredVaultService = active.service
            return LocatedVault(service: active.service, vault: vault)
        }
        if let pending = locatorState.pending {
            guard isValidRandomVaultReference(pending),
                  let vault = try readVault(
                      service: pending.service,
                      account: pending.account
                  ),
                  hasRecoveryMarker(vault) else {
                throw LicenseError.keychainVaultCorrupted
            }
            locatorState.active = pending
            locatorState.pending = nil
            try locator.save(locatorState)
            preferredVaultService = pending.service
            return LocatedVault(service: pending.service, vault: vault)
        }

        if let preferredVaultService,
           let vault = try readVault(service: preferredVaultService) {
            return LocatedVault(service: preferredVaultService, vault: vault)
        }
        preferredVaultService = nil
        for service in vaultServices.reversed() {
            if let vault = try readVault(service: service) {
                preferredVaultService = service
                return LocatedVault(service: service, vault: vault)
            }
        }
        return nil
    }

    private func readVault(service: String) throws -> Vault? {
        try readVault(service: service, account: vaultAccount)
    }

    private func readVault(service: String, account: String) throws -> Vault? {
        let repairRead = try readVaultForRepair(service: service, account: account)
        if repairRead.isCorrupted {
            throw LicenseError.keychainVaultCorrupted
        }
        return repairRead.vault
    }

    private func readVaultForRepair(service: String) throws -> VaultRepairRead {
        try readVaultForRepair(service: service, account: vaultAccount)
    }

    private func readVaultForRepair(service: String, account: String) throws -> VaultRepairRead {
        guard let encoded = try readItem(
            itemQuery(service: service, account: account)
        ) else {
            return VaultRepairRead(vault: nil, isCorrupted: false)
        }
        do {
            return VaultRepairRead(
                vault: try JSONDecoder().decode(Vault.self, from: encoded),
                isCorrupted: false
            )
        } catch {
            return VaultRepairRead(vault: nil, isCorrupted: true)
        }
    }

    private func writeAndVerify(_ vault: Vault, service: String) throws {
        try writeVault(vault, service: service)
        guard try readVault(service: service) == vault else {
            throw LicenseError.keychain("迁移后的 License Vault 校验失败。旧记录仍保留，未做删除。")
        }
    }

    private func addNewVaultAndVerify(
        _ vault: Vault,
        reference: LicenseVaultReference
    ) throws {
        let value: Data
        do {
            value = try JSONEncoder().encode(vault)
        } catch {
            throw LicenseError.keychain("License Vault 编码失败。")
        }

        var addQuery = itemQuery(
            service: reference.service,
            account: reference.account
        )
        addQuery[kSecValueData as String] = value
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        try check(add(addQuery as CFDictionary, nil))

        guard let verified = try readVault(
            service: reference.service,
            account: reference.account
        ), verified == vault else {
            throw LicenseError.keychainVaultCorrupted
        }
    }

    private func writeVault(_ vault: Vault, service: String) throws {
        let value: Data
        do {
            value = try JSONEncoder().encode(vault)
        } catch {
            throw LicenseError.keychain("License Vault 编码失败。")
        }

        let query = vaultQuery(service: service)
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = update(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            try check(add(addQuery as CFDictionary, nil))
            return
        }
        try check(status)
    }

    private func readItem(_ baseQuery: [String: Any]) throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return result as? Data
    }

    private func discoverLegacyKeys() throws -> [Key] {
        if let discoveredLegacyKeys {
            return discoveredLegacyKeys
        }

        var query = itemQuery(service: legacyService, account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            discoveredLegacyKeys = []
            return []
        }
        try check(status)

        let items = (result as? [Any]) ?? (result.map { [$0] } ?? [])
        let found = Set(items.compactMap { item -> Key? in
            guard let attributes = item as? [String: Any],
                  let account = attributes[kSecAttrAccount as String] as? String else {
                return nil
            }
            return Key(rawValue: account)
        })
        let keys = Key.allCases.filter(found.contains)
        discoveredLegacyKeys = keys
        return keys
    }

    private func readAllLegacyValues() throws -> [String: Data] {
        let keys = try discoverLegacyKeys()
        var values: [String: Data] = [:]
        for key in keys {
            if let value = try readItem(
                itemQuery(service: legacyService, account: key.rawValue)
            ) {
                values[key.rawValue] = value
            }
        }
        return values
    }

    private func check(_ status: OSStatus) throws {
        if status == errSecInteractionNotAllowed
            || status == errSecInteractionRequired
            || (status == errSecAuthFailed && interactiveContext == nil) {
            throw LicenseError.keychainAccessRequired
        }
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String?
                ?? "未知 Keychain 错误"
            throw LicenseError.keychain("\(message)（OSStatus \(status)）")
        }
    }

    private func vaultQuery(service: String) -> [String: Any] {
        itemQuery(service: service, account: vaultAccount)
    }

    private func isValidRandomVaultReference(_ reference: LicenseVaultReference) -> Bool {
        reference.account == vaultAccount
            && reference.service
                == "com.creatigo.promptstudio.license.vault.\(reference.id.uuidString.lowercased())"
    }

    private func hasRecoveryMarker(_ vault: Vault) -> Bool {
        guard let data = vault.values[Key.licenseRecoveryMarker.rawValue],
              let marker = try? JSONDecoder().decode(
                  LicenseRecoveryMarker.self,
                  from: data
              ) else {
            return false
        }
        return marker.version == 1
    }

    private func itemQuery(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseAuthenticationContext as String: interactiveContext ?? backgroundContext
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }
}
