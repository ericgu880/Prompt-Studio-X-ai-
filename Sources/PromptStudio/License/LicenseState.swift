import Foundation

enum LicenseState: Equatable {
    case trialActive(daysRemaining: Int)
    case trialExpired
    case proActive(certificate: LicenseCertificate)
    case grace(certificate: LicenseCertificate, daysRemaining: Int)
    case limited(reason: LimitedReason)
    case revoked(reason: String?)

    var displayName: String {
        switch self {
        case .trialActive: "Trial"
        case .trialExpired: "Trial Expired"
        case .proActive: "Pro"
        case .grace: "Grace"
        case .limited: "Limited"
        case .revoked: "Revoked"
        }
    }

    var localizedTitle: String {
        switch self {
        case .trialActive(let daysRemaining):
            "试用中，还剩 \(daysRemaining) 天"
        case .trialExpired:
            "试用已结束"
        case .proActive:
            "PromptStudio Pro 已激活"
        case .grace(_, let daysRemaining):
            "授权宽限期，还剩 \(daysRemaining) 天"
        case .limited:
            "当前为受限模式"
        case .revoked:
            "授权当前不可用"
        }
    }

    var localizedDetail: String {
        switch self {
        case .trialActive:
            "试用期间可使用 Pro 功能。"
        case .trialExpired:
            "你仍可以打开、查看、搜索、复制和基础导出已有数据。"
        case .proActive(let certificate):
            certificate.licenseType == "lifetime"
                ? "永久授权已生效；联网只用于安全刷新本地离线凭证。"
                : "授权已生效，本地离线凭证有效至 \(certificate.expiresAt.formatted(date: .abbreviated, time: .omitted))。"
        case .grace(let certificate, _):
            certificate.licenseType == "lifetime"
                ? "永久授权仍保留，请在 \(certificate.graceUntil.formatted(date: .abbreviated, time: .omitted)) 前联网刷新本地凭证。"
                : "请联网刷新授权。最迟刷新日为 \(certificate.graceUntil.formatted(date: .abbreviated, time: .omitted))。"
        case .limited(let reason):
            "\(reason.localizedDescription) 你仍可以打开、查看、搜索、复制和基础导出已有数据。"
        case .revoked(let reason):
            reason ?? "如认为这是误判，请联系支持。你仍可以查看和导出已有数据。"
        }
    }
}

enum LimitedReason: Equatable {
    case noLicense
    case trialExpired
    case certificateExpired
    case invalidCertificate
    case deviceMismatch
    case revoked
    case refreshRequired
    case clockInvalid
    case keychainAccessRequired
    case keychainUnavailable(String)

    var localizedDescription: String {
        switch self {
        case .noLicense:
            "未检测到本机授权。"
        case .trialExpired:
            "试用已结束。"
        case .certificateExpired:
            "本地授权证书已超过宽限期。"
        case .invalidCertificate:
            "本地授权证书无效。"
        case .deviceMismatch:
            "授权证书不属于当前设备。"
        case .revoked:
            "授权已被停用。"
        case .refreshRequired:
            "需要联网刷新授权。"
        case .clockInvalid:
            "检测到系统时间异常。"
        case .keychainAccessRequired:
            "需要授权 PromptStudio 读取原有 License 钥匙串记录。"
        case .keychainUnavailable(let message):
            "License 钥匙串不可用：\(message)"
        }
    }
}

enum FeatureKey: String, CaseIterable, Codable {
    case baseOpenLibrary = "base.open_library"
    case baseViewPrompt = "base.view_prompt"
    case baseCopyPrompt = "base.copy_prompt"
    case baseBasicSearch = "base.basic_search"
    case baseBasicExport = "base.basic_export"
    case baseDeleteLocalData = "base.delete_local_data"
    case baseLicenseSettings = "base.license_settings"
    case proCreatePrompt = "pro.create_prompt"
    case proEditPrompt = "pro.edit_prompt"
    case proDuplicatePrompt = "pro.duplicate_prompt"
    case proManageTags = "pro.manage_tags"
    case proManageCollections = "pro.manage_collections"
    case proTemplates = "pro.templates"
    case proCustomVariables = "pro.custom_variables"
    case proSingleImport = "pro.single_import"
    case proBatchImport = "pro.batch_import"
    case proAdvancedSearch = "pro.advanced_search"
    case proAIAssist = "pro.ai_assist"
    case proAdvancedExport = "pro.advanced_export"
    case proAutomation = "pro.automation"

    var isBaseFeature: Bool {
        rawValue.hasPrefix("base.")
    }
}

struct FeatureDecision: Equatable, Identifiable {
    let id = UUID()
    let allowed: Bool
    let feature: FeatureKey
    let reason: FeatureDeniedReason?
    let title: String?
    let message: String?
    let primaryAction: UpgradeAction?

    static func allowed(_ feature: FeatureKey) -> FeatureDecision {
        FeatureDecision(allowed: true, feature: feature, reason: nil, title: nil, message: nil, primaryAction: nil)
    }

    static func == (lhs: FeatureDecision, rhs: FeatureDecision) -> Bool {
        lhs.allowed == rhs.allowed
            && lhs.feature == rhs.feature
            && lhs.reason == rhs.reason
            && lhs.title == rhs.title
            && lhs.message == rhs.message
            && lhs.primaryAction == rhs.primaryAction
    }
}

enum FeatureDeniedReason: Equatable {
    case trialExpired
    case licenseRequired
    case licenseExpired
    case licenseRevoked
    case keychainAccessRequired
    case keychainUnavailable
    case featureNotIncluded
}

enum UpgradeAction: Equatable {
    case activate
    case buyPro
    case refreshLicense
    case repairKeychainAccess
    case contactSupport
}

struct LicenseReplacementDevice: Codable, Equatable, Identifiable {
    let activationId: String
    let deviceLabel: String
    let platform: String
    let appVersion: String?
    let activatedAt: Date
    let lastSeenAt: Date?

    var id: String { activationId }
}

struct LicenseAPIErrorData: Codable, Equatable {
    let deviceCount: Int?
    let seatLimit: Int?
    let devices: [LicenseReplacementDevice]?
}

enum LicenseError: Error, LocalizedError, Equatable {
    case keychain(String)
    case keychainAccessRequired
    case keychainVaultCorrupted
    case invalidCertificate
    case invalidDeviceIdentity
    case invalidResponse(String)
    case api(code: String, message: String, data: LicenseAPIErrorData?)
    case featureDenied(FeatureDecision)

    var errorDescription: String? {
        switch self {
        case .keychain(let message):
            "Keychain 操作失败：\(message)"
        case .keychainAccessRequired:
            "PromptStudio 需要你完成一次修复授权，才能读取原有 License 钥匙串记录。"
        case .keychainVaultCorrupted:
            "License Vault 已损坏；如旧记录仍在，可通过“修复访问”安全重建。"
        case .invalidCertificate:
            "授权证书无效。"
        case .invalidDeviceIdentity:
            "当前设备身份无效。"
        case .invalidResponse(let message):
            message
        case .api(_, let message, _):
            message
        case .featureDenied(let decision):
            decision.message ?? "该功能需要 PromptStudio Pro。"
        }
    }
}
