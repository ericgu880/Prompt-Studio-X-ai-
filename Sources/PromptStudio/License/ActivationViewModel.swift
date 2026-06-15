import Foundation

@MainActor
final class ActivationViewModel: ObservableObject {
    @Published var email = ""
    @Published var licenseCode = ""
    @Published private(set) var isLoading = false
    @Published var message: String?

    var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !licenseCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isLoading
    }

    func activate(using manager: LicenseManager) async -> Bool {
        guard canSubmit else { return false }
        isLoading = true
        defer { isLoading = false }
        do {
            try await manager.activate(email: email, licenseCode: licenseCode)
            message = "已激活 PromptStudio Pro。"
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func recover(using manager: LicenseManager) async {
        let targetEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetEmail.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await manager.recover(email: targetEmail)
            message = "已记录恢复请求。当前版本不会自动发送邮件，请联系支持人员核对购买记录。"
        } catch {
            message = error.localizedDescription
        }
    }
}
