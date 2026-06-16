import Foundation

enum ActivationFeedback: Equatable {
    case idle
    case loading(String)
    case success(String)
    case error(String)
    case info(String)
}

@MainActor
final class ActivationViewModel: ObservableObject {
    @Published var email = "" {
        didSet { clearFeedbackAfterEditing() }
    }
    @Published var licenseCode = "" {
        didSet { clearFeedbackAfterEditing() }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var isActivated = false
    @Published var feedback: ActivationFeedback = .idle

    var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !licenseCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isLoading
            && !isActivated
    }

    var canRecover: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isLoading
            && !isActivated
    }

    func activate(using manager: LicenseManager) async -> Bool {
        guard canSubmit else { return false }
        isLoading = true
        feedback = .loading("正在验证邮箱、激活码和当前设备身份...")
        defer { isLoading = false }
        do {
            try await manager.activate(email: email, licenseCode: licenseCode)
            isActivated = true
            feedback = .success("激活成功，正在进入 PromptStudio...")
            return true
        } catch {
            feedback = .error("激活失败，请检查信息或稍后重试。")
            return false
        }
    }

    func recover(using manager: LicenseManager) async {
        let targetEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetEmail.isEmpty, !isLoading else { return }
        isLoading = true
        feedback = .loading("正在提交恢复请求...")
        defer { isLoading = false }
        do {
            try await manager.recover(email: targetEmail)
            feedback = .info("已记录恢复请求。当前版本不会自动发送邮件，请联系支持人员核对购买记录。")
        } catch {
            feedback = .error("恢复请求提交失败，请检查邮箱或稍后重试。")
        }
    }

    private func clearFeedbackAfterEditing() {
        guard !isLoading, !isActivated else { return }
        switch feedback {
        case .error, .info:
            feedback = .idle
        case .idle, .loading, .success:
            break
        }
    }
}
