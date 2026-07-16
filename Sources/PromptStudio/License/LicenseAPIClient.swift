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

    private struct ErrorEnvelope: Codable {
        struct APIError: Codable {
            let code: String
            let message: String
            let data: LicenseAPIErrorData?
        }
        let ok: Bool
        let error: APIError
    }

    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseURL: URL? = nil,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL ?? Self.defaultBaseURL()
        self.session = session
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = LicenseDateCoding.makeDecoder()
    }

    func activate(_ request: ActivateRequest) async throws -> ActivateResponse {
        try await post("/v1/licenses/activate", body: request)
    }

    func activateRecovery(_ request: RecoveryActivateRequest) async throws -> ActivateResponse {
        try await post("/v1/licenses/recovery/activate", body: request)
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

    func listDevices(activationId: String, challengeId: String, signature: String) async throws -> LicenseDeviceList {
        try await post(
            "/v1/licenses/devices/list",
            body: [
                "activationId": activationId,
                "challengeId": challengeId,
                "signature": signature
            ]
        )
    }

    func renameDevice(activationId: String, challengeId: String, signature: String, targetActivationId: String, label: String) async throws {
        let _: EmptyResponse = try await post(
            "/v1/licenses/devices/rename",
            body: [
                "activationId": activationId,
                "challengeId": challengeId,
                "signature": signature,
                "targetActivationId": targetActivationId,
                "label": label
            ]
        )
    }

    func deactivateDevice(activationId: String, challengeId: String, signature: String, targetActivationId: String, reason: String) async throws {
        let _: EmptyResponse = try await post(
            "/v1/licenses/devices/deactivate",
            body: [
                "activationId": activationId,
                "challengeId": challengeId,
                "signature": signature,
                "targetActivationId": targetActivationId,
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
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Self.userFacingNetworkError(error)
        } catch {
            throw LicenseError.invalidResponse("暂时无法连接授权服务，请稍后重试。")
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            if let envelope = try? decoder.decode(ErrorEnvelope.self, from: data) {
                throw LicenseError.api(
                    code: envelope.error.code,
                    message: envelope.error.message,
                    data: envelope.error.data
                )
            }
            throw LicenseError.invalidResponse(Self.message(forHTTPStatus: statusCode))
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw LicenseError.invalidResponse("授权服务响应异常，请稍后重试或联系支持。")
        }
    }

    private static func userFacingNetworkError(_ error: URLError) -> LicenseError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return .invalidResponse("当前网络不可用，请检查网络后重试。")
        case .timedOut:
            return .invalidResponse("授权服务响应超时，请稍后重试。")
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .invalidResponse("暂时无法连接授权服务，请稍后重试。")
        case .secureConnectionFailed, .serverCertificateUntrusted:
            return .invalidResponse("授权服务的安全连接失败，请稍后重试或联系支持。")
        case .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return .invalidResponse("系统时间可能不正确，请校准后重试；若时间无误，请联系支持。")
        case .cancelled:
            return .invalidResponse("授权请求已取消。")
        default:
            return .invalidResponse("网络请求失败，请稍后重试。")
        }
    }

    private static func message(forHTTPStatus statusCode: Int) -> String {
        switch statusCode {
        case 429:
            return "请求过于频繁，请稍后再试。"
        case 500...599:
            return "授权服务暂时不可用，请稍后再试。"
        default:
            return "授权请求未能完成，请检查输入后重试。"
        }
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
        LicenseRuntimeConfiguration.serverURL
    }
}
