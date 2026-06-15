import CryptoKit
import Foundation

struct DeviceIdentity {
    let installId: String
    let installIdHash: String
    let publicKeyBase64URL: String
    let deviceKeyThumbprint: String
    let deviceLabel: String
}

final class DeviceIdentityManager {
    private let store: KeychainLicenseStore

    init(store: KeychainLicenseStore) {
        self.store = store
    }

    func loadOrCreateIdentity() throws -> DeviceIdentity {
        let installId = try loadOrCreateInstallId()
        let privateKey = try loadOrCreatePrivateKey()
        let publicKeyData = privateKey.publicKey.rawRepresentation
        let publicKey = LicenseEncoding.base64URL(publicKeyData)
        try store.save(publicKey, for: .devicePublicKey)
        return DeviceIdentity(
            installId: installId,
            installIdHash: LicenseEncoding.sha256Base64URL("install:\(installId)"),
            publicKeyBase64URL: publicKey,
            deviceKeyThumbprint: LicenseEncoding.sha256Base64URL(publicKeyData),
            deviceLabel: Self.defaultDeviceLabel()
        )
    }

    func sign(_ message: String) throws -> String {
        let privateKey = try loadOrCreatePrivateKey()
        return LicenseEncoding.base64URL(try privateKey.signature(for: Data(message.utf8)))
    }

    private func loadOrCreateInstallId() throws -> String {
        if let existing = try store.string(.installId), !existing.isEmpty {
            return existing
        }
        let value = UUID().uuidString
        try store.save(value, for: .installId)
        return value
    }

    private func loadOrCreatePrivateKey() throws -> Curve25519.Signing.PrivateKey {
        if let data = try store.data(.devicePrivateKey) {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        let privateKey = Curve25519.Signing.PrivateKey()
        try store.save(privateKey.rawRepresentation, for: .devicePrivateKey)
        return privateKey
    }

    private static func defaultDeviceLabel() -> String {
        let model = Host.current().localizedName ?? "Mac"
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(model) - macOS \(version.majorVersion).\(version.minorVersion)"
    }
}
