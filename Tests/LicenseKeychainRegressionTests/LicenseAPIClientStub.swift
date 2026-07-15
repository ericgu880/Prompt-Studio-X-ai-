import Foundation

@MainActor
final class LicenseAPIClient {
    struct DeviceProof: Codable {
        let version: String
        let clientNonce: String
        let createdAt: String
        let signature: String
    }

    struct ActivateRequest: Codable {
        let email: String
        let licenseCode: String
        let installIdHash: String
        let devicePublicKey: String
        let deviceProof: DeviceProof
        let deviceLabel: String
        let bundleId: String
        let appVersion: String
        let osVersion: String
        let replaceActivationId: String?
    }

    struct RecoveryActivateRequest: Codable {
        let recoveryToken: String
        let installIdHash: String
        let devicePublicKey: String
        let deviceProof: DeviceProof
        let deviceLabel: String
        let bundleId: String
        let appVersion: String
        let osVersion: String
        let replaceActivationId: String?
    }

    struct ActivateResponse: Codable {
        let ok: Bool
        let activationId: String
        let licenseCertificate: String
        let refreshAfter: Date
        let expiresAt: Date
        let graceUntil: Date
        let deviceCount: Int
        let seatLimit: Int
        let serverTime: Date?
    }

    struct RefreshChallengeResponse: Codable {
        let ok: Bool
        let challengeId: String
        let nonce: String
        let expiresAt: Date
    }

    struct RefreshResponse: Codable {
        let ok: Bool
        let licenseCertificate: String
        let refreshAfter: Date
        let expiresAt: Date
        let graceUntil: Date
        let status: String
        let serverTime: Date?
    }

    private let activateHandler: (ActivateRequest) async throws -> ActivateResponse
    private let refreshChallengeHandler: (String) async throws -> RefreshChallengeResponse
    private let refreshHandler: (
        String,
        String,
        String,
        String,
        String
    ) async throws -> RefreshResponse
    private let deactivateHandler: (
        String,
        String,
        String,
        String
    ) async throws -> Void

    init(
        activateHandler: @escaping (ActivateRequest) async throws -> ActivateResponse = { _ in fatalError() },
        refreshChallengeHandler: @escaping (String) async throws -> RefreshChallengeResponse = { _ in fatalError() },
        refreshHandler: @escaping (
            String,
            String,
            String,
            String,
            String
        ) async throws -> RefreshResponse = { _, _, _, _, _ in fatalError() },
        deactivateHandler: @escaping (
            String,
            String,
            String,
            String
        ) async throws -> Void = { _, _, _, _ in fatalError() }
    ) {
        self.activateHandler = activateHandler
        self.refreshChallengeHandler = refreshChallengeHandler
        self.refreshHandler = refreshHandler
        self.deactivateHandler = deactivateHandler
    }

    func activate(_ request: ActivateRequest) async throws -> ActivateResponse {
        try await activateHandler(request)
    }
    func activateRecovery(_ request: RecoveryActivateRequest) async throws -> ActivateResponse { fatalError() }
    func refreshChallenge(activationId: String) async throws -> RefreshChallengeResponse {
        try await refreshChallengeHandler(activationId)
    }
    func refresh(activationId: String, challengeId: String, signature: String, appVersion: String, osVersion: String) async throws -> RefreshResponse {
        try await refreshHandler(activationId, challengeId, signature, appVersion, osVersion)
    }
    func deactivate(activationId: String, challengeId: String, signature: String, reason: String) async throws {
        try await deactivateHandler(activationId, challengeId, signature, reason)
    }
    func listDevices(activationId: String, challengeId: String, signature: String) async throws -> LicenseDeviceList { fatalError() }
    func renameDevice(activationId: String, challengeId: String, signature: String, targetActivationId: String, label: String) async throws { fatalError() }
    func deactivateDevice(activationId: String, challengeId: String, signature: String, targetActivationId: String, reason: String) async throws { fatalError() }
    func recover(email: String) async throws { fatalError() }
}
