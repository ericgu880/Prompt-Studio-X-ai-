import Foundation

struct LicenseCertificate: Codable, Equatable {
    struct Header: Codable, Equatable {
        let typ: String
        let alg: String
        let kid: String
        let v: Int
    }

    let iss: String
    let aud: String
    let bundleId: String
    let licenseId: String
    let activationId: String
    let customerEmailHash: String
    let plan: String
    let licenseType: String
    let status: String
    let seatLimit: Int
    let features: [String]
    let majorVersion: Int
    let updatesUntil: Date?
    let deviceKeyThumbprint: String
    let issuedAt: Date
    let refreshAfter: Date
    let expiresAt: Date
    let graceUntil: Date
    let serverTime: Date
}
