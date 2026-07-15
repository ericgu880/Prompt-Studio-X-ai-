import AppKit
import SwiftUI

private enum LicenseCenterRoute: Equatable {
    case overview
    case activation(recoveryToken: String?)
    case devices
}

struct LicenseSettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var route: LicenseCenterRoute = .overview
    @State private var isRefreshing = false
    @State private var isDeactivating = false
    @State private var isRepairingKeychain = false
    @State private var message: String?
    @State private var confirmsCurrentDeviceDeactivation = false

    @ViewBuilder
    var body: some View {
        Group {
            switch route {
            case .overview:
                VStack(alignment: .leading, spacing: 16) {
                    statusPanel
                    actionsPanel
                    policyPanel
                }
                .confirmationDialog("停用当前设备？", isPresented: $confirmsCurrentDeviceDeactivation) {
                    Button("停用并释放席位", role: .destructive) {
                        Task { await deactivate() }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("停用后本机会退出 Pro 授权，但不会删除任何本地资料。")
                }
            case .activation(let recoveryToken):
                ActivationSheetView(
                    recoveryToken: recoveryToken,
                    onClose: { route = .overview },
                    onActivated: {
                        state.showToast("PromptStudio Pro 已激活")
                        route = .overview
                    }
                )
                .environmentObject(state)
                .id(recoveryToken ?? "manual-activation")
            case .devices:
                LicenseDeviceManagementSheet(
                    onClose: { route = .overview },
                    onCurrentDeviceRemoved: {
                        state.showToast("当前设备已停用")
                        route = .overview
                    }
                )
                .environmentObject(state)
            }
        }
        .onAppear(perform: openPendingRecoveryIfNeeded)
        .onChange(of: state.pendingLicenseRecoveryToken) { _, token in
            if token != nil {
                openPendingRecoveryIfNeeded()
            }
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
            if needsKeychainRepair {
                licenseActionRow("钥匙串访问", detail: "执行一次修复，保留原设备身份和激活状态。") {
                    Button(isRepairingKeychain ? "修复中" : "修复访问") {
                        repairKeychainAccess()
                    }
                    .buttonStyle(CapsuleButtonStyle(filled: true))
                    .disabled(isRepairingKeychain)
                }
            }
            licenseActionRow("激活码", detail: "输入购买邮箱和激活码。") {
                Button("激活") {
                    route = .activation(recoveryToken: nil)
                }
                .buttonStyle(CapsuleButtonStyle(filled: true))
                .disabled(needsKeychainRepair)
            }
            licenseActionRow("刷新授权", detail: refreshActionDetail) {
                Button(isRefreshing ? "刷新中" : "刷新") {
                    Task { await refresh() }
                }
                .buttonStyle(CapsuleButtonStyle())
                .disabled(isRefreshing || !hasDeviceLicense)
            }
            licenseActionRow("当前设备", detail: currentDeviceActionDetail) {
                Button(isDeactivating ? "停用中" : "停用设备") {
                    confirmsCurrentDeviceDeactivation = true
                }
                .buttonStyle(CapsuleButtonStyle())
                .disabled(isDeactivating || !hasDeviceLicense)
            }
            licenseActionRow("激活设备", detail: deviceManagementActionDetail) {
                Button("管理设备") {
                    route = .devices
                }
                .buttonStyle(CapsuleButtonStyle(filled: hasDeviceLicense))
                .disabled(!hasDeviceLicense)
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

    private var hasDeviceLicense: Bool {
        currentCertificate != nil
    }

    private var needsKeychainRepair: Bool {
        state.licenseManager.state == .limited(reason: .keychainAccessRequired)
    }

    private var refreshActionDetail: String {
        hasDeviceLicense ? "联网更新本机 30 天证书。" : "激活后可联网刷新本机证书。"
    }

    private var currentDeviceActionDetail: String {
        hasDeviceLicense ? "停用后会释放一个设备席位。" : "试用状态未绑定设备席位。"
    }

    private var deviceManagementActionDetail: String {
        hasDeviceLicense ? "查看、重命名或移除已激活设备。" : "激活后可查看、重命名或移除设备。"
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
            message = nil
            state.showToast("授权已刷新")
        } catch {
            message = error.localizedDescription
        }
    }

    private func repairKeychainAccess() {
        isRepairingKeychain = true
        defer { isRepairingKeychain = false }
        do {
            try state.licenseManager.repairKeychainAccess()
            message = nil
            state.showToast("License 钥匙串访问已恢复")
        } catch {
            message = error.localizedDescription
        }
    }

    private func deactivate() async {
        isDeactivating = true
        defer { isDeactivating = false }
        do {
            try await state.licenseManager.deactivateCurrentDevice()
            message = nil
            state.showToast("当前设备已停用")
        } catch {
            message = error.localizedDescription
        }
    }

    private func openPendingRecoveryIfNeeded() {
        guard let token = state.consumePendingLicenseRecoveryToken() else { return }
        route = .activation(recoveryToken: token)
    }
}

struct ActivationSheetView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var viewModel = ActivationViewModel()
    let recoveryToken: String?
    let onClose: () -> Void
    let onActivated: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    formPanel
                    if !viewModel.replacementDevices.isEmpty {
                        replacementPanel
                    }
                    statusPanel
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                securityPanel
                    .frame(width: 250)
            }
            actionBar
        }
        .foregroundStyle(StudioColor.text)
        .task {
            if let recoveryToken {
                viewModel.beginRecovery(token: recoveryToken)
            }
        }
    }

    private var hero: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(StudioColor.panelRaised)
                .frame(width: 42, height: 42)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(StudioColor.hairline, lineWidth: 1)
                )
            Image(systemName: "key.fill")
                .font(StudioFont.symbol(18, weight: .semibold))
                .foregroundStyle(StudioColor.secondaryText)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(StudioFont.symbol(12, weight: .semibold))
            }
            .buttonStyle(IconCircleButtonStyle())
            .help("返回授权概览")

            hero
            VStack(alignment: .leading, spacing: 5) {
                Text(viewModel.isRecoveryActivation ? "恢复 PromptStudio 授权" : "激活 PromptStudio Pro")
                    .font(StudioFont.font(18, weight: .semibold))
                    .foregroundStyle(StudioColor.text)
                Text(viewModel.isRecoveryActivation ? "使用邮件中的一次性凭证在当前设备继续。" : "使用购买邮箱与激活码绑定当前设备。")
                    .font(StudioFont.font(13))
                    .foregroundStyle(StudioColor.secondaryText)
            }
            Spacer()
        }
    }

    private var formPanel: some View {
        VStack(spacing: 0) {
            if viewModel.isRecoveryActivation {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "envelope.badge.shield.half.filled")
                        .font(StudioFont.symbol(20, weight: .medium))
                        .foregroundStyle(StudioColor.blue)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("恢复凭证已载入")
                            .font(StudioFont.font(14, weight: .semibold))
                        Text("凭证只用于本次设备授权，成功后立即失效。")
                            .font(StudioFont.font(12))
                            .foregroundStyle(StudioColor.secondaryText)
                    }
                    Spacer()
                }
                .padding(16)
            } else {
                VStack(spacing: 14) {
                    fields
                }
                .padding(16)

                Divider().overlay(StudioColor.hairline)

                recoveryRow
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .background(StudioColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(StudioColor.hairline, lineWidth: 1))
    }

    private var fields: some View {
        VStack(spacing: 14) {
            ActivationInputField(
                title: "购买邮箱",
                placeholder: "请输入购买时使用的邮箱",
                systemImage: "envelope",
                text: $viewModel.email,
                textContentType: .emailAddress,
                disabled: inputsDisabled
            )

            ActivationInputField(
                title: "激活码",
                placeholder: "请输入激活码",
                systemImage: "key",
                text: $viewModel.licenseCode,
                textContentType: .oneTimeCode,
                disabled: inputsDisabled,
                monospaced: true
            )
        }
    }

    private var primaryAction: some View {
        Button {
            Task {
                if await viewModel.activate(using: state.licenseManager) {
                    onActivated()
                }
            }
        } label: {
            HStack(spacing: 9) {
                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.74)
                }
                Text(primaryButtonTitle)
                    .font(StudioFont.font(15, weight: .semibold))
            }
            .foregroundStyle(primaryButtonTextColor)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(Capsule().fill(primaryButtonColor))
            .overlay(Capsule().stroke(primaryButtonBorderColor, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(primaryButtonDisabled)
    }

    private var recoveryRow: some View {
        HStack(spacing: 8) {
            Button {
                Task { await viewModel.recover(using: state.licenseManager) }
            } label: {
                Label("找回激活码", systemImage: "arrow.counterclockwise")
                    .font(StudioFont.font(13, weight: .medium))
                    .frame(height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(viewModel.canRecover ? StudioColor.secondaryText : StudioColor.mutedText)
            .disabled(!viewModel.canRecover)

            Spacer()

            Text("忘记激活码？可通过购买邮箱提交恢复请求。")
                .font(StudioFont.font(12))
                .foregroundStyle(StudioColor.mutedText)
        }
    }

    private var statusPanel: some View {
        HStack(alignment: .center, spacing: 12) {
            statusIcon
                .frame(width: 18, height: 18)
            Text(statusMessage)
                .font(StudioFont.font(13, weight: statusWeight))
                .foregroundStyle(statusForeground)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 50)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(statusBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(statusBorder, lineWidth: 1)
        )
    }

    private var footerNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(StudioFont.symbol(12, weight: .medium))
            Text("授权只绑定当前设备，不会上传或改变你的本地素材数据。")
                .font(StudioFont.font(11))
        }
        .foregroundStyle(StudioColor.mutedText)
        .frame(maxWidth: .infinity)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button("返回") { onClose() }
                .buttonStyle(CapsuleButtonStyle())
                .disabled(viewModel.isLoading)
            Spacer()
            primaryAction
                .frame(width: 184)
        }
    }

    private var replacementPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("选择要替换的设备")
                    .font(StudioFont.font(13, weight: .semibold))
                Text("新设备激活成功后，所选设备会立即退出授权。")
                    .font(StudioFont.font(12))
                    .foregroundStyle(StudioColor.secondaryText)
            }
            .padding(16)

            ForEach(viewModel.replacementDevices) { device in
                Button {
                    viewModel.selectedReplacementID = device.activationId
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: viewModel.selectedReplacementID == device.activationId ? "checkmark.circle.fill" : "circle")
                            .font(StudioFont.symbol(16, weight: .medium))
                            .foregroundStyle(viewModel.selectedReplacementID == device.activationId ? StudioColor.blue : StudioColor.tertiaryText)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.deviceLabel)
                                .font(StudioFont.font(13, weight: .medium))
                                .foregroundStyle(StudioColor.text)
                            Text(replacementDeviceDetail(device))
                                .font(StudioFont.font(11))
                                .foregroundStyle(StudioColor.tertiaryText)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(viewModel.selectedReplacementID == device.activationId ? StudioColor.selection : Color.clear)
                .overlay(alignment: .top) {
                    Rectangle().fill(StudioColor.hairline).frame(height: 1)
                }
            }
        }
        .background(StudioColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
    }

    private var securityPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("授权说明", systemImage: "lock.shield")
                .font(StudioFont.font(13, weight: .semibold))
            infoRow("设备绑定", detail: "每个席位对应一台当前激活设备。")
            infoRow("本地资料", detail: "授权服务不会上传或修改资料库内容。")
            infoRow("找回邮件", detail: "一次性链接 15 分钟有效，使用后立即失效。")
            Divider().overlay(StudioColor.hairline)
            Button("购买 PromptStudio Pro") { openPurchasePage() }
                .buttonStyle(TextHoverButtonStyle())
        }
        .padding(16)
        .background(StudioColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
    }

    private func infoRow(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(StudioFont.font(12, weight: .medium))
            Text(detail)
                .font(StudioFont.font(11))
                .foregroundStyle(StudioColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func replacementDeviceDetail(_ device: LicenseReplacementDevice) -> String {
        let lastSeen = device.lastSeenAt ?? device.activatedAt
        return "\(device.platform) · 最近使用 \(lastSeen.formatted(date: .abbreviated, time: .omitted))"
    }

    private func openPurchasePage() {
        if let url = URL(string: "https://promptstudio.app/pricing") {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch viewModel.feedback {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        case .success:
            Image(systemName: "checkmark.circle")
                .font(StudioFont.symbol(17, weight: .medium))
        case .error:
            Image(systemName: "xmark.circle")
                .font(StudioFont.symbol(17, weight: .medium))
        case .info:
            Image(systemName: "info.circle")
                .font(StudioFont.symbol(17, weight: .medium))
        case .idle:
            Image(systemName: "info")
                .font(StudioFont.symbol(15, weight: .medium))
        }
    }

    private var statusMessage: String {
        switch viewModel.feedback {
        case .idle:
            return "输入购买邮箱和激活码后即可激活。"
        case .loading(let message), .success(let message), .info(let message):
            return message
        case .error(let message):
            return message
        }
    }

    private var statusWeight: Font.Weight {
        switch viewModel.feedback {
        case .success:
            .semibold
        default:
            .regular
        }
    }

    private var statusForeground: Color {
        switch viewModel.feedback {
        case .success:
            return Color(hex: 0xE6F8EB)
        case .error:
            return Color(hex: 0xFFBBB5)
        case .loading:
            return Color(hex: 0xB8D2FF)
        case .info:
            return StudioColor.secondaryText
        case .idle:
            return StudioColor.secondaryText
        }
    }

    private var statusBackground: Color {
        switch viewModel.feedback {
        case .success:
            return Color(hex: 0x13271B)
        case .error:
            return Color(hex: 0x2A1717)
        case .loading:
            return Color(hex: 0x17202B)
        case .info, .idle:
            return Color(hex: 0x15181E)
        }
    }

    private var statusBorder: Color {
        switch viewModel.feedback {
        case .success:
            return Color(hex: 0x2E6F43)
        case .error:
            return Color(hex: 0x7A3630)
        case .loading:
            return Color(hex: 0x31445C)
        case .info, .idle:
            return Color(hex: 0x2B323C)
        }
    }

    private var primaryButtonTitle: String {
        if !viewModel.replacementDevices.isEmpty {
            return viewModel.selectedReplacementID == nil ? "请选择设备" : "替换并激活"
        }
        return switch viewModel.feedback {
        case .loading:
            "激活中..."
        case .success:
            "激活成功"
        case .error:
            "重新激活"
        case .idle, .info:
            "立即激活"
        }
    }

    private var primaryButtonColor: Color {
        switch viewModel.feedback {
        case .loading:
            return StudioColor.panelRaised
        case .success:
            return Color(hex: 0xE9F8EF)
        case .idle, .error, .info:
            return primaryButtonDisabled ? StudioColor.control : StudioColor.primaryAction
        }
    }

    private var primaryButtonTextColor: Color {
        switch viewModel.feedback {
        case .loading:
            return Color(hex: 0xD8DEE8)
        case .success:
            return Color(hex: 0x17351F)
        case .idle, .error, .info:
            return primaryButtonDisabled ? StudioColor.mutedText : StudioColor.primaryActionText
        }
    }

    private var primaryButtonBorderColor: Color {
        switch viewModel.feedback {
        case .success:
            return Color(hex: 0xBFE8CA)
        case .loading, .idle, .error, .info:
            return primaryButtonDisabled ? StudioColor.hairline : Color.clear
        }
    }

    private var primaryButtonDisabled: Bool {
        viewModel.isActivated || !viewModel.canConfirmActivation
    }

    private var inputsDisabled: Bool {
        viewModel.isLoading || viewModel.isActivated
    }
}

private struct ActivationInputField: View {
    let title: String
    let placeholder: String
    let systemImage: String
    @Binding var text: String
    let textContentType: NSTextContentType?
    let disabled: Bool
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(StudioFont.font(13, weight: .medium))
                .foregroundStyle(StudioColor.secondaryText)

            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(StudioFont.symbol(16, weight: .medium))
                    .foregroundStyle(disabled ? StudioColor.mutedText : StudioColor.secondaryText)
                    .frame(width: 18)

                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .textContentType(textContentType)
                    .font(monospaced ? .system(size: 14, weight: .regular, design: .monospaced) : StudioFont.font(14))
                    .foregroundStyle(StudioColor.text)
                    .disabled(disabled)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(disabled ? Color(hex: 0x111419) : Color(hex: 0x15181D))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color(hex: 0x3B414B), lineWidth: 1)
            )
        }
        .opacity(disabled ? 0.82 : 1)
    }
}

@MainActor
final class LicenseDeviceManagementViewModel: ObservableObject {
    @Published private(set) var deviceList: LicenseDeviceList?
    @Published private(set) var isLoading = false
    @Published private(set) var busyDeviceID: String?
    @Published var editingDeviceID: String?
    @Published var editingLabel = ""
    @Published var message: String?

    var activeDeviceCount: Int {
        deviceList?.activeDeviceCount ?? 0
    }

    var seatLimit: Int {
        deviceList?.seatLimit ?? 0
    }

    func load(using manager: LicenseManager) async {
        isLoading = true
        message = nil
        defer { isLoading = false }
        do {
            deviceList = try await manager.listDevices()
        } catch {
            message = error.localizedDescription
        }
    }

    func beginEditing(_ device: LicenseDevice) {
        editingDeviceID = device.activationId
        editingLabel = device.label
        message = nil
    }

    func cancelEditing() {
        editingDeviceID = nil
        editingLabel = ""
    }

    func renameEditingDevice(using manager: LicenseManager) async -> Bool {
        guard let editingDeviceID else { return false }
        let label = editingLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            message = "设备名称不能为空。"
            return false
        }
        busyDeviceID = editingDeviceID
        message = nil
        defer { busyDeviceID = nil }
        do {
            try await manager.renameDevice(activationId: editingDeviceID, label: label)
            cancelEditing()
            await load(using: manager)
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func deactivate(_ device: LicenseDevice, using manager: LicenseManager) async -> LicenseDeviceRemovalResult {
        busyDeviceID = device.activationId
        message = nil
        defer { busyDeviceID = nil }
        do {
            try await manager.deactivateDevice(activationId: device.activationId)
            if device.isCurrent {
                return .current
            }
            await load(using: manager)
            return .other
        } catch {
            message = error.localizedDescription
            return .failed
        }
    }

    func isBusy(_ device: LicenseDevice) -> Bool {
        isLoading || busyDeviceID == device.activationId
    }
}

enum LicenseDeviceRemovalResult {
    case current
    case other
    case failed
}

struct LicenseDeviceManagementSheet: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var viewModel = LicenseDeviceManagementViewModel()
    @State private var pendingRemoval: LicenseDevice?
    let onClose: () -> Void
    let onCurrentDeviceRemoved: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            deviceSummary
            deviceListContent
            HStack {
                Text("设备变更会立即同步到授权服务，不影响本地资料。")
                    .font(StudioFont.font(11))
                    .foregroundStyle(StudioColor.tertiaryText)
                Spacer()
                Button("增加设备席位") { openPurchasePage() }
                    .buttonStyle(TextHoverButtonStyle())
            }
        }
        .foregroundStyle(StudioColor.text)
        .task {
            await viewModel.load(using: state.licenseManager)
        }
        .confirmationDialog(
            "移除设备？",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingRemoval = nil
                    }
                }
            )
        ) {
            if let device = pendingRemoval {
                Button("移除设备", role: .destructive) {
                    Task {
                        let result = await viewModel.deactivate(device, using: state.licenseManager)
                        pendingRemoval = nil
                        switch result {
                        case .current:
                            onCurrentDeviceRemoved()
                        case .other:
                            state.showToast("设备已移除，席位已释放")
                        case .failed:
                            break
                        }
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if pendingRemoval?.isCurrent == true {
                Text("移除当前设备后，本机会退出授权状态。")
            } else {
                Text("移除后该设备会释放一个授权席位。")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(StudioFont.symbol(12, weight: .semibold))
            }
            .buttonStyle(IconCircleButtonStyle())
            .help("返回授权概览")

            VStack(alignment: .leading, spacing: 5) {
                Text("管理激活设备")
                    .font(StudioFont.font(18, weight: .semibold))
                Text("重命名设备或释放不再使用的席位。")
                    .font(StudioFont.font(13))
                    .foregroundStyle(StudioColor.secondaryText)
            }

            Spacer()

            Button {
                Task { await viewModel.load(using: state.licenseManager) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(StudioFont.symbol(12, weight: .semibold))
            }
            .buttonStyle(IconCircleButtonStyle())
            .disabled(viewModel.isLoading)
            .help("刷新设备列表")
        }
    }

    private var deviceSummary: some View {
        HStack(spacing: 14) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(StudioFont.symbol(22, weight: .medium))
                .foregroundStyle(StudioColor.blue)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 8).fill(StudioColor.control))
            VStack(alignment: .leading, spacing: 4) {
                Text("已使用 \(viewModel.activeDeviceCount) / \(viewModel.seatLimit) 个席位")
                    .font(StudioFont.font(14, weight: .semibold))
                Text(viewModel.activeDeviceCount < viewModel.seatLimit ? "仍有可用席位。" : "席位已用满，可移除旧设备后再激活新设备。")
                    .font(StudioFont.font(12))
                    .foregroundStyle(StudioColor.secondaryText)
            }
            Spacer()
        }
        .padding(16)
        .background(StudioColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
    }

    @ViewBuilder
    private var deviceListContent: some View {
        if viewModel.isLoading && viewModel.deviceList == nil {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("正在加载设备...")
                    .font(StudioFont.font(13))
                    .foregroundStyle(StudioColor.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
            .background(StudioColor.panel)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
        } else if let devices = viewModel.deviceList?.devices, !devices.isEmpty {
            VStack(spacing: 0) {
                ForEach(devices) { device in
                    deviceRow(device)
                    if device.id != devices.last?.id {
                        Rectangle()
                            .fill(StudioColor.hairline)
                            .frame(height: 1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .background(StudioColor.panel)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
            .overlay(alignment: .bottomLeading) {
                if let message = viewModel.message {
                    Text(message)
                        .font(StudioFont.font(12))
                        .foregroundStyle(Color(hex: 0xFFBBB5))
                        .padding(.top, 12)
                        .offset(y: 24)
                }
            }
        } else {
            VStack(spacing: 10) {
                Text("暂无激活设备")
                    .font(StudioFont.font(15, weight: .semibold))
                if let message = viewModel.message {
                    Text(message)
                        .font(StudioFont.font(12))
                        .foregroundStyle(Color(hex: 0xFFBBB5))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 180)
            .background(StudioColor.panel)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
        }
    }

    private func deviceRow(_ device: LicenseDevice) -> some View {
        HStack(spacing: 16) {
            Circle()
                .fill(device.isCurrent ? Color(hex: 0x4AE06D) : Color.white.opacity(0.28))
                .frame(width: 9, height: 9)

            Image(systemName: "apple.logo")
                .font(StudioFont.symbol(18, weight: .regular))
                .foregroundStyle(Color.white.opacity(device.isCurrent ? 0.78 : 0.52))

            VStack(alignment: .leading, spacing: 6) {
                if viewModel.editingDeviceID == device.activationId {
                    TextField("设备名称", text: $viewModel.editingLabel)
                        .textFieldStyle(.plain)
                        .font(StudioFont.font(14, weight: .medium))
                        .foregroundStyle(StudioColor.text)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(Color.black.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.18), lineWidth: 1))
                } else {
                    Text(device.label)
                        .font(StudioFont.font(14, weight: .medium))
                        .foregroundStyle(Color.white.opacity(device.isCurrent ? 0.94 : 0.68))
                        .lineLimit(1)
                }
                Text(deviceSubtitle(device))
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.48))
            }

            Spacer()

            if viewModel.editingDeviceID == device.activationId {
                Button("取消") {
                    viewModel.cancelEditing()
                }
                .buttonStyle(TextHoverButtonStyle())
                Button("保存") {
                    Task {
                        if await viewModel.renameEditingDevice(using: state.licenseManager) {
                            state.showToast("设备名称已更新")
                        }
                    }
                }
                .buttonStyle(CapsuleButtonStyle(filled: true))
                .disabled(viewModel.isBusy(device))
            } else {
                Button {
                    viewModel.beginEditing(device)
                } label: {
                    Image(systemName: "pencil")
                        .font(StudioFont.symbol(12, weight: .medium))
                }
                .buttonStyle(IconCircleButtonStyle())
                .disabled(viewModel.isBusy(device))
                .help("重命名设备")

                Button {
                    pendingRemoval = device
                } label: {
                    Image(systemName: "trash")
                        .font(StudioFont.symbol(12, weight: .medium))
                }
                .buttonStyle(IconCircleButtonStyle())
                .disabled(viewModel.isBusy(device))
                .help("移除设备")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 66)
    }

    private func deviceSubtitle(_ device: LicenseDevice) -> String {
        let date = device.lastSeenAt ?? device.activatedAt
        let prefix = device.lastSeenAt == nil ? "激活" : "最近在线"
        return "\(prefix) \(date.formatted(date: .numeric, time: .shortened))"
    }

    private func openPurchasePage() {
        if let url = URL(string: "https://promptstudio.app/pricing") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct FeatureDeniedSheet: View {
    @EnvironmentObject private var state: AppState
    let decision: FeatureDecision
    @State private var isRefreshing = false
    @State private var isRepairingKeychain = false

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
                case .repairKeychainAccess:
                    Button(isRepairingKeychain ? "修复中" : "修复钥匙串访问") {
                        repairKeychainAccess()
                    }
                    .buttonStyle(CapsuleButtonStyle(filled: true))
                    .disabled(isRepairingKeychain)
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
        case .keychainAccessRequired:
            "key.fill"
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

    private func repairKeychainAccess() {
        isRepairingKeychain = true
        defer { isRepairingKeychain = false }
        do {
            try state.licenseManager.repairKeychainAccess()
            state.modal = nil
            state.showToast("License 钥匙串访问已恢复")
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
