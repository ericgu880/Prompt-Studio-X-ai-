import CryptoKit
import Foundation

final class LicenseCertificateVerifier {
    private let publicKeys: [String: String]
    private let bundleId: String
    private let issuer: String
    private let audience: String
    private let decoder: JSONDecoder

    init(
        publicKeys: [String: String] = LicenseCertificateVerifier.defaultPublicKeys(),
        bundleId: String = Bundle.main.bundleIdentifier ?? "com.creatigo.promptstudio",
        issuer: String = "promptstudio-license-server",
        audience: String = "promptstudio-macos"
    ) {
        self.publicKeys = publicKeys
        self.bundleId = bundleId
        self.issuer = issuer
        self.audience = audience
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func verify(_ certificateString: String, expectedActivationId: String, expectedDeviceKeyThumbprint: String) throws -> LicenseCertificate {
        let parts = certificateString.split(separator: ".").map(String.init)
        guard parts.count == 3,
              let headerData = LicenseEncoding.data(base64URL: parts[0]),
              let payloadData = LicenseEncoding.data(base64URL: parts[1]),
              let signatureData = LicenseEncoding.data(base64URL: parts[2]) else {
            throw LicenseError.invalidCertificate
        }
        let header = try decoder.decode(LicenseCertificate.Header.self, from: headerData)
        guard header.typ == "PS-LICENSE-CERT", header.alg == "EdDSA", header.v == 1,
              let publicKeyString = publicKeys[header.kid],
              let publicKeyData = LicenseEncoding.data(base64URL: publicKeyString) else {
            throw LicenseError.invalidCertificate
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        guard publicKey.isValidSignature(signatureData, for: signingInput) else {
            throw LicenseError.invalidCertificate
        }
        let certificate = try decoder.decode(LicenseCertificate.self, from: payloadData)
        guard certificate.iss == issuer,
              certificate.aud == audience,
              certificate.bundleId == bundleId,
              certificate.activationId == expectedActivationId,
              certificate.deviceKeyThumbprint == expectedDeviceKeyThumbprint,
              certificate.status == "active" else {
            throw LicenseError.invalidCertificate
        }
        return certificate
    }

    private static func defaultPublicKeys() -> [String: String] {
        if let override = ProcessInfo.processInfo.environment["PROMPTSTUDIO_LICENSE_PUBLIC_KEY_RAW_B64URL"],
           !override.isEmpty {
            return ["dev-key-1": override]
        }
        return [
            "dev-key-1": "Oh1nK1wBBKus9ooAP7Up9QKWxk_Ylpa0jeMHUt_fW4U"
        ]
    }
}
