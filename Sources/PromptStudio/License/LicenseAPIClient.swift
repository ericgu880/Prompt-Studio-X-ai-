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

    private struct ErrorEnvelope: Codable {
        struct APIError: Codable {
            let code: String
            let message: String
        }
        let ok: Bool
        let error: APIError
    }

    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseURL: URL = LicenseAPIClient.defaultBaseURL(),
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func activate(_ request: ActivateRequest) async throws -> ActivateResponse {
        try await post("/v1/licenses/activate", body: request)
    }

    func refreshChallenge(activationId: String) async throws -> RefreshChallengeResponse {
        try await post("/v1/licenses/refresh/challenge", body: ["activationId": activationId])
    }

    func refresh(activationId: String, challengeId: String, signature: String, appVersion: String, osVersion: String) async throws -> RefreshResponse {
        try await post(
            "/v1/licenses/refresh",
            body: [
                "activationId": activationId,
                "challengeId": challengeId,
                "signature": signature,
                "appVersion": appVersion,
                "osVersion": osVersion
            ]
        )
    }

    func deactivate(activationId: String, challengeId: String, signature: String, reason: String) async throws {
        let _: EmptyResponse = try await post(
            "/v1/licenses/deactivate",
            body: [
                "activationId": activationId,
                "challengeId": challengeId,
                "signature": signature,
                "reason": reason
            ]
        )
    }

    func recover(email: String) async throws {
        let _: EmptyResponse = try await post("/v1/licenses/recover", body: ["email": email])
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            if let envelope = try? decoder.decode(ErrorEnvelope.self, from: data) {
                throw LicenseError.api(code: envelope.error.code, message: envelope.error.message)
            }
            throw LicenseError.invalidResponse("授权服务暂时不可用，请稍后再试。")
        }
        return try decoder.decode(T.self, from: data)
    }

    private func url(for path: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let requestPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, requestPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        return components.url!
    }

    private struct EmptyResponse: Codable {
        let ok: Bool
    }

    private static func defaultBaseURL() -> URL {
        if let raw = ProcessInfo.processInfo.environment["PROMPTSTUDIO_LICENSE_SERVER_URL"],
           let url = URL(string: raw) {
            return url
        }
        if let raw = UserDefaults.standard.string(forKey: "PromptStudioLicenseServerURL"),
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "http://localhost:8787")!
    }
}
