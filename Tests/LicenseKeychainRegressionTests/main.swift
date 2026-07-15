import CryptoKit
import Foundation
import LocalAuthentication
import Security

private final class CopyMatchingRecorder {
    var status: OSStatus = errSecSuccess
    var resultData = Data(#"{"migrationVersion":1,"values":{"promptstudio.licenseCertificate":"dmFsdWU="}}"#.utf8)
    private(set) var queries: [[String: Any]] = []

    func call(
        _ query: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        queries.append(query as NSDictionary as! [String: Any])
        if status == errSecSuccess {
            result?.pointee = resultData as CFData
        }
        return status
    }
}

private struct RecordingStoreFailure: Error {
    let message: String
}

private actor AsyncOperationGate {
    private var hasStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        hasStarted = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        for waiter in releaseWaiters {
            waiter.resume()
        }
        releaseWaiters.removeAll()
    }
}

private final class KeychainBackend {
    struct ItemKey: Hashable {
        let service: String
        let account: String
    }

    private(set) var items: [ItemKey: Data] = [:]
    private(set) var addedVaults = 0
    private(set) var interactiveLegacyBulkReads = 0
    private var backgroundRestrictedServices: Set<String> = []

    func seedLegacy(_ key: KeychainLicenseStore.Key, value: Data) {
        items[ItemKey(service: "com.creatigo.promptstudio.license", account: key.rawValue)] = value
    }

    func seedVault(
        _ encodedVault: Data,
        generation: Int = 2,
        requiresInteraction: Bool = false
    ) {
        let service = "com.creatigo.promptstudio.license.v\(generation)"
        items[ItemKey(service: service, account: "promptstudio.licenseVault")] = encodedVault
        if requiresInteraction {
            backgroundRestrictedServices.insert(service)
        }
    }

    func copyMatching(
        _ query: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        let attributes = query as NSDictionary
        if attributes[kSecAttrService as String] as? String == "com.creatigo.promptstudio.license",
           attributes[kSecAttrAccount as String] == nil {
            let legacyItems = items.filter { $0.key.service == "com.creatigo.promptstudio.license" }
            guard !legacyItems.isEmpty else { return errSecItemNotFound }
            if isBackground(attributes) {
                return errSecInteractionNotAllowed
            }
            interactiveLegacyBulkReads += 1
            let payload: [[String: Any]] = legacyItems.map { entry in
                [
                    kSecAttrAccount as String: entry.key.account,
                    kSecValueData as String: entry.value
                ]
            }
            result?.pointee = payload.count == 1
                ? payload[0] as CFDictionary
                : payload as CFArray
            return errSecSuccess
        }
        guard let key = itemKey(attributes), let value = items[key] else {
            return errSecItemNotFound
        }
        if (key.service == "com.creatigo.promptstudio.license" || backgroundRestrictedServices.contains(key.service)),
           isBackground(attributes) {
            return errSecInteractionNotAllowed
        }
        result?.pointee = value as CFData
        return errSecSuccess
    }

    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        let queryAttributes = query as NSDictionary
        guard let key = itemKey(queryAttributes), items[key] != nil else {
            return errSecItemNotFound
        }
        guard let value = (attributes as NSDictionary)[kSecValueData as String] as? Data else {
            return errSecParam
        }
        items[key] = value
        return errSecSuccess
    }

    func add(
        _ attributes: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        let dictionary = attributes as NSDictionary
        guard let key = itemKey(dictionary),
              let value = dictionary[kSecValueData as String] as? Data else {
            return errSecParam
        }
        guard items[key] == nil else { return errSecDuplicateItem }
        items[key] = value
        if key.service.hasPrefix("com.creatigo.promptstudio.license.v") {
            addedVaults += 1
        }
        return errSecSuccess
    }

    private func itemKey(_ attributes: NSDictionary) -> ItemKey? {
        guard let service = attributes[kSecAttrService as String] as? String,
              let account = attributes[kSecAttrAccount as String] as? String else {
            return nil
        }
        return ItemKey(service: service, account: account)
    }

    private func isBackground(_ attributes: NSDictionary) -> Bool {
        (attributes[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true
    }
}

private final class RecordingLicenseStore: LicenseStore {
    var values: [String: Data] = [:]
    var legacyMigrationRequired = false
    var preparationError: LicenseError?
    var deleteFailureKey: KeychainLicenseStore.Key?
    private(set) var reads: [KeychainLicenseStore.Key] = []
    private(set) var saves: [KeychainLicenseStore.Key] = []
    private(set) var interactiveRuns = 0
    private(set) var legacyMigrations = 0
    private(set) var backgroundReadsAfterMigration = 0
    private var isInteractive = false

    func prepareForBackgroundAccess() throws {
        if let preparationError { throw preparationError }
        if legacyMigrationRequired {
            throw LicenseError.keychainAccessRequired
        }
    }

    func migrateLegacyItemsToVault() throws {
        guard isInteractive else {
            throw RecordingStoreFailure(message: "legacy migration must run in the interactive session")
        }
        legacyMigrations += 1
        legacyMigrationRequired = false
    }

    func string(_ key: KeychainLicenseStore.Key) throws -> String? {
        try data(key).flatMap { String(data: $0, encoding: .utf8) }
    }

    func data(_ key: KeychainLicenseStore.Key) throws -> Data? {
        if legacyMigrations > 0 && !isInteractive {
            backgroundReadsAfterMigration += 1
        }
        reads.append(key)
        return values[key.rawValue]
    }

    func save(_ value: String, for key: KeychainLicenseStore.Key) throws {
        try save(Data(value.utf8), for: key)
    }

    func save(_ value: Data, for key: KeychainLicenseStore.Key) throws {
        saves.append(key)
        values[key.rawValue] = value
    }

    func delete(_ key: KeychainLicenseStore.Key) throws {
        if key == deleteFailureKey {
            throw RecordingStoreFailure(message: "injected delete failure")
        }
        values[key.rawValue] = nil
    }

    func withInteractiveAuthentication(
        context: LAContext,
        _ operation: () throws -> Void
    ) throws {
        interactiveRuns += 1
        isInteractive = true
        defer { isInteractive = false }
        try operation()
    }
}

@main
private enum LicenseKeychainRegressionTests {
    @MainActor
    static func main() async throws {
        try backgroundReadsNeverPresentAuthenticationUI()
        try interactionRequiredHasAFirstClassError()
        try interactiveReadsReuseOneAuthenticationContext()
        try legacyMigrationSurvivesANewBackgroundStore()
        try aSingleLegacyRecordCanBeMigrated()
        try aPartialVaultMergesMissingLegacyValues()
        try anIncompletePreferredVaultMergesACompleteLowerGeneration()
        try aVaultFromAnOldSignatureIsReboundWithoutDeletingIt()
        try aCorruptVaultCanBeRebuiltFromPreservedLegacyValues()
        try aPreferredVaultCanBeReboundAgainWithoutDeletingIt()
        try aCorruptPreferredVaultCanRecoverFromAnOlderVault()
        try corruptRecoveryDoesNotResurrectDeletedLegacyValues()
        try corruptOnlyVaultDoesNotRestoreStaleActivation()
        try corruptPreferredVaultDoesNotRestoreActivationFromACompleteOlderVault()
        try deviceIdentityDoesNotRewriteDerivedPublicKey()
        try trialStateReadsItsKeyOnce()
        try launchAccessFailureDoesNotCreateTrialOrIdentity()
        try nonInteractiveKeychainFailuresAreNotReportedAsRepairable()
        try legacyIdentityAloneRequiresRepairAtLaunch()
        try repairRunsOneInteractiveSessionAndReloadsState()
        try featureGateOffersKeychainRepair()
        try await serverRevocationPersistsUntilAValidReactivation()
        try await explicitDeactivationPersistsBeforeLocalCleanup()
        try await staleRevocationCannotDeleteANewerActivation()
        try await confirmedDeactivationSurvivesANewerSameActivationMutation()
        print("License keychain regression tests passed")
    }

    private static func backgroundReadsNeverPresentAuthenticationUI() throws {
        let recorder = CopyMatchingRecorder()
        let store = KeychainLicenseStore(copyMatching: recorder.call)

        _ = try store.data(.licenseCertificate)

        let query = try onlyQuery(in: recorder)
        guard let context = query[kSecUseAuthenticationContext as String] as? LAContext,
              context.interactionNotAllowed else {
            throw Failure("background keychain reads must use a non-interactive LAContext")
        }
    }

    private static func interactionRequiredHasAFirstClassError() throws {
        let recorder = CopyMatchingRecorder()
        recorder.status = errSecInteractionNotAllowed
        let store = KeychainLicenseStore(copyMatching: recorder.call)

        do {
            _ = try store.data(.licenseCertificate)
            throw Failure("interaction-not-allowed must not be treated as missing data")
        } catch LicenseError.keychainAccessRequired {
            // Expected: LicenseManager can show one explicit repair action.
        }
    }

    private static func interactiveReadsReuseOneAuthenticationContext() throws {
        let recorder = CopyMatchingRecorder()
        let store = KeychainLicenseStore(copyMatching: recorder.call)
        let context = LAContext()

        try store.withInteractiveAuthentication(context: context) {
            _ = try store.data(.licenseCertificate)
            _ = try store.data(.activationId)
            _ = try store.data(.devicePrivateKey)
        }

        guard recorder.queries.count == 3 else {
            throw Failure("expected three recorded keychain reads")
        }
        for query in recorder.queries {
            guard let recorded = query[kSecUseAuthenticationContext as String] as? LAContext,
                  recorded === context else {
                throw Failure("interactive keychain reads must reuse the supplied LAContext")
            }
            guard !recorded.interactionNotAllowed else {
                throw Failure("interactive reads must not reuse the background non-interactive context")
            }
        }
    }

    private static func legacyMigrationSurvivesANewBackgroundStore() throws {
        let backend = KeychainBackend()
        let startedAt = "2026-07-16T00:00:00Z"
        backend.seedLegacy(.trialStartedAt, value: Data(startedAt.utf8))
        backend.seedLegacy(.installId, value: Data("old-install-id".utf8))
        let store = KeychainLicenseStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )

        do {
            try store.prepareForBackgroundAccess()
            throw Failure("legacy items must require an explicit migration")
        } catch LicenseError.keychainAccessRequired {
            // Expected: background startup never opens a password dialog.
        }

        try store.withInteractiveAuthentication(context: LAContext()) {
            try store.migrateLegacyItemsToVault()
        }

        let freshStore = KeychainLicenseStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )
        try freshStore.prepareForBackgroundAccess()
        guard try freshStore.string(.trialStartedAt) == startedAt,
              try freshStore.string(.installId) == "old-install-id" else {
            throw Failure("a new background store must read every migrated value without interaction")
        }
        guard backend.addedVaults == 1 else {
            throw Failure("legacy migration must create exactly one consolidated vault")
        }
        guard backend.interactiveLegacyBulkReads == 1 else {
            throw Failure("legacy records must be fetched in one interactive keychain operation")
        }
        guard backend.items.keys.filter({ $0.service == "com.creatigo.promptstudio.license" }).count == 2 else {
            throw Failure("legacy records must be preserved after migration")
        }
    }

    private static func aSingleLegacyRecordCanBeMigrated() throws {
        let backend = KeychainBackend()
        backend.seedLegacy(.trialStartedAt, value: Data("2026-07-16T00:00:00Z".utf8))
        let store = KeychainLicenseStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )

        try store.withInteractiveAuthentication(context: LAContext()) {
            try store.migrateLegacyItemsToVault()
        }

        let freshStore = KeychainLicenseStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )
        try freshStore.prepareForBackgroundAccess()
        guard try freshStore.string(.trialStartedAt) == "2026-07-16T00:00:00Z" else {
            throw Failure("a single dictionary result from Security.framework must migrate correctly")
        }
    }

    private static func aPartialVaultMergesMissingLegacyValues() throws {
        let backend = KeychainBackend()
        backend.seedVault(Data(#"{"values":{"promptstudio.installId":"bmV3LWluc3RhbGwtaWQ="}}"#.utf8))
        backend.seedLegacy(.installId, value: Data("old-install-id".utf8))
        backend.seedLegacy(.trialStartedAt, value: Data("2026-07-16T00:00:00Z".utf8))
        let store = KeychainLicenseStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )

        do {
            try store.prepareForBackgroundAccess()
            throw Failure("a vault without a completed migration marker must inspect legacy records")
        } catch LicenseError.keychainAccessRequired {
            // Expected: incomplete vaults never hide old License records.
        }
        try store.withInteractiveAuthentication(context: LAContext()) {
            try store.migrateLegacyItemsToVault()
        }

        let freshStore = KeychainLicenseStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )
        try freshStore.prepareForBackgroundAccess()
        guard try freshStore.string(.installId) == "new-install-id" else {
            throw Failure("existing vault values must win over older legacy values")
        }
        guard try freshStore.string(.trialStartedAt) == "2026-07-16T00:00:00Z" else {
            throw Failure("missing vault fields must be filled from legacy records")
        }
    }

    private static func anIncompletePreferredVaultMergesACompleteLowerGeneration() throws {
        let backend = KeychainBackend()
        backend.seedVault(
            Data(#"{"migrationVersion":1,"values":{"promptstudio.installId":"djItaW5zdGFsbA==","promptstudio.trialStartedAt":"MjAyNi0wNy0xNlQwMDowMDowMFo="}}"#.utf8),
            generation: 2
        )
        backend.seedVault(
            Data(#"{"values":{"promptstudio.installId":"djMtaW5zdGFsbA=="}}"#.utf8),
            generation: 3
        )
        let store = KeychainLicenseStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )

        do {
            try store.prepareForBackgroundAccess()
            throw Failure("an incomplete preferred vault must be merged through explicit repair")
        } catch LicenseError.keychainAccessRequired {
            // Expected: background launch must not mark the partial v3 complete in place.
        }
        try store.withInteractiveAuthentication(context: LAContext()) {
            try store.migrateLegacyItemsToVault()
        }

        let freshStore = KeychainLicenseStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )
        try freshStore.prepareForBackgroundAccess()
        guard try freshStore.string(.installId) == "v3-install",
              try freshStore.string(.trialStartedAt) == "2026-07-16T00:00:00Z" else {
            throw Failure("v3 values must win while missing fields are retained from complete v2")
        }
    }

    private static func aVaultFromAnOldSignatureIsReboundWithoutDeletingIt() throws {
        let backend = KeychainBackend()
        backend.seedVault(
            Data(#"{"migrationVersion":1,"values":{"promptstudio.installId":"b2xkLXNpZ25hdHVyZS1pZA=="}}"#.utf8),
            requiresInteraction: true
        )
        let store = KeychainLicenseStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )

        do {
            try store.prepareForBackgroundAccess()
            throw Failure("a vault bound to an old signature must require repair")
        } catch LicenseError.keychainAccessRequired {
            // Expected after moving from an ad-hoc build to Developer ID.
        }
        try store.withInteractiveAuthentication(context: LAContext()) {
            try store.migrateLegacyItemsToVault()
        }

        let freshStore = KeychainLicenseStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )
        try freshStore.prepareForBackgroundAccess()
        guard try freshStore.string(.installId) == "old-signature-id" else {
            throw Failure("rebound vault must remain readable from a new non-interactive store")
        }
        let vaultServices = Set(backend.items.keys.map(\.service))
        guard vaultServices.contains("com.creatigo.promptstudio.license.v2"),
              vaultServices.contains("com.creatigo.promptstudio.license.v3") else {
            throw Failure("rebind must preserve the old vault as a backup and create a new vault")
        }
    }

    private static func aCorruptVaultCanBeRebuiltFromPreservedLegacyValues() throws {
        let backend = KeychainBackend()
        let corruptVault = Data("not-json".utf8)
        backend.seedVault(corruptVault)
        backend.seedLegacy(.installId, value: Data("preserved-install-id".utf8))
        let store = KeychainLicenseStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )

        do {
            try store.prepareForBackgroundAccess()
            throw Failure("a corrupt vault with preserved legacy values must offer repair")
        } catch LicenseError.keychainAccessRequired {
            // Expected: explicit repair can rebuild into a new vault slot.
        }
        try store.withInteractiveAuthentication(context: LAContext()) {
            try store.migrateLegacyItemsToVault()
        }

        let freshStore = KeychainLicenseStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )
        try freshStore.prepareForBackgroundAccess()
        guard try freshStore.string(.installId) == "preserved-install-id" else {
            throw Failure("repair must rebuild a corrupt vault from preserved legacy values")
        }
        let oldVaultKey = KeychainBackend.ItemKey(
            service: "com.creatigo.promptstudio.license.v2",
            account: "promptstudio.licenseVault"
        )
        guard backend.items[oldVaultKey] == corruptVault else {
            throw Failure("repair must preserve the corrupt vault for diagnosis and rollback")
        }
    }

    private static func aPreferredVaultCanBeReboundAgainWithoutDeletingIt() throws {
        let backend = KeychainBackend()
        let v3Data = Data(#"{"migrationVersion":1,"values":{"promptstudio.installId":"djMtaW5zdGFsbC1pZA=="}}"#.utf8)
        backend.seedVault(v3Data, generation: 3, requiresInteraction: true)
        let store = KeychainLicenseStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )

        do {
            try store.prepareForBackgroundAccess()
            throw Failure("a preferred vault bound to another signature must require repair")
        } catch LicenseError.keychainAccessRequired {
            // Expected: a new generation must be created under the current signature.
        }
        try store.withInteractiveAuthentication(context: LAContext()) {
            try store.migrateLegacyItemsToVault()
        }

        let freshStore = KeychainLicenseStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )
        try freshStore.prepareForBackgroundAccess()
        guard try freshStore.string(.installId) == "v3-install-id" else {
            throw Failure("a second rebound must remain readable without interaction")
        }
        let v3Key = KeychainBackend.ItemKey(
            service: "com.creatigo.promptstudio.license.v3",
            account: "promptstudio.licenseVault"
        )
        let v4Key = KeychainBackend.ItemKey(
            service: "com.creatigo.promptstudio.license.v4",
            account: "promptstudio.licenseVault"
        )
        guard backend.items[v3Key] == v3Data, backend.items[v4Key] != nil else {
            throw Failure("a second rebound must preserve v3 and create a fresh v4 slot")
        }
    }

    private static func aCorruptPreferredVaultCanRecoverFromAnOlderVault() throws {
        let backend = KeychainBackend()
        let v2Data = Data(#"{"migrationVersion":1,"values":{"promptstudio.installId":"djItYmFja3VwLWlk"}}"#.utf8)
        let corruptV3 = Data("corrupt-v3".utf8)
        backend.seedVault(v2Data, generation: 2)
        backend.seedVault(corruptV3, generation: 3)
        let store = KeychainLicenseStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )

        do {
            try store.prepareForBackgroundAccess()
            throw Failure("a corrupt preferred vault must offer explicit repair")
        } catch LicenseError.keychainAccessRequired {
            // Expected: the next generation can be rebuilt from preserved backups.
        }
        try store.withInteractiveAuthentication(context: LAContext()) {
            try store.migrateLegacyItemsToVault()
        }

        let freshStore = KeychainLicenseStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )
        try freshStore.prepareForBackgroundAccess()
        guard try freshStore.string(.installId) == "v2-backup-id" else {
            throw Failure("repair must recover a corrupt preferred vault from the newest valid backup")
        }
        let corruptKey = KeychainBackend.ItemKey(
            service: "com.creatigo.promptstudio.license.v3",
            account: "promptstudio.licenseVault"
        )
        let recoveredKey = KeychainBackend.ItemKey(
            service: "com.creatigo.promptstudio.license.v4",
            account: "promptstudio.licenseVault"
        )
        guard backend.items[corruptKey] == corruptV3, backend.items[recoveredKey] != nil else {
            throw Failure("repair must preserve corrupt v3 and create a verified v4 recovery slot")
        }
    }

    private static func corruptRecoveryDoesNotResurrectDeletedLegacyValues() throws {
        let backend = KeychainBackend()
        backend.seedLegacy(.activationId, value: Data("deleted-activation".utf8))
        backend.seedVault(
            Data(#"{"migrationVersion":1,"values":{"promptstudio.installId":"Y3VycmVudC1pZA=="}}"#.utf8),
            generation: 2
        )
        backend.seedVault(Data("corrupt-v3".utf8), generation: 3)
        let store = KeychainLicenseStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )

        try store.withInteractiveAuthentication(context: LAContext()) {
            try store.migrateLegacyItemsToVault()
        }

        let freshStore = KeychainLicenseStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )
        try freshStore.prepareForBackgroundAccess()
        guard try freshStore.string(.activationId) == nil else {
            throw Failure("a complete backup vault must not resurrect values deleted from legacy state")
        }
    }

    private static func corruptOnlyVaultDoesNotRestoreStaleActivation() throws {
        let backend = KeychainBackend()
        backend.seedVault(Data("corrupt-v2".utf8), generation: 2)
        backend.seedLegacy(.installId, value: Data("preserved-install".utf8))
        backend.seedLegacy(.activationId, value: Data("deactivated-id".utf8))
        backend.seedLegacy(.licenseCertificate, value: Data("stale-certificate".utf8))
        let store = KeychainLicenseStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )

        try store.withInteractiveAuthentication(context: LAContext()) {
            try store.migrateLegacyItemsToVault()
        }

        let freshStore = KeychainLicenseStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )
        try freshStore.prepareForBackgroundAccess()
        guard try freshStore.string(.installId) == "preserved-install" else {
            throw Failure("disaster recovery should preserve the local device identity")
        }
        guard try freshStore.string(.activationId) == nil,
              try freshStore.string(.licenseCertificate) == nil else {
            throw Failure("disaster recovery must not resurrect stale deactivated license values")
        }
    }

    private static func corruptPreferredVaultDoesNotRestoreActivationFromACompleteOlderVault() throws {
        let backend = KeychainBackend()
        backend.seedVault(
            Data(#"{"migrationVersion":1,"values":{"promptstudio.installId":"cHJlc2VydmVkLWluc3RhbGw=","promptstudio.activationId":"b2xkLWFjdGl2YXRpb24=","promptstudio.licenseCertificate":"b2xkLWNlcnRpZmljYXRl"}}"#.utf8),
            generation: 2
        )
        backend.seedVault(Data("corrupt-v3-after-deactivation".utf8), generation: 3)
        let store = KeychainLicenseStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )

        try store.withInteractiveAuthentication(context: LAContext()) {
            try store.migrateLegacyItemsToVault()
        }

        let freshStore = KeychainLicenseStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )
        try freshStore.prepareForBackgroundAccess()
        guard try freshStore.string(.installId) == "preserved-install" else {
            throw Failure("recovery should retain identity from the newest readable backup")
        }
        guard try freshStore.string(.activationId) == nil,
              try freshStore.string(.licenseCertificate) == nil else {
            throw Failure("a lower complete Vault may be a pre-deactivation snapshot and must not restore its license")
        }
    }

    private static func deviceIdentityDoesNotRewriteDerivedPublicKey() throws {
        let store = RecordingLicenseStore()
        store.values[KeychainLicenseStore.Key.installId.rawValue] = Data("install-id".utf8)
        store.values[KeychainLicenseStore.Key.devicePrivateKey.rawValue] =
            Curve25519.Signing.PrivateKey().rawRepresentation

        _ = try DeviceIdentityManager(store: store).loadOrCreateIdentity()

        guard !store.saves.contains(.devicePublicKey) else {
            throw Failure("device public key is derived and must not be rewritten on every launch")
        }
    }

    private static func trialStateReadsItsKeyOnce() throws {
        let store = RecordingLicenseStore()
        let formatter = ISO8601DateFormatter()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        store.values[KeychainLicenseStore.Key.trialStartedAt.rawValue] =
            Data(formatter.string(from: start).utf8)

        _ = try TrialManager(store: store).currentState(
            now: start.addingTimeInterval(24 * 60 * 60)
        )

        let reads = store.reads.filter { $0 == .trialStartedAt }
        guard reads.count == 1 else {
            throw Failure("trial state must read trialStartedAt once, got \(reads.count)")
        }
    }

    @MainActor
    private static func launchAccessFailureDoesNotCreateTrialOrIdentity() throws {
        let store = RecordingLicenseStore()
        store.legacyMigrationRequired = true

        let manager = LicenseManager(store: store)

        guard manager.state == .limited(reason: .keychainAccessRequired) else {
            throw Failure("launch access failure must surface a repairable limited state")
        }
        guard store.saves.isEmpty else {
            throw Failure("launch access failure must not create a trial or device identity")
        }
    }

    @MainActor
    private static func nonInteractiveKeychainFailuresAreNotReportedAsRepairable() throws {
        let store = RecordingLicenseStore()
        store.preparationError = .keychain("decode failed")

        let manager = LicenseManager(store: store)

        guard case .limited(.keychainUnavailable(let message)) = manager.state,
              message.contains("decode failed") else {
            throw Failure("non-authentication keychain failures must preserve their real error")
        }
        let decision = manager.featureGate.evaluate(.proEditPrompt)
        guard decision.reason == .keychainUnavailable,
              decision.primaryAction == .contactSupport else {
            throw Failure("a damaged keychain must not offer an authorization repair that cannot fix it")
        }
    }

    @MainActor
    private static func legacyIdentityAloneRequiresRepairAtLaunch() throws {
        let store = RecordingLicenseStore()
        store.legacyMigrationRequired = true
        store.values[KeychainLicenseStore.Key.installId.rawValue] = Data("old-install-id".utf8)
        store.values[KeychainLicenseStore.Key.devicePrivateKey.rawValue] =
            Curve25519.Signing.PrivateKey().rawRepresentation

        let manager = LicenseManager(store: store)

        guard manager.state == .limited(reason: .keychainAccessRequired) else {
            throw Failure("an old device identity must offer repair even without a license or trial record")
        }
        guard store.saves.isEmpty else {
            throw Failure("detecting an old device identity must not silently create a new trial")
        }
    }

    @MainActor
    private static func repairRunsOneInteractiveSessionAndReloadsState() throws {
        let store = RecordingLicenseStore()
        store.legacyMigrationRequired = true
        let formatter = ISO8601DateFormatter()
        store.values[KeychainLicenseStore.Key.trialStartedAt.rawValue] =
            Data(formatter.string(from: Date()).utf8)
        let manager = LicenseManager(store: store)

        try manager.repairKeychainAccess()

        guard store.interactiveRuns == 1 else {
            throw Failure("repair must use exactly one interactive authentication session")
        }
        guard store.legacyMigrations == 1 else {
            throw Failure("repair must persist the legacy values in the new vault")
        }
        guard store.backgroundReadsAfterMigration > 0 else {
            throw Failure("repair must verify the vault again with non-interactive background reads")
        }
        guard case .trialActive = manager.state else {
            throw Failure("repair must reload license state after authentication")
        }
    }

    private static func featureGateOffersKeychainRepair() throws {
        let decision = FeatureGate(
            state: .limited(reason: .keychainAccessRequired)
        ).evaluate(.proEditPrompt)

        guard decision.reason == .keychainAccessRequired,
              decision.primaryAction == .repairKeychainAccess else {
            throw Failure("keychain access failures must offer repair, not reactivation")
        }
    }

    @MainActor
    private static func serverRevocationPersistsUntilAValidReactivation() async throws {
        let store = RecordingLicenseStore()
        let devicePrivateKey = Curve25519.Signing.PrivateKey()
        let activationId = "activation-to-revoke"
        let now = Date()
        let signed = try makeSignedTestCertificate(
            activationId: activationId,
            devicePrivateKey: devicePrivateKey,
            now: now
        )
        store.values[KeychainLicenseStore.Key.installId.rawValue] = Data("install-id".utf8)
        store.values[KeychainLicenseStore.Key.devicePrivateKey.rawValue] =
            devicePrivateKey.rawRepresentation
        store.values[KeychainLicenseStore.Key.activationId.rawValue] = Data(activationId.utf8)
        store.values[KeychainLicenseStore.Key.licenseCertificate.rawValue] =
            Data(signed.certificate.utf8)

        let revokedMessage = "该授权已被服务端停用"
        let revokedAPI = LicenseAPIClient(
            refreshChallengeHandler: { _ in
                LicenseAPIClient.RefreshChallengeResponse(
                    ok: true,
                    challengeId: "challenge-id",
                    nonce: "nonce",
                    expiresAt: now.addingTimeInterval(300)
                )
            },
            refreshHandler: { _, _, _, _, _ in
                throw LicenseError.api(
                    code: "LICENSE_REVOKED",
                    message: revokedMessage,
                    data: nil
                )
            }
        )
        let manager = LicenseManager(
            store: store,
            verifier: signed.verifier,
            api: revokedAPI
        )
        guard case .proActive = manager.state else {
            throw Failure("test setup must begin with an active local certificate")
        }

        do {
            try await manager.forceRefresh()
            throw Failure("server revocation must fail the refresh request")
        } catch LicenseError.api(let code, _, _) where code == "LICENSE_REVOKED" {
            // Expected: the revocation must also be persisted locally.
        }
        guard try store.string(.licenseRevocation) == revokedMessage,
              try store.string(.activationId) == nil,
              try store.string(.licenseCertificate) == nil,
              manager.state == .revoked(reason: revokedMessage) else {
            throw Failure("server revocation must persist before local license data is cleared")
        }

        let offlineRelaunch = LicenseManager(store: store, verifier: signed.verifier)
        guard offlineRelaunch.state == .revoked(reason: revokedMessage) else {
            throw Failure("an offline relaunch must not restore Pro after server revocation")
        }

        let activationResponse = LicenseAPIClient.ActivateResponse(
            ok: true,
            activationId: activationId,
            licenseCertificate: signed.certificate,
            refreshAfter: now.addingTimeInterval(3_600),
            expiresAt: now.addingTimeInterval(86_400),
            graceUntil: now.addingTimeInterval(172_800),
            deviceCount: 1,
            seatLimit: 1,
            serverTime: now
        )
        let activationAPI = LicenseAPIClient(
            activateHandler: { _ in activationResponse }
        )
        let reactivated = LicenseManager(
            store: store,
            verifier: signed.verifier,
            api: activationAPI
        )
        try await reactivated.activate(email: "test@example.com", licenseCode: "TEST-CODE")
        guard try store.string(.licenseRevocation) == nil,
              case .proActive = reactivated.state else {
            throw Failure("only a successfully verified activation may clear persisted revocation")
        }
    }

    @MainActor
    private static func explicitDeactivationPersistsBeforeLocalCleanup() async throws {
        let store = RecordingLicenseStore()
        let devicePrivateKey = Curve25519.Signing.PrivateKey()
        let activationId = "activation-to-deactivate"
        let now = Date()
        let signed = try makeSignedTestCertificate(
            activationId: activationId,
            devicePrivateKey: devicePrivateKey,
            now: now
        )
        store.values[KeychainLicenseStore.Key.installId.rawValue] = Data("install-id".utf8)
        store.values[KeychainLicenseStore.Key.devicePrivateKey.rawValue] =
            devicePrivateKey.rawRepresentation
        store.values[KeychainLicenseStore.Key.activationId.rawValue] = Data(activationId.utf8)
        store.values[KeychainLicenseStore.Key.licenseCertificate.rawValue] =
            Data(signed.certificate.utf8)

        let api = LicenseAPIClient(
            refreshChallengeHandler: { _ in
                LicenseAPIClient.RefreshChallengeResponse(
                    ok: true,
                    challengeId: "deactivate-challenge",
                    nonce: "nonce",
                    expiresAt: now.addingTimeInterval(300)
                )
            },
            deactivateHandler: { _, _, _, _ in }
        )
        let manager = LicenseManager(store: store, verifier: signed.verifier, api: api)
        guard case .proActive = manager.state else {
            throw Failure("deactivation test must begin with an active certificate")
        }
        store.deleteFailureKey = .licenseCertificate

        do {
            try await manager.deactivateCurrentDevice()
            throw Failure("the injected local cleanup failure must propagate")
        } catch is RecordingStoreFailure {
            // Expected after the server has already confirmed deactivation.
        }

        guard let tombstone = try store.string(.licenseRevocation),
              manager.state == .revoked(reason: tombstone) else {
            throw Failure("deactivation must persist its tombstone before fallible local cleanup")
        }
        let offlineRelaunch = LicenseManager(store: store, verifier: signed.verifier)
        guard offlineRelaunch.state == .revoked(reason: tombstone) else {
            throw Failure("cleanup failure must not restore Pro on an offline relaunch")
        }
    }

    @MainActor
    private static func staleRevocationCannotDeleteANewerActivation() async throws {
        let store = RecordingLicenseStore()
        let devicePrivateKey = Curve25519.Signing.PrivateKey()
        let certificateSigningKey = Curve25519.Signing.PrivateKey()
        let now = Date()
        let activationA = "activation-a"
        let activationB = "activation-b"
        let signedA = try makeSignedTestCertificate(
            activationId: activationA,
            devicePrivateKey: devicePrivateKey,
            now: now,
            certificateSigningKey: certificateSigningKey
        )
        let signedB = try makeSignedTestCertificate(
            activationId: activationB,
            devicePrivateKey: devicePrivateKey,
            now: now,
            certificateSigningKey: certificateSigningKey
        )
        store.values[KeychainLicenseStore.Key.installId.rawValue] = Data("install-id".utf8)
        store.values[KeychainLicenseStore.Key.devicePrivateKey.rawValue] =
            devicePrivateKey.rawRepresentation
        store.values[KeychainLicenseStore.Key.activationId.rawValue] = Data(activationA.utf8)
        store.values[KeychainLicenseStore.Key.licenseCertificate.rawValue] =
            Data(signedA.certificate.utf8)

        let gate = AsyncOperationGate()
        let activationResponseB = LicenseAPIClient.ActivateResponse(
            ok: true,
            activationId: activationB,
            licenseCertificate: signedB.certificate,
            refreshAfter: now.addingTimeInterval(3_600),
            expiresAt: now.addingTimeInterval(86_400),
            graceUntil: now.addingTimeInterval(172_800),
            deviceCount: 1,
            seatLimit: 1,
            serverTime: now
        )
        let api = LicenseAPIClient(
            activateHandler: { _ in activationResponseB },
            refreshChallengeHandler: { _ in
                LicenseAPIClient.RefreshChallengeResponse(
                    ok: true,
                    challengeId: "slow-challenge",
                    nonce: "nonce",
                    expiresAt: now.addingTimeInterval(300)
                )
            },
            refreshHandler: { _, _, _, _, _ in
                await gate.arriveAndWait()
                throw LicenseError.api(
                    code: "LICENSE_REVOKED",
                    message: "stale revocation for A",
                    data: nil
                )
            }
        )
        let manager = LicenseManager(store: store, verifier: signedA.verifier, api: api)
        let staleRefresh = Task { try await manager.forceRefresh() }
        await gate.waitUntilStarted()

        try await manager.activate(email: "new@example.com", licenseCode: "NEW-CODE")
        await gate.release()
        do {
            try await staleRefresh.value
            throw Failure("the stale A refresh must still report its server error")
        } catch LicenseError.api(let code, _, _) where code == "LICENSE_REVOKED" {
            // Expected, but it must not mutate the newer B activation.
        }

        guard try store.string(.activationId) == activationB,
              try store.string(.licenseCertificate) == signedB.certificate,
              try store.string(.licenseRevocation) == nil,
              case .proActive(let certificate) = manager.state,
              certificate.activationId == activationB else {
            throw Failure("a stale A response must never revoke or overwrite activation B")
        }
    }

    @MainActor
    private static func confirmedDeactivationSurvivesANewerSameActivationMutation() async throws {
        let store = RecordingLicenseStore()
        let devicePrivateKey = Curve25519.Signing.PrivateKey()
        let activationId = "same-activation"
        let now = Date()
        let signed = try makeSignedTestCertificate(
            activationId: activationId,
            devicePrivateKey: devicePrivateKey,
            now: now
        )
        store.values[KeychainLicenseStore.Key.installId.rawValue] = Data("install-id".utf8)
        store.values[KeychainLicenseStore.Key.devicePrivateKey.rawValue] =
            devicePrivateKey.rawRepresentation
        store.values[KeychainLicenseStore.Key.activationId.rawValue] = Data(activationId.utf8)
        store.values[KeychainLicenseStore.Key.licenseCertificate.rawValue] =
            Data(signed.certificate.utf8)

        let gate = AsyncOperationGate()
        let api = LicenseAPIClient(
            refreshChallengeHandler: { _ in
                LicenseAPIClient.RefreshChallengeResponse(
                    ok: true,
                    challengeId: "same-activation-challenge",
                    nonce: "nonce",
                    expiresAt: now.addingTimeInterval(300)
                )
            },
            deactivateHandler: { _, _, _, _ in
                await gate.arriveAndWait()
            }
        )
        let manager = LicenseManager(store: store, verifier: signed.verifier, api: api)
        let deactivation = Task { try await manager.deactivateCurrentDevice() }
        await gate.waitUntilStarted()

        // A newer local state reload changes the request generation but not the
        // activation ownership. The server-confirmed deactivation must still win.
        manager.loadStateOnLaunch()
        await gate.release()
        try await deactivation.value

        guard let tombstone = try store.string(.licenseRevocation),
              manager.state == .revoked(reason: tombstone) else {
            throw Failure("a newer same-activation mutation must not discard confirmed deactivation")
        }
    }

    private static func makeSignedTestCertificate(
        activationId: String,
        devicePrivateKey: Curve25519.Signing.PrivateKey,
        now: Date,
        certificateSigningKey: Curve25519.Signing.PrivateKey = .init()
    ) throws -> (certificate: String, verifier: LicenseCertificateVerifier) {
        let keyId = "test-key"
        let bundleId = "com.creatigo.promptstudio"
        let header = LicenseCertificate.Header(
            typ: "PS-LICENSE-CERT",
            alg: "EdDSA",
            kid: keyId,
            v: 1
        )
        let payload = LicenseCertificate(
            iss: "promptstudio-license-server",
            aud: "promptstudio-macos",
            bundleId: bundleId,
            licenseId: "test-license",
            activationId: activationId,
            customerEmailHash: "test-email-hash",
            plan: "pro",
            licenseType: "perpetual",
            status: "active",
            seatLimit: 1,
            features: [FeatureKey.proEditPrompt.rawValue],
            majorVersion: 1,
            updatesUntil: nil,
            deviceKeyThumbprint: LicenseEncoding.sha256Base64URL(
                devicePrivateKey.publicKey.rawRepresentation
            ),
            issuedAt: now.addingTimeInterval(-60),
            refreshAfter: now.addingTimeInterval(3_600),
            expiresAt: now.addingTimeInterval(86_400),
            graceUntil: now.addingTimeInterval(172_800),
            serverTime: now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.ISO8601Format())
        }
        let headerPart = LicenseEncoding.base64URL(try encoder.encode(header))
        let payloadPart = LicenseEncoding.base64URL(try encoder.encode(payload))
        let signingInput = "\(headerPart).\(payloadPart)"
        let signature = try certificateSigningKey.signature(for: Data(signingInput.utf8))
        let certificate = "\(signingInput).\(LicenseEncoding.base64URL(signature))"
        let verifier = LicenseCertificateVerifier(
            publicKeys: [
                keyId: LicenseEncoding.base64URL(
                    certificateSigningKey.publicKey.rawRepresentation
                )
            ],
            bundleId: bundleId
        )
        return (certificate, verifier)
    }

    private static func onlyQuery(in recorder: CopyMatchingRecorder) throws -> [String: Any] {
        guard recorder.queries.count == 1, let query = recorder.queries.first else {
            throw Failure("expected exactly one keychain query")
        }
        return query
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
