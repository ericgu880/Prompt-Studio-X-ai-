import Combine
import CryptoKit
import Foundation

@MainActor
final class LicenseManager: ObservableObject {
    @Published private(set) var state: LicenseState = .limited(reason: .noLicense)

    private let store: KeychainLicenseStore
    private let trialManager: TrialManager
    private let identityManager: DeviceIdentityManager
    private let verifier: LicenseCertificateVerifier
    private let api: LicenseAPIClient
    private let formatter = ISO8601DateFormatter()

    init(
        store: KeychainLicenseStore = KeychainLicenseStore(),
        verifier: LicenseCertificateVerifier = LicenseCertificateVerifier(),
        api: LicenseAPIClient = LicenseAPIClient()
    ) {
        self.store = store
        self.trialManager = TrialManager(store: store)
        self.identityManager = DeviceIdentityManager(store: store)
        self.verifier = verifier
        self.api = api
        loadStateOnLaunch()
    }

    var featureGate: FeatureGate {
        FeatureGate(state: state)
    }

    func loadStateOnLaunch() {
        state = resolveLocalState()
    }

    func activate(email: String, licenseCode: String) async throws {
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
                osVersion: osVersion
            )
        )
        _ = try verifier.verify(
            response.licenseCertificate,
            expectedActivationId: response.activationId,
            expectedDeviceKeyThumbprint: identity.deviceKeyThumbprint
        )
        try store.save(response.activationId, for: .activationId)
        try store.save(response.licenseCertificate, for: .licenseCertificate)
        try store.save(formatter.string(from: response.serverTime ?? Date()), for: .lastTrustedServerTime)
        state = resolveLocalState()
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
        guard let activationId = try store.string(.activationId) else {
            state = .limited(reason: .noLicense)
            return
        }
        let challenge = try await api.refreshChallenge(activationId: activationId)
        let bundleId = Bundle.main.bundleIdentifier ?? "com.creatigo.promptstudio"
        let message = buildDeviceProofMessage(
            activationId: activationId,
            challengeId: challenge.challengeId,
            nonce: challenge.nonce,
            bundleId: bundleId
        )
        let signature = try identityManager.sign(message)
        do {
            let response = try await api.refresh(
                activationId: activationId,
                challengeId: challenge.challengeId,
                signature: signature,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                osVersion: Self.osVersionString()
            )
            let identity = try identityManager.loadOrCreateIdentity()
            _ = try verifier.verify(
                response.licenseCertificate,
                expectedActivationId: activationId,
                expectedDeviceKeyThumbprint: identity.deviceKeyThumbprint
            )
            try store.save(response.licenseCertificate, for: .licenseCertificate)
            try store.save(formatter.string(from: response.serverTime ?? Date()), for: .lastTrustedServerTime)
            state = resolveLocalState()
        } catch LicenseError.api(let code, let message) where code == "LICENSE_REVOKED" || code == "LICENSE_NOT_AVAILABLE" {
            state = .revoked(reason: message)
            throw LicenseError.api(code: code, message: message)
        } catch LicenseError.api(let code, let message) where code == "INVALID_DEVICE_PROOF" {
            state = .limited(reason: .deviceMismatch)
            throw LicenseError.api(code: code, message: message)
        }
    }

    func deactivateCurrentDevice() async throws {
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
        try store.delete(.licenseCertificate)
        try store.delete(.activationId)
        state = resolveLocalState()
    }

    func recover(email: String) async throws {
        try await api.recover(email: email)
    }

    private func resolveLocalState(now localNow: Date = Date()) -> LicenseState {
        let certificateString = try? store.string(.licenseCertificate)
        let activationId = try? store.string(.activationId)
        if certificateString != nil || activationId != nil {
            guard let certificateString, let activationId else {
                return .limited(reason: .invalidCertificate)
            }
            let identity: DeviceIdentity
            do {
                identity = try identityManager.loadOrCreateIdentity()
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
            if let trusted = trustedServerTime(), localNow < trusted.addingTimeInterval(-24 * 60 * 60) {
                return .limited(reason: .clockInvalid)
            }
            let now = effectiveNow(localNow)
            if now <= certificate.expiresAt {
                return .proActive(certificate: certificate)
            }
            if now <= certificate.graceUntil {
                return .grace(certificate: certificate, daysRemaining: Self.daysUntil(certificate.graceUntil, from: now))
            }
            return .limited(reason: .certificateExpired)
        }

        let trial = trialManager.currentState(now: localNow)
        return trial.isActive ? .trialActive(daysRemaining: trial.daysRemaining) : .trialExpired
    }

    private func effectiveNow(_ localNow: Date) -> Date {
        guard let trusted = trustedServerTime() else {
            return localNow
        }
        return max(localNow, trusted)
    }

    private func trustedServerTime() -> Date? {
        guard let raw = try? store.string(.lastTrustedServerTime) else {
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
}
