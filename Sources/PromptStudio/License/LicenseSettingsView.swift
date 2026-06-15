import AppKit
import SwiftUI

struct LicenseSettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var isActivationPresented = false
    @State private var isRefreshing = false
    @State private var isDeactivating = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusPanel
            actionsPanel
            policyPanel
        }
        .sheet(isPresented: $isActivationPresented) {
            ActivationSheetView()
                .environmentObject(state)
        }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                LicenseStatusBadge(state: state.licenseManager.state)
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.licenseManager.state.localizedTitle)
                        .font(StudioFont.font(15, weight: .semibold))
                        .foregroundStyle(StudioColor.text)
                    Text(state.licenseManager.state.localizedDetail)
                        .font(StudioFont.font(12))
                        .foregroundStyle(StudioColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            if let certificate = currentCertificate {
                Divider().overlay(StudioColor.hairline)
                VStack(spacing: 10) {
                    licenseInfoRow("方案", certificate.plan)
                    licenseInfoRow("设备数", "\(certificate.seatLimit)")
                    licenseInfoRow("证书到期", certificate.expiresAt.formatted(date: .abbreviated, time: .shortened))
                    licenseInfoRow("宽限期至", certificate.graceUntil.formatted(date: .abbreviated, time: .shortened))
                }
            }

            if let message {
                Text(message)
                    .font(StudioFont.font(12))
                    .foregroundStyle(StudioColor.secondaryText)
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
    }

    private var actionsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            licenseActionRow("激活码", detail: "输入购买邮箱和激活码。") {
                Button("激活") {
                    isActivationPresented = true
                }
                .buttonStyle(CapsuleButtonStyle(filled: true))
            }
            licenseActionRow("刷新授权", detail: "联网更新本机 30 天证书。") {
                Button(isRefreshing ? "刷新中" : "刷新") {
                    Task { await refresh() }
                }
                .buttonStyle(CapsuleButtonStyle())
                .disabled(isRefreshing)
            }
            licenseActionRow("当前设备", detail: "停用后会释放一个设备席位。") {
                Button(isDeactivating ? "停用中" : "停用设备") {
                    Task { await deactivate() }
                }
                .buttonStyle(CapsuleButtonStyle())
                .disabled(isDeactivating || currentCertificate == nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
    }

    private var policyPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("受限模式")
                .font(StudioFont.font(13, weight: .semibold))
            Text("授权不可用时，PromptStudio 仍允许打开、查看、基础搜索、复制、基础导出和删除本地数据；新建、编辑、导入、高级导出和集合管理需要 Pro。")
                .font(StudioFont.font(12))
                .foregroundStyle(StudioColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
    }

    private var currentCertificate: LicenseCertificate? {
        switch state.licenseManager.state {
        case .proActive(let certificate), .grace(let certificate, _):
            certificate
        default:
            nil
        }
    }

    private func licenseInfoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(StudioFont.font(12))
                .foregroundStyle(StudioColor.secondaryText)
            Spacer()
            Text(value)
                .font(StudioFont.font(12, weight: .medium))
                .foregroundStyle(StudioColor.text)
        }
    }

    private func licenseActionRow<Content: View>(
        _ title: String,
        detail: String,
        @ViewBuilder action: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(StudioFont.font(13, weight: .semibold))
                Text(detail)
                    .font(StudioFont.font(12))
                    .foregroundStyle(StudioColor.secondaryText)
            }
            Spacer()
            action()
        }
        .padding(16)
        .overlay(alignment: .top) { Rectangle().fill(StudioColor.hairline).frame(height: 1) }
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await state.licenseManager.forceRefresh()
            message = "授权已刷新。"
        } catch {
            message = error.localizedDescription
        }
    }

    private func deactivate() async {
        isDeactivating = true
        defer { isDeactivating = false }
        do {
            try await state.licenseManager.deactivateCurrentDevice()
            message = "当前设备已停用。"
        } catch {
            message = error.localizedDescription
        }
    }
}

struct ActivationSheetView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = ActivationViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("激活 PromptStudio Pro")
                    .font(StudioFont.font(18, weight: .semibold))
                Text("输入购买邮箱和激活码。")
                    .font(StudioFont.font(13))
                    .foregroundStyle(StudioColor.secondaryText)
            }

            VStack(alignment: .leading, spacing: 12) {
                labeledField("购买邮箱") {
                    TextField("name@example.com", text: $viewModel.email)
                        .textContentType(.emailAddress)
                }
                labeledField("激活码") {
                    TextField("PS-XXXX-XXXX-XXXX-XXXX-XXXX", text: $viewModel.licenseCode)
                        .textContentType(.oneTimeCode)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                }
            }

            if let message = viewModel.message {
                Text(message)
                    .font(StudioFont.font(12))
                    .foregroundStyle(StudioColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button("找回激活码") {
                    Task { await viewModel.recover(using: state.licenseManager) }
                }
                .buttonStyle(TextHoverButtonStyle())
                .disabled(viewModel.isLoading || viewModel.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()

                Button("取消") { dismiss() }
                    .buttonStyle(CapsuleButtonStyle())

                Button(viewModel.isLoading ? "激活中" : "激活") {
                    Task {
                        if await viewModel.activate(using: state.licenseManager) {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(CapsuleButtonStyle(filled: true))
                .disabled(!viewModel.canSubmit)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(StudioColor.appBackground)
        .foregroundStyle(StudioColor.text)
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(StudioFont.font(12, weight: .medium))
                .foregroundStyle(StudioColor.secondaryText)
            content()
                .textFieldStyle(.plain)
                .font(StudioFont.font(13))
                .foregroundStyle(StudioColor.text)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(StudioColor.control)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
        }
    }
}

struct FeatureDeniedSheet: View {
    @EnvironmentObject private var state: AppState
    let decision: FeatureDecision
    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName)
                    .font(StudioFont.symbol(22, weight: .medium))
                    .foregroundStyle(StudioColor.primaryAction)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(StudioColor.control))
                VStack(alignment: .leading, spacing: 7) {
                    Text(decision.title ?? "需要 PromptStudio Pro")
                        .font(StudioFont.font(18, weight: .semibold))
                    Text(decision.message ?? "该功能需要 PromptStudio Pro。")
                        .font(StudioFont.font(13))
                        .foregroundStyle(StudioColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Button("关闭") {
                    state.modal = nil
                }
                .buttonStyle(CapsuleButtonStyle())

                Spacer()

                switch decision.primaryAction {
                case .refreshLicense:
                    Button(isRefreshing ? "刷新中" : "刷新授权") {
                        Task { await refresh() }
                    }
                    .buttonStyle(CapsuleButtonStyle(filled: true))
                    .disabled(isRefreshing)
                case .contactSupport:
                    Button("打开授权设置") {
                        state.openLicenseSettings()
                    }
                    .buttonStyle(CapsuleButtonStyle(filled: true))
                case .buyPro:
                    Button("购买 Pro") {
                        openPurchasePage()
                    }
                    .buttonStyle(CapsuleButtonStyle())
                    Button("输入激活码") {
                        state.openLicenseSettings()
                    }
                    .buttonStyle(CapsuleButtonStyle(filled: true))
                case .activate, .none:
                    Button("输入激活码") {
                        state.openLicenseSettings()
                    }
                    .buttonStyle(CapsuleButtonStyle(filled: true))
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(StudioColor.appBackground)
        .foregroundStyle(StudioColor.text)
    }

    private var iconName: String {
        switch decision.reason {
        case .licenseExpired:
            "arrow.clockwise"
        case .licenseRevoked:
            "exclamationmark.triangle"
        default:
            "lock"
        }
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await state.licenseManager.forceRefresh()
            state.modal = nil
        } catch {
            state.modal = .error(error.localizedDescription)
        }
    }

    private func openPurchasePage() {
        if let url = URL(string: "https://promptstudio.app/pricing") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct LicenseStatusBadge: View {
    let state: LicenseState

    var body: some View {
        Text(label)
            .font(StudioFont.font(11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(color.opacity(0.13)))
            .overlay(Capsule().stroke(color.opacity(0.42), lineWidth: 1))
    }

    private var label: String {
        switch state {
        case .trialActive:
            "TRIAL"
        case .trialExpired:
            "TRIAL ENDED"
        case .proActive:
            "PRO"
        case .grace:
            "GRACE"
        case .limited:
            "LIMITED"
        case .revoked:
            "REVOKED"
        }
    }

    private var color: Color {
        switch state {
        case .trialActive, .proActive:
            StudioColor.primaryAction
        case .grace:
            Color.yellow
        case .trialExpired, .limited:
            StudioColor.secondaryText
        case .revoked:
            Color.red
        }
    }
}
