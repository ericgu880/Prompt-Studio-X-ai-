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

private final class RecordingVaultLocator: LicenseVaultLocatorStore, @unchecked Sendable {
    var stored = LicenseVaultLocatorState.empty
    private(set) var saves: [LicenseVaultLocatorState] = []
    var failOnSaveNumber: Int?

    func load() throws -> LicenseVaultLocatorState {
        stored
    }

    func save(_ state: LicenseVaultLocatorState) throws {
        let saveNumber = saves.count + 1
        if failOnSaveNumber == saveNumber {
            failOnSaveNumber = nil
            throw RecordingStoreFailure(message: "injected locator failure")
        }
        stored = state
        saves.append(state)
    }
}

private struct DecodedLicenseVault: Codable, Equatable {
    let migrationVersion: Int?
    let values: [String: Data]
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
    enum OperationKind: Equatable {
        case copyAttributes
        case copyData
        case update
        case add
    }

    struct Operation: Equatable {
        let service: String
        let account: String?
        let kind: OperationKind
    }

    struct ItemKey: Hashable {
        let service: String
        let account: String
    }

    private(set) var items: [ItemKey: Data] = [:]
    private(set) var addedVaults = 0
    private(set) var legacyAttributeDiscoveries = 0
    private(set) var interactiveLegacyDataReads = 0
    private(set) var invalidBulkPasswordDataQueries = 0
    private(set) var operations: [Operation] = []
    private var backgroundRestrictedServices: Set<String> = []
    private var corruptedDataReadServices: Set<String> = []

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

    func corruptDataReads(service: String) {
        corruptedDataReadServices.insert(service)
    }

    func copyMatching(
        _ query: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        let attributes = query as NSDictionary
        let service = attributes[kSecAttrService as String] as? String ?? "<missing-service>"
        let account = attributes[kSecAttrAccount as String] as? String
        operations.append(
            Operation(
                service: service,
                account: account,
                kind: attributes[kSecReturnData as String] as? Bool == true
                    ? .copyData
                    : .copyAttributes
            )
        )
        if attributes[kSecReturnData as String] as? Bool == true,
           attributes[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String {
            invalidBulkPasswordDataQueries += 1
            return errSecParam
        }
        if attributes[kSecAttrService as String] as? String == "com.creatigo.promptstudio.license",
           attributes[kSecAttrAccount as String] == nil {
            let legacyItems = items.filter { $0.key.service == "com.creatigo.promptstudio.license" }
            guard !legacyItems.isEmpty else { return errSecItemNotFound }
            legacyAttributeDiscoveries += 1
            let payload: [[String: Any]] = legacyItems.map { entry in
                [
                    kSecAttrAccount as String: entry.key.account
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
        if key.service == "com.creatigo.promptstudio.license" {
            interactiveLegacyDataReads += 1
        }
        let returnedValue = corruptedDataReadServices.contains(key.service)
            ? Data("corrupted-vault-read".utf8)
            : value
        result?.pointee = returnedValue as CFData
        return errSecSuccess
    }

    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        let queryAttributes = query as NSDictionary
        operations.append(
            Operation(
                service: queryAttributes[kSecAttrService as String] as? String ?? "<missing-service>",
                account: queryAttributes[kSecAttrAccount as String] as? String,
                kind: .update
            )
        )
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
        operations.append(
            Operation(
                service: dictionary[kSecAttrService as String] as? String ?? "<missing-service>",
                account: dictionary[kSecAttrAccount as String] as? String,
                kind: .add
            )
        )
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
    var freshVaultCreationFailure: RecordingStoreFailure?
    var deleteFailureKey: KeychainLicenseStore.Key?
    private(set) var reads: [KeychainLicenseStore.Key] = []
    private(set) var saves: [KeychainLicenseStore.Key] = []
    private(set) var interactiveRuns = 0
    private(set) var legacyMigrations = 0
    private(set) var freshVaultCreationDates: [Date] = []
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
        if values[KeychainLicenseStore.Key.licenseRecoveryMarker.rawValue] == nil {
            let hasTrustedTrialStart: Bool
            if let data = values[KeychainLicenseStore.Key.trialStartedAt.rawValue],
               let raw = String(data: data, encoding: .utf8) {
                hasTrustedTrialStart = ISO8601DateFormatter().date(from: raw) != nil
            } else {
                hasTrustedTrialStart = false
            }
            let marker = LicenseRecoveryMarker(
                version: 1,
                mode: .migratedExisting,
                createdAt: Date(),
                blocksTrialBootstrap: !hasTrustedTrialStart
            )
            values[KeychainLicenseStore.Key.licenseRecoveryMarker.rawValue] =
                try JSONEncoder().encode(marker)
        }
    }

    func createFreshVaultForReactivation(now: Date) throws {
        if let freshVaultCreationFailure {
            throw freshVaultCreationFailure
        }
        freshVaultCreationDates.append(now)
        let marker = LicenseRecoveryMarker(
            version: 1,
            mode: .newIdentity,
            createdAt: now,
            blocksTrialBootstrap: true
        )
        values = [
            KeychainLicenseStore.Key.licenseRecoveryMarker.rawValue:
                try JSONEncoder().encode(marker)
        ]
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

private func makeKeychainStore(
    copyMatching: @escaping KeychainLicenseStore.CopyMatching = SecItemCopyMatching,
    update: @escaping KeychainLicenseStore.Update = SecItemUpdate,
    add: @escaping KeychainLicenseStore.Add = SecItemAdd,
    locator: any LicenseVaultLocatorStore = RecordingVaultLocator(),
    makeUUID: @escaping () -> UUID = UUID.init
) -> KeychainLicenseStore {
    KeychainLicenseStore(
        copyMatching: copyMatching,
        update: update,
        add: add,
        locator: locator,
        makeUUID: makeUUID
    )
}

@main
private enum LicenseKeychainRegressionTests {
    @MainActor
    static func main() async throws {
        try recoveryDomainModelsHaveStableRepresentations()
        try vaultLocatorRoundTripsActiveAndPending()
        try vaultLocatorStateCanPromotePendingReference()
        try vaultLocatorPersistsWholeStateUnderOneDataKey()
        try emptyVaultLocatorDefaultsLoadEmpty()
        try malformedVaultLocatorDataFailsClosed()
        try freshRecoveryCreatesOnlyOneRandomVaultWithoutLegacyAccess()
        try pendingLocatorFailurePreventsAnyKeychainMutation()
        try failedFreshRecoveryDoesNotPublishAnActiveLocator()
        try pendingRecoveryWithoutAVaultFailsClosed()
        try failedFreshVaultVerificationPreservesLegacyState()
        try activeRandomVaultIsTheOnlyServiceReadAfterRestart()
        try missingActiveRandomVaultFailsClosedWithoutLegacyFallback()
        try backgroundReadsNeverPresentAuthenticationUI()
        try interactionRequiredHasAFirstClassError()
        try recoverableSecurityStatusesAreClassified()
        try interactiveReadsReuseOneAuthenticationContext()
        try legacyDiscoveryAvoidsUnsupportedBulkPasswordData()
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
        try freshRecoveryRequiresReactivationWithoutStartingTrial()
        try launchWithRecoveryMarkerNeverRestartsTrial()
        try failedFreshRecoveryKeepsTheChoiceState()
        try nonInteractiveKeychainFailuresAreNotReportedAsRepairable()
        try legacyIdentityAloneRequiresRepairAtLaunch()
        try repairRunsOneInteractiveSessionAndReloadsState()
        try preservationRecoveryWithoutTrialDoesNotIssueANewTrial()
        try featureGateOffersKeychainRepair()
        try inactiveLicenseIsPreviewOnly()
        try await activationFailureKeepsRecoveryBlocked()
        try await successfulActivationCompletesRecovery()
        try releaseRuntimeConfigurationFailsClosed()
        try lifetimeLicensePresentationBuildsTrust()
        try await serverRevocationPersistsUntilAValidReactivation()
        try await explicitDeactivationPersistsBeforeLocalCleanup()
        try await staleRevocationCannotDeleteANewerActivation()
        try await confirmedDeactivationSurvivesANewerSameActivationMutation()
        print("License keychain regression tests passed")
    }

    private static func recoveryDomainModelsHaveStableRepresentations() throws {
        guard LicenseRecoveryOption.preserveAndMigrate.rawValue == "preserveAndMigrate",
              LicenseRecoveryOption.newIdentityAndReactivate.rawValue == "newIdentityAndReactivate" else {
            throw Failure("license recovery options must keep their persisted raw values")
        }

        let createdAt = Date(timeIntervalSince1970: 1_752_624_000)
        let marker = LicenseRecoveryMarker(
            version: 1,
            mode: .migratedExisting,
            createdAt: createdAt,
            blocksTrialBootstrap: true
        )
        let encodedMarker = try JSONEncoder().encode(marker)
        guard try JSONDecoder().decode(LicenseRecoveryMarker.self, from: encodedMarker) == marker else {
            throw Failure("license recovery markers must round-trip without losing bootstrap policy")
        }

        let phases: [LicenseRecoveryPhase] = [
            .notRequired,
            .choiceRequired,
            .working(.preserveAndMigrate),
            .reactivationRequired,
            .completed,
            .failed(option: .newIdentityAndReactivate, message: "reactivation failed")
        ]
        guard phases[2] == .working(.preserveAndMigrate),
              phases[5] == .failed(
                  option: .newIdentityAndReactivate,
                  message: "reactivation failed"
              ) else {
            throw Failure("license recovery phases must preserve their associated recovery context")
        }
    }

    private static func vaultLocatorRoundTripsActiveAndPending() throws {
        try withIsolatedUserDefaults { defaults, _ in
            let expected = LicenseVaultLocatorState(
                active: LicenseVaultReference(
                    id: UUID(uuidString: "6A7B2E99-7D28-4E58-A056-D75C734EC971")!,
                    service: "com.creatigo.promptstudio.license.v2",
                    account: "promptstudio.licenseVault"
                ),
                pending: LicenseVaultReference(
                    id: UUID(uuidString: "133D6CDA-5291-4598-B6A8-5DE4904A7796")!,
                    service: "com.creatigo.promptstudio.license.v3",
                    account: "promptstudio.pendingLicenseVault"
                )
            )
            let store = UserDefaultsLicenseVaultLocator(defaults: defaults)

            try store.save(expected)

            guard try store.load() == expected else {
                throw Failure("vault locator must round-trip active and pending references together")
            }
        }
    }

    private static func vaultLocatorPersistsWholeStateUnderOneDataKey() throws {
        try withIsolatedUserDefaults { defaults, suiteName in
            let store = UserDefaultsLicenseVaultLocator(defaults: defaults)
            try store.save(
                LicenseVaultLocatorState(
                    active: LicenseVaultReference(
                        id: UUID(),
                        service: "com.creatigo.promptstudio.license.v2",
                        account: "promptstudio.licenseVault"
                    ),
                    pending: nil
                )
            )
            let replacement = LicenseVaultLocatorState(
                active: LicenseVaultReference(
                    id: UUID(),
                    service: "com.creatigo.promptstudio.license.v3",
                    account: "promptstudio.licenseVault"
                ),
                pending: LicenseVaultReference(
                    id: UUID(),
                    service: "com.creatigo.promptstudio.license.v4",
                    account: "promptstudio.pendingLicenseVault"
                )
            )

            try store.save(replacement)

            let key = "PromptStudioLicenseVaultLocatorState.v1"
            let persistedDomain = defaults.persistentDomain(forName: suiteName) ?? [:]
            guard persistedDomain.count == 1,
                  let encodedState = persistedDomain[key] as? Data,
                  try JSONDecoder().decode(LicenseVaultLocatorState.self, from: encodedState) == replacement else {
                throw Failure("vault locator updates must replace one complete encoded state under one key")
            }
        }
    }

    private static func vaultLocatorStateCanPromotePendingReference() throws {
        let pending = LicenseVaultReference(
            id: UUID(),
            service: "com.creatigo.promptstudio.license.v3",
            account: "promptstudio.pendingLicenseVault"
        )
        var state = LicenseVaultLocatorState(active: nil, pending: pending)

        state.active = state.pending
        state.pending = nil

        guard state.active == pending, state.pending == nil else {
            throw Failure("vault locator state must support promoting pending to active")
        }
    }

    private static func emptyVaultLocatorDefaultsLoadEmpty() throws {
        try withIsolatedUserDefaults { defaults, _ in
            let store = UserDefaultsLicenseVaultLocator(defaults: defaults)

            guard try store.load() == .empty else {
                throw Failure("an uninitialized vault locator must load an empty state")
            }
        }
    }

    private static func malformedVaultLocatorDataFailsClosed() throws {
        try withIsolatedUserDefaults { defaults, _ in
            defaults.set(
                Data("not valid locator JSON".utf8),
                forKey: "PromptStudioLicenseVaultLocatorState.v1"
            )
            let store = UserDefaultsLicenseVaultLocator(defaults: defaults)
            var didThrow = false

            do {
                _ = try store.load()
            } catch {
                didThrow = true
            }

            guard didThrow else {
                throw Failure("malformed vault locator data must fail closed instead of loading empty")
            }
        }
    }

    private static func withIsolatedUserDefaults(
        _ operation: (UserDefaults, String) throws -> Void
    ) throws {
        let suiteName = "LicenseKeychainRegressionTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw Failure("could not create isolated user defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try operation(defaults, suiteName)
    }

    private static func freshRecoveryCreatesOnlyOneRandomVaultWithoutLegacyAccess() throws {
        let backend = KeychainBackend()
        backend.seedLegacy(.activationId, value: Data("legacy-activation".utf8))
        backend.seedLegacy(.trialStartedAt, value: Data("2026-01-01T00:00:00Z".utf8))
        backend.seedVault(
            Data(#"{"migrationVersion":1,"values":{"promptstudio.installId":"b2xkLXZhdWx0"}}"#.utf8),
            generation: 7
        )
        let oldItems = backend.items
        let locator = RecordingVaultLocator()
        let fixedID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let expectedService = "com.creatigo.promptstudio.license.vault.\(fixedID.uuidString.lowercased())"
        let fixedDate = Date(timeIntervalSince1970: 1_752_624_000)
        let store = makeKeychainStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add,
            locator: locator,
            makeUUID: { fixedID }
        )
        let before = backend.operations.count

        try store.createFreshVaultForReactivation(now: fixedDate)

        let delta = Array(backend.operations.dropFirst(before))
        let forbiddenLegacyServices = Set(
            ["com.creatigo.promptstudio.license"]
                + (2...16).map { "com.creatigo.promptstudio.license.v\($0)" }
        )
        guard delta.map(\.kind) == [.add, .copyData],
              delta.allSatisfy({ $0.service == expectedService }),
              delta.allSatisfy({ !forbiddenLegacyServices.contains($0.service) }) else {
            throw Failure("B recovery may only add and verify its random Vault")
        }
        for (key, value) in oldItems {
            guard backend.items[key] == value else {
                throw Failure("B recovery must preserve every legacy License item byte-for-byte")
            }
        }

        let reference = LicenseVaultReference(
            id: fixedID,
            service: expectedService,
            account: "promptstudio.licenseVault"
        )
        guard locator.stored == LicenseVaultLocatorState(active: reference, pending: nil),
              locator.saves == [
                  LicenseVaultLocatorState(active: nil, pending: reference),
                  LicenseVaultLocatorState(active: reference, pending: nil)
              ] else {
            throw Failure("B recovery must publish pending before atomically promoting the random Vault")
        }
        let vaultKey = KeychainBackend.ItemKey(
            service: expectedService,
            account: "promptstudio.licenseVault"
        )
        guard let encodedVault = backend.items[vaultKey],
              let vault = try? JSONDecoder().decode(DecodedLicenseVault.self, from: encodedVault),
              vault.migrationVersion == 1,
              vault.values.count == 1,
              let markerData = vault.values["promptstudio.licenseRecoveryMarker"],
              let marker = try? JSONDecoder().decode(LicenseRecoveryMarker.self, from: markerData),
              marker == LicenseRecoveryMarker(
                  version: 1,
                  mode: .newIdentity,
                  createdAt: fixedDate,
                  blocksTrialBootstrap: true
              ),
              vault.values["promptstudio.trialStartedAt"] == nil else {
            throw Failure("a fresh B Vault must contain only the permanent Trial-blocking recovery marker")
        }
    }

    private static func failedFreshRecoveryDoesNotPublishAnActiveLocator() throws {
        let backend = KeychainBackend()
        backend.seedLegacy(.installId, value: Data("preserved-install".utf8))
        let originalItems = backend.items
        let locator = RecordingVaultLocator()
        locator.failOnSaveNumber = 2
        let fixedID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let store = makeKeychainStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add,
            locator: locator,
            makeUUID: { fixedID }
        )

        do {
            try store.createFreshVaultForReactivation(now: Date(timeIntervalSince1970: 1_752_624_000))
            throw Failure("injected locator commit failure must abort B recovery")
        } catch is RecordingStoreFailure {
            // Expected: the uncommitted random Vault may remain orphaned, but never becomes active.
        }

        guard locator.stored.active == nil,
              locator.stored.pending?.id == fixedID else {
            throw Failure("failed recovery must not publish an active Vault")
        }
        for (key, value) in originalItems {
            guard backend.items[key] == value else {
                throw Failure("locator failure must not change preserved legacy records")
            }
        }

        let beforeRestart = backend.operations.count
        let restartedStore = makeKeychainStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add,
            locator: locator
        )
        try restartedStore.prepareForBackgroundAccess()
        let restartOperations = Array(backend.operations.dropFirst(beforeRestart))
        guard locator.stored.active?.id == fixedID,
              locator.stored.pending == nil,
              restartOperations.count == 1,
              restartOperations[0].service == locator.stored.active?.service else {
            throw Failure("restart must verify and finish a pending random Vault without legacy fallback")
        }
    }

    private static func pendingLocatorFailurePreventsAnyKeychainMutation() throws {
        let backend = KeychainBackend()
        backend.seedLegacy(.installId, value: Data("preserved-install".utf8))
        let originalItems = backend.items
        let locator = RecordingVaultLocator()
        locator.failOnSaveNumber = 1
        let fixedID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let store = makeKeychainStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add,
            locator: locator,
            makeUUID: { fixedID }
        )

        do {
            try store.createFreshVaultForReactivation(
                now: Date(timeIntervalSince1970: 1_752_624_000)
            )
            throw Failure("pending locator failure must abort before adding a random Vault")
        } catch is RecordingStoreFailure {
            // Expected: no Keychain operation is allowed before pending is durable.
        }

        guard locator.stored == .empty,
              locator.saves.isEmpty,
              backend.operations.isEmpty,
              backend.items == originalItems else {
            throw Failure("pending locator failure must leave Keychain and locator state untouched")
        }
    }

    private static func pendingRecoveryWithoutAVaultFailsClosed() throws {
        let backend = KeychainBackend()
        backend.seedLegacy(.trialStartedAt, value: Data("2026-01-01T00:00:00Z".utf8))
        backend.seedVault(Data(#"{"migrationVersion":1,"values":{}}"#.utf8), generation: 4)
        let fixedID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let reference = LicenseVaultReference(
            id: fixedID,
            service: "com.creatigo.promptstudio.license.vault.\(fixedID.uuidString.lowercased())",
            account: "promptstudio.licenseVault"
        )
        let locator = RecordingVaultLocator()
        locator.stored = LicenseVaultLocatorState(active: nil, pending: reference)
        let store = makeKeychainStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add,
            locator: locator
        )
        let before = backend.operations.count

        do {
            _ = try store.data(.licenseRecoveryMarker)
            throw Failure("an interrupted recovery without a Vault must remain fail-closed")
        } catch LicenseError.keychainVaultCorrupted {
            // Expected: the pending proof remains so Trial cannot bootstrap on restart.
        }

        let delta = Array(backend.operations.dropFirst(before))
        guard locator.stored == LicenseVaultLocatorState(active: nil, pending: reference),
              delta.count == 1,
              delta[0].service == reference.service else {
            throw Failure("an incomplete pending recovery must not be cleared or fall back to old services")
        }
    }

    private static func failedFreshVaultVerificationPreservesLegacyState() throws {
        let backend = KeychainBackend()
        backend.seedLegacy(.licenseCertificate, value: Data("old-certificate".utf8))
        let originalItems = backend.items
        let locator = RecordingVaultLocator()
        let fixedID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let service = "com.creatigo.promptstudio.license.vault.\(fixedID.uuidString.lowercased())"
        backend.corruptDataReads(service: service)
        let store = makeKeychainStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add,
            locator: locator,
            makeUUID: { fixedID }
        )

        do {
            try store.createFreshVaultForReactivation(now: Date(timeIntervalSince1970: 1_752_624_000))
            throw Failure("a random Vault that cannot be verified must not become active")
        } catch LicenseError.keychainVaultCorrupted {
            // Expected: verification is fail-closed.
        }

        guard locator.stored.active == nil,
              locator.stored.pending?.id == fixedID else {
            throw Failure("failed Vault verification must leave only the pending locator")
        }
        for (key, value) in originalItems {
            guard backend.items[key] == value else {
                throw Failure("verification failure must preserve every old License item")
            }
        }
    }

    private static func activeRandomVaultIsTheOnlyServiceReadAfterRestart() throws {
        let backend = KeychainBackend()
        backend.seedLegacy(.installId, value: Data("legacy-install".utf8))
        backend.seedVault(Data(#"{"migrationVersion":1,"values":{}}"#.utf8), generation: 12)
        let locator = RecordingVaultLocator()
        let fixedID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let service = "com.creatigo.promptstudio.license.vault.\(fixedID.uuidString.lowercased())"
        let firstStore = makeKeychainStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add,
            locator: locator,
            makeUUID: { fixedID }
        )
        try firstStore.createFreshVaultForReactivation(now: Date(timeIntervalSince1970: 1_752_624_000))

        let before = backend.operations.count
        let restartedStore = makeKeychainStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add,
            locator: locator
        )
        try restartedStore.prepareForBackgroundAccess()
        guard try restartedStore.data(.licenseRecoveryMarker) != nil else {
            throw Failure("the recovery marker must survive a new store instance")
        }
        let delta = Array(backend.operations.dropFirst(before))
        guard !delta.isEmpty,
              delta.allSatisfy({ $0.service == service && $0.kind == .copyData }) else {
            throw Failure("an active locator must prevent every legacy and generation scan after restart")
        }
    }

    private static func missingActiveRandomVaultFailsClosedWithoutLegacyFallback() throws {
        let backend = KeychainBackend()
        backend.seedLegacy(.trialStartedAt, value: Data("2026-01-01T00:00:00Z".utf8))
        backend.seedVault(Data(#"{"migrationVersion":1,"values":{}}"#.utf8), generation: 16)
        let fixedID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let reference = LicenseVaultReference(
            id: fixedID,
            service: "com.creatigo.promptstudio.license.vault.\(fixedID.uuidString.lowercased())",
            account: "promptstudio.licenseVault"
        )
        let locator = RecordingVaultLocator()
        locator.stored = LicenseVaultLocatorState(active: reference, pending: nil)
        let store = makeKeychainStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add,
            locator: locator
        )
        let before = backend.operations.count

        do {
            _ = try store.data(.licenseRecoveryMarker)
            throw Failure("a missing active random Vault must fail closed")
        } catch LicenseError.keychainVaultCorrupted {
            // Expected: never fall back to legacy generations.
        }

        let delta = Array(backend.operations.dropFirst(before))
        guard delta.count == 1,
              delta[0].service == reference.service,
              delta[0].kind == .copyData else {
            throw Failure("missing active locator targets must not scan any old License service")
        }
    }

    private static func releaseRuntimeConfigurationFailsClosed() throws {
        let resolved = LicenseRuntimeConfiguration.resolvedServerURL(
            allowsRuntimeOverrides: false,
            environment: ["PROMPTSTUDIO_LICENSE_SERVER_URL": "https://attacker.example"],
            userDefaultsValue: "https://another-attacker.example"
        )
        guard resolved.absoluteString == "https://license.promptstudio.app" else {
            throw Failure("release builds must ignore runtime license-server overrides")
        }
        guard LicenseRuntimeConfiguration.purchaseURL(rawValue: nil) == nil,
              LicenseRuntimeConfiguration.purchaseURL(rawValue: "http://checkout.example") == nil,
              LicenseRuntimeConfiguration.purchaseURL(rawValue: "https://checkout.example")?.absoluteString == "https://checkout.example" else {
            throw Failure("purchase links must be explicitly configured with HTTPS")
        }
        guard !AppRuntimePolicy.includesDemoLibraryContent else {
            throw Failure("release builds must not write demo content into an empty user library")
        }
    }

    private static func lifetimeLicensePresentationBuildsTrust() throws {
        guard LicensePresentation.planName(plan: "pro_lifetime", licenseType: "lifetime") == "PromptStudio Pro 永久授权",
              LicensePresentation.planName(plan: "team", licenseType: "subscription") == "PromptStudio Pro 订阅" else {
            throw Failure("license plans must use customer-facing names instead of raw identifiers")
        }
    }

    private static func backgroundReadsNeverPresentAuthenticationUI() throws {
        let recorder = CopyMatchingRecorder()
        let store = makeKeychainStore(copyMatching: recorder.call)

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
        let store = makeKeychainStore(copyMatching: recorder.call)

        do {
            _ = try store.data(.licenseCertificate)
            throw Failure("interaction-not-allowed must not be treated as missing data")
        } catch LicenseError.keychainAccessRequired {
            // Expected: LicenseManager can show one explicit repair action.
        }
    }

    private static func recoverableSecurityStatusesAreClassified() throws {
        for status in [errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed] {
            let recorder = CopyMatchingRecorder()
            recorder.status = status
            let store = makeKeychainStore(copyMatching: recorder.call)

            do {
                _ = try store.data(.licenseCertificate)
                throw Failure("background Security status \(status) must require explicit recovery")
            } catch LicenseError.keychainAccessRequired {
                // Expected: these statuses are recoverable only through a user action.
            }
        }

        let interactiveRecorder = CopyMatchingRecorder()
        interactiveRecorder.status = errSecAuthFailed
        let interactiveStore = makeKeychainStore(copyMatching: interactiveRecorder.call)
        do {
            try interactiveStore.withInteractiveAuthentication(context: LAContext()) {
                _ = try interactiveStore.data(.licenseCertificate)
            }
            throw Failure("interactive authentication failure must surface the actual Security error")
        } catch LicenseError.keychain(let message) {
            guard message.contains("OSStatus \(errSecAuthFailed)"),
                  message != errSecAuthFailed.description else {
                throw Failure("interactive Security errors must include a readable message and OSStatus")
            }
        }

        let parameterRecorder = CopyMatchingRecorder()
        parameterRecorder.status = errSecParam
        let parameterStore = makeKeychainStore(copyMatching: parameterRecorder.call)
        do {
            _ = try parameterStore.data(.licenseCertificate)
            throw Failure("non-recoverable Security failures must not be swallowed")
        } catch LicenseError.keychain(let message) {
            guard message.contains("OSStatus \(errSecParam)"),
                  message != errSecParam.description else {
                throw Failure("Security failures must expose a readable message and numeric status")
            }
        }
    }

    private static func interactiveReadsReuseOneAuthenticationContext() throws {
        let recorder = CopyMatchingRecorder()
        let store = makeKeychainStore(copyMatching: recorder.call)
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

    private static func legacyDiscoveryAvoidsUnsupportedBulkPasswordData() throws {
        let backend = KeychainBackend()
        backend.seedLegacy(.installId, value: Data("legacy-install-id".utf8))
        let store = makeKeychainStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )

        do {
            try store.prepareForBackgroundAccess()
            throw Failure("discovered legacy records must require an explicit recovery choice")
        } catch LicenseError.keychainAccessRequired {
            // Expected: name discovery is safe, while secret data remains unread.
        }

        guard backend.invalidBulkPasswordDataQueries == 0 else {
            throw Failure("generic-password discovery cannot combine kSecReturnData with kSecMatchLimitAll")
        }
        guard backend.legacyAttributeDiscoveries == 1,
              backend.interactiveLegacyDataReads == 0 else {
            throw Failure("background startup must discover legacy account names without reading secrets")
        }
    }

    private static func legacyMigrationSurvivesANewBackgroundStore() throws {
        let backend = KeychainBackend()
        let startedAt = "2026-07-16T00:00:00Z"
        backend.seedLegacy(.trialStartedAt, value: Data(startedAt.utf8))
        backend.seedLegacy(.installId, value: Data("old-install-id".utf8))
        let store = makeKeychainStore(
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

        let freshStore = makeKeychainStore(
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
        guard backend.legacyAttributeDiscoveries == 1,
              backend.interactiveLegacyDataReads == 2 else {
            throw Failure("legacy records must be discovered once and then read account by account")
        }
        guard backend.items.keys.filter({ $0.service == "com.creatigo.promptstudio.license" }).count == 2 else {
            throw Failure("legacy records must be preserved after migration")
        }
    }

    private static func aSingleLegacyRecordCanBeMigrated() throws {
        let backend = KeychainBackend()
        backend.seedLegacy(.trialStartedAt, value: Data("2026-07-16T00:00:00Z".utf8))
        let store = makeKeychainStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )

        try store.withInteractiveAuthentication(context: LAContext()) {
            try store.migrateLegacyItemsToVault()
        }

        let freshStore = makeKeychainStore(
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
        let store = makeKeychainStore(
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

        let freshStore = makeKeychainStore(
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
        let store = makeKeychainStore(
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

        let freshStore = makeKeychainStore(
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
        let store = makeKeychainStore(
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

        let freshStore = makeKeychainStore(
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
        let store = makeKeychainStore(
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

        let freshStore = makeKeychainStore(
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
        let store = makeKeychainStore(
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

        let freshStore = makeKeychainStore(
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
        let store = makeKeychainStore(
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

        let freshStore = makeKeychainStore(
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
        let store = makeKeychainStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )

        try store.withInteractiveAuthentication(context: LAContext()) {
            try store.migrateLegacyItemsToVault()
        }

        let freshStore = makeKeychainStore(
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
        let store = makeKeychainStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )

        try store.withInteractiveAuthentication(context: LAContext()) {
            try store.migrateLegacyItemsToVault()
        }

        let freshStore = makeKeychainStore(
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
        let store = makeKeychainStore(
            copyMatching: backend.copyMatching,
            update: backend.update,
            add: backend.add
        )

        try store.withInteractiveAuthentication(context: LAContext()) {
            try store.migrateLegacyItemsToVault()
        }

        let freshStore = makeKeychainStore(
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
        guard manager.recoveryPhase == .choiceRequired else {
            throw Failure("launch access failure must expose the explicit recovery choice")
        }
        guard store.saves.isEmpty else {
            throw Failure("launch access failure must not create a trial or device identity")
        }
    }

    @MainActor
    private static func freshRecoveryRequiresReactivationWithoutStartingTrial() throws {
        let store = RecordingLicenseStore()
        store.legacyMigrationRequired = true
        let manager = LicenseManager(store: store)

        try manager.recoverLicense(using: .newIdentityAndReactivate)

        guard manager.state == .limited(
            reason: .reactivationRequiredAfterKeychainRecovery
        ), manager.recoveryPhase == .reactivationRequired else {
            throw Failure("B recovery must enter a persistent reactivation-required state")
        }
        guard store.freshVaultCreationDates.count == 1,
              store.interactiveRuns == 0,
              store.legacyMigrations == 0,
              store.values[KeychainLicenseStore.Key.trialStartedAt.rawValue] == nil,
              store.values[KeychainLicenseStore.Key.licenseRecoveryMarker.rawValue] != nil else {
            throw Failure("B recovery must create only a recovery marker without Trial or legacy access")
        }
        let decision = manager.featureGate.evaluate(.proEditPrompt)
        guard decision.primaryAction == .activate,
              decision.message?.contains("原激活和试用未复制") == true else {
            throw Failure("recovered identities must route Pro features to reactivation")
        }
    }

    @MainActor
    private static func launchWithRecoveryMarkerNeverRestartsTrial() throws {
        let store = RecordingLicenseStore()
        let marker = LicenseRecoveryMarker(
            version: 1,
            mode: .newIdentity,
            createdAt: Date(timeIntervalSince1970: 1_752_624_000),
            blocksTrialBootstrap: true
        )
        store.values[KeychainLicenseStore.Key.licenseRecoveryMarker.rawValue] =
            try JSONEncoder().encode(marker)

        let manager = LicenseManager(store: store)

        guard manager.state == .limited(
            reason: .reactivationRequiredAfterKeychainRecovery
        ), manager.recoveryPhase == .reactivationRequired else {
            throw Failure("a recovery marker must remain blocked after relaunch")
        }
        guard !store.saves.contains(.trialStartedAt),
              store.values[KeychainLicenseStore.Key.trialStartedAt.rawValue] == nil else {
            throw Failure("a recovery marker must prevent Trial bootstrap on every relaunch")
        }
    }

    @MainActor
    private static func failedFreshRecoveryKeepsTheChoiceState() throws {
        let store = RecordingLicenseStore()
        store.legacyMigrationRequired = true
        store.freshVaultCreationFailure = RecordingStoreFailure(
            message: "injected fresh Vault failure"
        )
        let manager = LicenseManager(store: store)

        do {
            try manager.recoverLicense(using: .newIdentityAndReactivate)
            throw Failure("fresh Vault errors must propagate")
        } catch is RecordingStoreFailure {
            // Expected: the user can explicitly retry either recovery option.
        }

        guard case .failed(
            option: .newIdentityAndReactivate,
            message: let message
        ) = manager.recoveryPhase,
              message.contains("injected fresh Vault failure"),
              manager.state == .limited(reason: .keychainAccessRequired),
              store.interactiveRuns == 0 else {
            throw Failure("failed B recovery must remain non-interactive and preserve the prior limited state")
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

        try manager.recoverLicense(using: .preserveAndMigrate)

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
        guard manager.recoveryPhase == .completed else {
            throw Failure("successful preservation recovery must complete its state machine")
        }
    }

    @MainActor
    private static func preservationRecoveryWithoutTrialDoesNotIssueANewTrial() throws {
        let store = RecordingLicenseStore()
        store.legacyMigrationRequired = true
        store.values[KeychainLicenseStore.Key.installId.rawValue] =
            Data("preserved-install-id".utf8)
        let manager = LicenseManager(store: store)

        try manager.recoverLicense(using: .preserveAndMigrate)

        guard manager.state == .limited(
            reason: .reactivationRequiredAfterKeychainRecovery
        ), manager.recoveryPhase == .reactivationRequired,
              !store.saves.contains(.trialStartedAt),
              let markerData = store.values[
                  KeychainLicenseStore.Key.licenseRecoveryMarker.rawValue
              ],
              let marker = try? JSONDecoder().decode(
                  LicenseRecoveryMarker.self,
                  from: markerData
              ),
              marker.mode == .migratedExisting,
              marker.blocksTrialBootstrap else {
            throw Failure("preservation recovery without a trusted Trial date must require reactivation")
        }
    }

    private static func featureGateOffersKeychainRepair() throws {
        let decision = FeatureGate(
            state: .limited(reason: .keychainAccessRequired)
        ).evaluate(.proEditPrompt)

        guard decision.reason == .keychainAccessRequired,
              decision.primaryAction == .chooseKeychainRecovery else {
            throw Failure("keychain access failures must open the recovery choice without touching secrets")
        }
    }

    private static func inactiveLicenseIsPreviewOnly() throws {
        let gate = FeatureGate(state: .limited(reason: .noLicense))
        guard gate.evaluate(.baseOpenLibrary).allowed,
              gate.evaluate(.baseViewPrompt).allowed,
              gate.evaluate(.baseBasicSearch).allowed,
              gate.evaluate(.baseLicenseSettings).allowed,
              !gate.evaluate(.baseCopyPrompt).allowed,
              !gate.evaluate(.baseBasicExport).allowed,
              !gate.evaluate(.baseDeleteLocalData).allowed,
              !gate.evaluate(.proCreatePrompt).allowed,
              !gate.evaluate(.proEditPrompt).allowed,
              !gate.evaluate(.proSingleImport).allowed else {
            throw Failure("an inactive license must allow preview/navigation only")
        }
    }

    @MainActor
    private static func activationFailureKeepsRecoveryBlocked() async throws {
        let store = RecordingLicenseStore()
        let devicePrivateKey = Curve25519.Signing.PrivateKey()
        let marker = LicenseRecoveryMarker(
            version: 1,
            mode: .newIdentity,
            createdAt: Date(),
            blocksTrialBootstrap: true
        )
        store.values[KeychainLicenseStore.Key.licenseRecoveryMarker.rawValue] =
            try JSONEncoder().encode(marker)
        store.values[KeychainLicenseStore.Key.installId.rawValue] = Data("install-id".utf8)
        store.values[KeychainLicenseStore.Key.devicePrivateKey.rawValue] =
            devicePrivateKey.rawRepresentation
        let api = LicenseAPIClient(
            activateHandler: { _ in
                throw LicenseError.invalidResponse("offline activation failure")
            }
        )
        let manager = LicenseManager(store: store, api: api)

        do {
            try await manager.activate(email: "test@example.com", licenseCode: "TEST-CODE")
            throw Failure("activation failure must propagate")
        } catch LicenseError.invalidResponse(let message)
            where message == "offline activation failure" {
            // Expected: the marker and recovery phase remain in place.
        }

        guard manager.state == .limited(
            reason: .reactivationRequiredAfterKeychainRecovery
        ), manager.recoveryPhase == .reactivationRequired,
              store.values[KeychainLicenseStore.Key.licenseRecoveryMarker.rawValue] != nil,
              store.values[KeychainLicenseStore.Key.trialStartedAt.rawValue] == nil else {
            throw Failure("failed activation must not clear recovery state or start Trial")
        }
    }

    @MainActor
    private static func successfulActivationCompletesRecovery() async throws {
        let store = RecordingLicenseStore()
        let devicePrivateKey = Curve25519.Signing.PrivateKey()
        let activationId = "recovered-activation"
        let now = Date()
        let marker = LicenseRecoveryMarker(
            version: 1,
            mode: .newIdentity,
            createdAt: now,
            blocksTrialBootstrap: true
        )
        let signed = try makeSignedTestCertificate(
            activationId: activationId,
            devicePrivateKey: devicePrivateKey,
            now: now
        )
        store.values[KeychainLicenseStore.Key.licenseRecoveryMarker.rawValue] =
            try JSONEncoder().encode(marker)
        store.values[KeychainLicenseStore.Key.installId.rawValue] = Data("install-id".utf8)
        store.values[KeychainLicenseStore.Key.devicePrivateKey.rawValue] =
            devicePrivateKey.rawRepresentation
        let api = LicenseAPIClient(
            activateHandler: { _ in
                LicenseAPIClient.ActivateResponse(
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
            }
        )
        let manager = LicenseManager(
            store: store,
            verifier: signed.verifier,
            api: api
        )
        guard manager.recoveryPhase == .reactivationRequired else {
            throw Failure("test setup must begin in recovery reactivation state")
        }

        try await manager.activate(email: "test@example.com", licenseCode: "TEST-CODE")

        guard case .proActive = manager.state,
              manager.recoveryPhase == .completed,
              store.values[KeychainLicenseStore.Key.licenseRecoveryMarker.rawValue] != nil,
              store.values[KeychainLicenseStore.Key.trialStartedAt.rawValue] == nil else {
            throw Failure("successful activation must complete recovery while retaining its Trial tombstone")
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
