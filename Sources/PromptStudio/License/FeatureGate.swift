import Foundation

struct FeatureGate {
    let state: LicenseState

    func evaluate(_ feature: FeatureKey) -> FeatureDecision {
        if feature.isBaseFeature {
            return .allowed(feature)
        }

        switch state {
        case .trialActive:
            return .allowed(feature)
        case .proActive(let certificate), .grace(let certificate, _):
            return certificate.features.contains(feature.rawValue)
                ? .allowed(feature)
                : denied(feature, reason: .featureNotIncluded)
        case .trialExpired:
            return denied(feature, reason: .trialExpired)
        case .limited(let reason):
            switch reason {
            case .certificateExpired, .refreshRequired:
                return denied(feature, reason: .licenseExpired)
            case .revoked:
                return denied(feature, reason: .licenseRevoked)
            case .noLicense, .trialExpired, .invalidCertificate, .deviceMismatch, .clockInvalid:
                return denied(feature, reason: .licenseRequired)
            }
        case .revoked:
            return denied(feature, reason: .licenseRevoked)
        }
    }

    func assertAllowed(_ feature: FeatureKey) throws {
        let decision = evaluate(feature)
        if !decision.allowed {
            throw LicenseError.featureDenied(decision)
        }
    }

    private func denied(_ feature: FeatureKey, reason: FeatureDeniedReason) -> FeatureDecision {
        let featureName = displayName(for: feature)
        let title: String
        let message: String
        let action: UpgradeAction
        switch reason {
        case .trialExpired:
            title = "\(featureName)需要 PromptStudio Pro"
            message = "试用已结束。你仍可以打开、搜索、复制和基础导出已有数据。"
            action = .activate
        case .licenseExpired:
            title = "需要刷新 PromptStudio Pro"
            message = "本地授权已过宽限期。你仍可以打开、搜索、复制和基础导出已有数据。"
            action = .refreshLicense
        case .licenseRevoked:
            title = "授权当前不可用"
            message = "你仍可以打开、搜索、复制和基础导出已有数据。如认为这是误判，请联系支持。"
            action = .contactSupport
        case .licenseRequired:
            title = "\(featureName)需要 PromptStudio Pro"
            message = "该功能属于 Pro 功能。你仍可以打开、搜索、复制和基础导出已有数据。"
            action = .activate
        case .featureNotIncluded:
            title = "当前授权不包含此功能"
            message = "该功能不在当前授权权益中。"
            action = .contactSupport
        }
        return FeatureDecision(
            allowed: false,
            feature: feature,
            reason: reason,
            title: title,
            message: message,
            primaryAction: action
        )
    }

    private func displayName(for feature: FeatureKey) -> String {
        switch feature {
        case .proCreatePrompt: "新建 Prompt"
        case .proEditPrompt: "编辑 Prompt"
        case .proDuplicatePrompt: "复制为新 Prompt"
        case .proManageTags: "标签管理"
        case .proManageCollections: "集合管理"
        case .proTemplates: "模板管理"
        case .proCustomVariables: "自定义变量"
        case .proSingleImport: "导入"
        case .proBatchImport: "批量导入"
        case .proAdvancedSearch: "高级搜索"
        case .proAIAssist: "AI 辅助"
        case .proAdvancedExport: "高级导出"
        case .proAutomation: "自动化"
        case .baseOpenLibrary, .baseViewPrompt, .baseCopyPrompt, .baseBasicSearch, .baseBasicExport, .baseDeleteLocalData, .baseLicenseSettings:
            "该功能"
        }
    }
}
