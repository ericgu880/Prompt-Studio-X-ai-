import Foundation
import Security

final class KeychainLicenseStore {
    private let service = "com.creatigo.promptstudio.license"

    enum Key: String {
        case installId = "promptstudio.installId"
        case devicePrivateKey = "promptstudio.devicePrivateKey"
        case devicePublicKey = "promptstudio.devicePublicKey"
        case activationId = "promptstudio.activationId"
        case licenseCertificate = "promptstudio.licenseCertificate"
        case trialStartedAt = "promptstudio.trialStartedAt"
        case lastTrustedServerTime = "promptstudio.lastTrustedServerTime"
    }

    func string(_ key: Key) throws -> String? {
        try data(key).flatMap { String(data: $0, encoding: .utf8) }
    }

    func data(_ key: Key) throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw LicenseError.keychain(status.description) }
        return result as? Data
    }

    func save(_ value: String, for key: Key) throws {
        try save(Data(value.utf8), for: key)
    }

    func save(_ value: Data, for key: Key) throws {
        let query = baseQuery(key)
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw LicenseError.keychain(addStatus.description) }
            return
        }
        guard status == errSecSuccess else { throw LicenseError.keychain(status.description) }
    }

    func delete(_ key: Key) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LicenseError.keychain(status.description)
        }
    }

    private func baseQuery(_ key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
    }
}
