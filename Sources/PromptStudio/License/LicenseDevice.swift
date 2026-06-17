import Foundation

struct LicenseDevice: Codable, Equatable, Identifiable {
    let activationId: String
    let label: String
    let status: String
    let platform: String
    let appVersion: String?
    let osVersion: String?
    let activatedAt: Date
    let lastSeenAt: Date?
    let isCurrent: Bool

    var id: String { activationId }
}

struct LicenseDeviceList: Codable, Equatable {
    let seatLimit: Int
    let activeDeviceCount: Int
    let devices: [LicenseDevice]
}
