import CryptoKit
import Foundation

enum LicenseEncoding {
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64URL string: String) -> Data? {
        var normalized = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - normalized.count % 4) % 4
        normalized += String(repeating: "=", count: padding)
        return Data(base64Encoded: normalized)
    }

    static func sha256Base64URL(_ text: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(text.utf8))))
    }

    static func sha256Base64URL(_ data: Data) -> String {
        base64URL(Data(SHA256.hash(data: data)))
    }
}
