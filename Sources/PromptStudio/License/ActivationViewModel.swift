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
    @Published private(set) var recoveryToken: String?
    @Published private(set) var replacementDevices: [LicenseReplacementDevice] = []
    @Published var selectedReplacementID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isActivated = false
    @Published var feedback: ActivationFeedback = .idle

    var canSubmit: Bool {
        (isRecoveryActivation
            || (!email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !licenseCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            && !isLoading
            && !isActivated
    }

    var canRecover: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isLoading
            && !isActivated
            && !isRecoveryActivation
    }

    var canConfirmActivation: Bool {
        canSubmit && (replacementDevices.isEmpty || selectedReplacementID != nil)
    }

    var isRecoveryActivation: Bool {
        recoveryToken?.isEmpty == false
    }

    func beginRecovery(token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recoveryToken = trimmed
        replacementDevices = []
        selectedReplacementID = nil
        feedback = .info("一次性恢复凭证已载入，请在 15 分钟内完成本机授权。")
    }

    func activate(using manager: LicenseManager) async -> Bool {
        guard canSubmit else { return false }
        isLoading = true
        feedback = .loading(
            isRecoveryActivation
                ? "正在验证恢复凭证和当前设备身份..."
                : "正在验证邮箱、激活码和当前设备身份..."
        )
        defer { isLoading = false }
        do {
            if let recoveryToken {
                try await manager.activate(
                    recoveryToken: recoveryToken,
                    replacing: selectedReplacementID
                )
            } else {
                try await manager.activate(
                    email: email,
                    licenseCode: licenseCode,
                    replacing: selectedReplacementID
                )
            }
            isActivated = true
            feedback = .success("PromptStudio Pro 已在当前设备激活。")
            return true
        } catch LicenseError.api(let code, let message, let data) {
            if code == "SEAT_LIMIT_EXCEEDED", let devices = data?.devices, !devices.isEmpty {
                replacementDevices = devices
                selectedReplacementID = nil
                feedback = .info("设备席位已满，请选择一台旧设备进行替换。")
            } else {
                feedback = .error(message)
            }
            return false
        } catch let error as LicenseError {
            feedback = .error(error.localizedDescription)
            return false
        } catch {
            feedback = .error("激活失败，请稍后重试。")
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
            feedback = .info("如果该邮箱有有效授权，我们会发送找回邮件。链接 15 分钟内有效。")
        } catch let error as LicenseError {
            feedback = .error(error.localizedDescription)
        } catch {
            feedback = .error("找回请求提交失败，请稍后重试。")
        }
    }

    private func clearFeedbackAfterEditing() {
        guard !isLoading, !isActivated else { return }
        replacementDevices = []
        selectedReplacementID = nil
        switch feedback {
        case .error, .info:
            feedback = .idle
        case .idle, .loading, .success:
            break
        }
    }
}
