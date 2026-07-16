import Combine
import CryptoKit
import Foundation
import LocalAuthentication

@MainActor
final class LicenseManager: ObservableObject {
    @Published private(set) var state: LicenseState = .limited(reason: .noLicense)
    @Published private(set) var recoveryPhase: LicenseRecoveryPhase = .notRequired

    private let store: any LicenseStore
    private let trialManager: TrialManager
    private let identityManager: DeviceIdentityManager
    private let verifier: LicenseCertificateVerifier
    private let api: LicenseAPIClient
    private let formatter = ISO8601DateFormatter()
    private var mutationGeneration: UInt64 = 0
    private var activationEpoch: UInt64 = 0

    private struct SignedDeviceChallenge {
        let activationId: String
        let challengeId: String
        let signature: String
    }

    init(
        store: any LicenseStore = KeychainLicenseStore(),
        verifier: LicenseCertificateVerifier = LicenseCertificateVerifier(),
        api: LicenseAPIClient? = nil
    ) {
        self.store = store
        self.trialManager = TrialManager(store: store)
        self.identityManager = DeviceIdentityManager(store: store)
        self.verifier = verifier
        self.api = api ?? LicenseAPIClient()
        loadStateOnLaunch()
    }

    var featureGate: FeatureGate {
        FeatureGate(state: state)
    }

    func loadStateOnLaunch() {
        _ = beginMutation()
        do {
            try store.prepareForBackgroundAccess()
            state = try resolveLocalState()
            if state == .limited(reason: .reactivationRequiredAfterKeychainRecovery) {
                recoveryPhase = .reactivationRequired
            } else if recoveryPhase != .completed {
                recoveryPhase = .notRequired
            }
        } catch LicenseError.keychainAccessRequired {
            state = .limited(reason: .keychainAccessRequired)
            recoveryPhase = .choiceRequired
        } catch {
            state = .limited(reason: .keychainUnavailable(error.localizedDescription))
        }
    }

    func repairKeychainAccess() throws {
        try recoverLicense(using: .preserveAndMigrate)
    }

    func recoverLicense(using option: LicenseRecoveryOption) throws {
        _ = beginMutation()
        recoveryPhase = .working(option)
        do {
            switch option {
            case .preserveAndMigrate:
                let context = LAContext()
                context.localizedReason = "读取并保留这台 Mac 上现有的 PromptStudio License"
                try store.withInteractiveAuthentication(context: context) {
                    try store.migrateLegacyItemsToVault()
                }
                try store.prepareForBackgroundAccess()
                state = try resolveLocalState()
                recoveryPhase = state == .limited(
                    reason: .reactivationRequiredAfterKeychainRecovery
                ) ? .reactivationRequired : .completed
            case .newIdentityAndReactivate:
                try store.createFreshVaultForReactivation(now: Date())
                state = .limited(
                    reason: .reactivationRequiredAfterKeychainRecovery
                )
                recoveryPhase = .reactivationRequired
            }
        } catch {
            recoveryPhase = .failed(
                option: option,
                message: Self.recoveryErrorMessage(error)
            )
            throw error
        }
    }

    func activate(email: String, licenseCode: String, replacing activationId: String? = nil) async throws {
        let generation = beginMutation()
        try store.prepareForBackgroundAccess()
        let identity = try identityManager.loadOrCreateIdentity()
        let bundleId = Bundle.main.bundleIdentifier ?? "com.creatigo.promptstudio"
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let osVersion = Self.osVersionString()
        let nonce = LicenseEncoding.base64URL(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let createdAt = formatter.string(from: Date())
        let proofMessage = buildActivateProofMessage(
            email: email,
            licenseCode: licenseCode,
            installIdHash: identity.installIdHash,
            devicePublicKey: identity.publicKeyBase64URL,
            bundleId: bundleId,
            appVersion: appVersion,
            osVersion: osVersion,
            clientNonce: nonce,
            createdAt: createdAt
        )
        let signature = try identityManager.sign(proofMessage)
        let response = try await api.activate(
            LicenseAPIClient.ActivateRequest(
                email: email,
                licenseCode: licenseCode,
                installIdHash: identity.installIdHash,
                devicePublicKey: identity.publicKeyBase64URL,
                deviceProof: LicenseAPIClient.DeviceProof(
                    version: "PromptStudio-Activate-Proof-v1",
                    clientNonce: nonce,
                    createdAt: createdAt,
                    signature: signature
                ),
                deviceLabel: identity.deviceLabel,
                bundleId: bundleId,
                appVersion: appVersion,
                osVersion: osVersion,
                replaceActivationId: activationId
            )
        )
        try saveActivation(response, identity: identity, generation: generation)
    }

    func activate(recoveryToken: String, replacing activationId: String? = nil) async throws {
        let generation = beginMutation()
        try store.prepareForBackgroundAccess()
        let identity = try identityManager.loadOrCreateIdentity()
        let bundleId = Bundle.main.bundleIdentifier ?? "com.creatigo.promptstudio"
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let osVersion = Self.osVersionString()
        let nonce = LicenseEncoding.base64URL(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let createdAt = formatter.string(from: Date())
        let proofMessage = buildRecoveryProofMessage(
            recoveryToken: recoveryToken,
            installIdHash: identity.installIdHash,
            devicePublicKey: identity.publicKeyBase64URL,
            bundleId: bundleId,
            appVersion: appVersion,
            osVersion: osVersion,
            clientNonce: nonce,
            createdAt: createdAt
        )
        let signature = try identityManager.sign(proofMessage)
        let response = try await api.activateRecovery(
            LicenseAPIClient.RecoveryActivateRequest(
                recoveryToken: recoveryToken,
                installIdHash: identity.installIdHash,
                devicePublicKey: identity.publicKeyBase64URL,
                deviceProof: LicenseAPIClient.DeviceProof(
                    version: "PromptStudio-Recovery-Proof-v1",
                    clientNonce: nonce,
                    createdAt: createdAt,
                    signature: signature
                ),
                deviceLabel: identity.deviceLabel,
                bundleId: bundleId,
                appVersion: appVersion,
                osVersion: osVersion,
                replaceActivationId: activationId
            )
        )
        try saveActivation(response, identity: identity, generation: generation)
    }

    private func saveActivation(
        _ response: LicenseAPIClient.ActivateResponse,
        identity: DeviceIdentity,
        generation: UInt64
    ) throws {
        guard generation == mutationGeneration else { return }
        let completesRecovery = recoveryPhase == .reactivationRequired
        _ = try verifier.verify(
            response.licenseCertificate,
            expectedActivationId: response.activationId,
            expectedDeviceKeyThumbprint: identity.deviceKeyThumbprint
        )
        try store.save(response.activationId, for: .activationId)
        try store.save(response.licenseCertificate, for: .licenseCertificate)
        try store.save(formatter.string(from: response.serverTime ?? Date()), for: .lastTrustedServerTime)
        try store.delete(.licenseRevocation)
        // A successful activation establishes new ownership even when the
        // server reuses the same activation ID. Older in-flight operations
        // must not be allowed to revoke this newly established activation.
        activationEpoch &+= 1
        state = try resolveLocalState()
        if completesRecovery {
            recoveryPhase = .completed
        }
    }

    func refreshIfNeeded() async {
        guard case .proActive(let certificate) = state, Date() >= certificate.refreshAfter else {
            if case .grace = state {
                try? await forceRefresh()
            }
            return
        }
        try? await forceRefresh()
    }

    func forceRefresh() async throws {
        let generation = beginMutation()
        let ownershipEpoch = activationEpoch
        try store.prepareForBackgroundAccess()
        guard let activationId = try store.string(.activationId) else {
            state = .limited(reason: .noLicense)
            return
        }
        do {
            let challenge = try await api.refreshChallenge(activationId: activationId)
            guard try mutationIsCurrent(generation, activationId: activationId) else { return }
            let bundleId = Bundle.main.bundleIdentifier ?? "com.creatigo.promptstudio"
            let message = buildDeviceProofMessage(
                activationId: activationId,
                challengeId: challenge.challengeId,
                nonce: challenge.nonce,
                bundleId: bundleId
            )
            let signature = try identityManager.sign(message)
            let response = try await api.refresh(
                activationId: activationId,
                challengeId: challenge.challengeId,
                signature: signature,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                osVersion: Self.osVersionString()
            )
            guard try mutationIsCurrent(generation, activationId: activationId) else { return }
            let identity = try identityManager.loadOrCreateIdentity()
            _ = try verifier.verify(
                response.licenseCertificate,
                expectedActivationId: activationId,
                expectedDeviceKeyThumbprint: identity.deviceKeyThumbprint
            )
            try store.save(response.licenseCertificate, for: .licenseCertificate)
            try store.save(formatter.string(from: response.serverTime ?? Date()), for: .lastTrustedServerTime)
            state = try resolveLocalState()
        } catch LicenseError.api(let code, let message, let data) where code == "LICENSE_REVOKED" || code == "LICENSE_NOT_AVAILABLE" {
            if try activationOwnershipIsCurrent(ownershipEpoch, activationId: activationId) {
                try persistRevocation(message)
            }
            throw LicenseError.api(code: code, message: message, data: data)
        } catch LicenseError.api(let code, let message, let data) where code == "INVALID_DEVICE_PROOF" {
            if try mutationIsCurrent(generation, activationId: activationId) {
                state = .limited(reason: .deviceMismatch)
            }
            throw LicenseError.api(code: code, message: message, data: data)
        }
    }

    func deactivateCurrentDevice() async throws {
        _ = beginMutation()
        let ownershipEpoch = activationEpoch
        try store.prepareForBackgroundAccess()
        guard let activationId = try store.string(.activationId) else { return }
        let challenge = try await api.refreshChallenge(activationId: activationId)
        let bundleId = Bundle.main.bundleIdentifier ?? "com.creatigo.promptstudio"
        let signature = try identityManager.sign(
            buildDeviceProofMessage(
                activationId: activationId,
                challengeId: challenge.challengeId,
                nonce: challenge.nonce,
                bundleId: bundleId
            )
        )
        try await api.deactivate(
            activationId: activationId,
            challengeId: challenge.challengeId,
            signature: signature,
            reason: "user_requested"
        )
        guard try activationOwnershipIsCurrent(ownershipEpoch, activationId: activationId) else { return }
        try persistRevocation("本机授权已停用。如需继续使用 Pro，请重新激活。")
    }

    func listDevices() async throws -> LicenseDeviceList {
        let proof = try await makeSignedDeviceChallenge()
        return try await api.listDevices(
            activationId: proof.activationId,
            challengeId: proof.challengeId,
            signature: proof.signature
        )
    }

    func renameDevice(activationId targetActivationId: String, label: String) async throws {
        let proof = try await makeSignedDeviceChallenge()
        try await api.renameDevice(
            activationId: proof.activationId,
            challengeId: proof.challengeId,
            signature: proof.signature,
            targetActivationId: targetActivationId,
            label: label
        )
    }

    func deactivateDevice(activationId targetActivationId: String) async throws {
        _ = beginMutation()
        let ownershipEpoch = activationEpoch
        try store.prepareForBackgroundAccess()
        let currentActivationId = try store.string(.activationId)
        let proof = try await makeSignedDeviceChallenge()
        try await api.deactivateDevice(
            activationId: proof.activationId,
            challengeId: proof.challengeId,
            signature: proof.signature,
            targetActivationId: targetActivationId,
            reason: "user_requested"
        )
        if let currentActivationId,
           targetActivationId == currentActivationId,
           try activationOwnershipIsCurrent(ownershipEpoch, activationId: currentActivationId) {
            try persistRevocation("本机授权已停用。如需继续使用 Pro，请重新激活。")
        }
    }

    func recover(email: String) async throws {
        try await api.recover(email: email)
    }

    private func makeSignedDeviceChallenge() async throws -> SignedDeviceChallenge {
        try store.prepareForBackgroundAccess()
        guard let activationId = try store.string(.activationId) else {
            throw LicenseError.invalidResponse("未检测到本机授权。")
        }
        let challenge = try await api.refreshChallenge(activationId: activationId)
        let bundleId = Bundle.main.bundleIdentifier ?? "com.creatigo.promptstudio"
        let signature = try identityManager.sign(
            buildDeviceProofMessage(
                activationId: activationId,
                challengeId: challenge.challengeId,
                nonce: challenge.nonce,
                bundleId: bundleId
            )
        )
        return SignedDeviceChallenge(
            activationId: activationId,
            challengeId: challenge.challengeId,
            signature: signature
        )
    }

    private func resolveLocalState(now localNow: Date = Date()) throws -> LicenseState {
        if let revocation = try store.string(.licenseRevocation) {
            return .revoked(reason: revocation.isEmpty ? nil : revocation)
        }
        let certificateString = try store.string(.licenseCertificate)
        let activationId = try store.string(.activationId)
        if certificateString != nil || activationId != nil {
            guard let certificateString, let activationId else {
                return .limited(reason: .invalidCertificate)
            }
            let identity: DeviceIdentity
            do {
                identity = try identityManager.loadOrCreateIdentity()
            } catch LicenseError.keychainAccessRequired {
                throw LicenseError.keychainAccessRequired
            } catch {
                return .limited(reason: .deviceMismatch)
            }
            let certificate: LicenseCertificate
            do {
                certificate = try verifier.verify(
                    certificateString,
                    expectedActivationId: activationId,
                    expectedDeviceKeyThumbprint: identity.deviceKeyThumbprint
                )
            } catch {
                return .limited(reason: .invalidCertificate)
            }
            let trusted = try trustedServerTime()
            if let trusted, localNow < trusted.addingTimeInterval(-24 * 60 * 60) {
                return .limited(reason: .clockInvalid)
            }
            let now = effectiveNow(localNow, trustedServerTime: trusted)
            if now <= certificate.expiresAt {
                return .proActive(certificate: certificate)
            }
            if now <= certificate.graceUntil {
                return .grace(certificate: certificate, daysRemaining: Self.daysUntil(certificate.graceUntil, from: now))
            }
            return .limited(reason: .certificateExpired)
        }

        if let markerData = try store.data(.licenseRecoveryMarker) {
            guard let marker = try? JSONDecoder().decode(
                LicenseRecoveryMarker.self,
                from: markerData
            ) else {
                return .limited(
                    reason: .reactivationRequiredAfterKeychainRecovery
                )
            }
            if marker.blocksTrialBootstrap {
                return .limited(
                    reason: .reactivationRequiredAfterKeychainRecovery
                )
            }
        }

        let trial = try trialManager.currentState(now: localNow)
        return trial.isActive ? .trialActive(daysRemaining: trial.daysRemaining) : .trialExpired
    }

    private func persistRevocation(_ reason: String) throws {
        state = .revoked(reason: reason)
        // The tombstone must land before either delete. Once the server has
        // confirmed deactivation, a cleanup failure must never revive the older
        // certificate on the next offline launch.
        try store.save(reason, for: .licenseRevocation)
        try store.delete(.licenseCertificate)
        try store.delete(.activationId)
    }

    @discardableResult
    private func beginMutation() -> UInt64 {
        mutationGeneration &+= 1
        return mutationGeneration
    }

    private func mutationIsCurrent(_ generation: UInt64, activationId: String) throws -> Bool {
        guard generation == mutationGeneration else { return false }
        return try store.string(.activationId) == activationId
    }

    private func activationOwnershipIsCurrent(_ epoch: UInt64, activationId: String) throws -> Bool {
        guard epoch == activationEpoch else { return false }
        return try store.string(.activationId) == activationId
    }

    private func effectiveNow(_ localNow: Date, trustedServerTime: Date?) -> Date {
        guard let trusted = trustedServerTime else {
            return localNow
        }
        return max(localNow, trusted)
    }

    private func trustedServerTime() throws -> Date? {
        guard let raw = try store.string(.lastTrustedServerTime) else {
            return nil
        }
        return formatter.date(from: raw)
    }

    private func buildActivateProofMessage(
        email: String,
        licenseCode: String,
        installIdHash: String,
        devicePublicKey: String,
        bundleId: String,
        appVersion: String,
        osVersion: String,
        clientNonce: String,
        createdAt: String
    ) -> String {
        [
            "PromptStudio-Activate-Proof-v1",
            "emailSha256:\(LicenseEncoding.sha256Base64URL(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()))",
            "licenseCodeSha256:\(LicenseEncoding.sha256Base64URL(Self.normalizedLicenseCode(licenseCode)))",
            "installIdHash:\(installIdHash)",
            "devicePublicKey:\(devicePublicKey)",
            "bundleId:\(bundleId)",
            "appVersion:\(appVersion.isEmpty ? "-" : appVersion)",
            "osVersion:\(osVersion.isEmpty ? "-" : osVersion)",
            "clientNonce:\(clientNonce)",
            "createdAt:\(createdAt)"
        ].joined(separator: "\n")
    }

    private func buildDeviceProofMessage(activationId: String, challengeId: String, nonce: String, bundleId: String) -> String {
        [
            "PromptStudio-Device-Proof-v1",
            "activationId:\(activationId)",
            "challengeId:\(challengeId)",
            "nonce:\(nonce)",
            "bundleId:\(bundleId)"
        ].joined(separator: "\n")
    }

    private func buildRecoveryProofMessage(
        recoveryToken: String,
        installIdHash: String,
        devicePublicKey: String,
        bundleId: String,
        appVersion: String,
        osVersion: String,
        clientNonce: String,
        createdAt: String
    ) -> String {
        [
            "PromptStudio-Recovery-Proof-v1",
            "recoveryTokenSha256:\(LicenseEncoding.sha256Base64URL(recoveryToken))",
            "installIdHash:\(installIdHash)",
            "devicePublicKey:\(devicePublicKey)",
            "bundleId:\(bundleId)",
            "appVersion:\(appVersion.isEmpty ? "-" : appVersion)",
            "osVersion:\(osVersion.isEmpty ? "-" : osVersion)",
            "clientNonce:\(clientNonce)",
            "createdAt:\(createdAt)"
        ].joined(separator: "\n")
    }

    private static func normalizedLicenseCode(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
            .map(String.init)
            .joined()
    }

    private static func daysUntil(_ date: Date, from now: Date) -> Int {
        max(0, Calendar.current.dateComponents([.day], from: now, to: date).day ?? 0)
    }

    private static func osVersionString() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func recoveryErrorMessage(_ error: Error) -> String {
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return String(describing: error)
    }
}
