import AppKit
import SwiftUI

struct LicenseSettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var isActivationPresented = false
    @State private var isDeviceManagementPresented = false
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
        .sheet(isPresented: $isDeviceManagementPresented) {
            LicenseDeviceManagementSheet()
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
            licenseActionRow("刷新授权", detail: refreshActionDetail) {
                Button(isRefreshing ? "刷新中" : "刷新") {
                    Task { await refresh() }
                }
                .buttonStyle(CapsuleButtonStyle())
                .disabled(isRefreshing || !hasDeviceLicense)
            }
            licenseActionRow("当前设备", detail: currentDeviceActionDetail) {
                Button(isDeactivating ? "停用中" : "停用设备") {
                    Task { await deactivate() }
                }
                .buttonStyle(CapsuleButtonStyle())
                .disabled(isDeactivating || !hasDeviceLicense)
            }
            licenseActionRow("激活设备", detail: deviceManagementActionDetail) {
                Button("管理设备") {
                    isDeviceManagementPresented = true
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
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                VStack(spacing: 18) {
                    hero
                    header
                    fields
                    primaryAction
                    recoveryRow
                }
                .padding(.horizontal, 38)
                .padding(.top, 42)
                .padding(.bottom, 18)

                Rectangle()
                    .fill(StudioColor.hairline)
                    .frame(height: 1)

                statusPanel
                    .padding(.horizontal, 38)
                    .padding(.top, 18)

                Text("授权只绑定当前设备，不会上传或改变你的本地素材数据。")
                    .font(StudioFont.font(11))
                    .foregroundStyle(StudioColor.mutedText)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
                    .padding(.bottom, 20)
            }
            .frame(width: 560)
            .background(
                LinearGradient(
                    colors: [Color(hex: 0x202124), Color(hex: 0x17191D)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.34), lineWidth: 1)
            )

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(StudioFont.symbol(13, weight: .medium))
                    .foregroundStyle(StudioColor.secondaryText)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isLoading)
            .padding(20)
        }
        .padding(1)
        .background(StudioColor.appBackground)
        .foregroundStyle(StudioColor.text)
    }

    private var hero: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 80, height: 80)
                .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
            Image(systemName: "bolt.fill")
                .font(StudioFont.symbol(30, weight: .semibold))
                .foregroundStyle(.white)
            Image(systemName: "sparkle")
                .font(StudioFont.symbol(11, weight: .semibold))
                .foregroundStyle(StudioColor.mutedText)
                .offset(x: -58, y: -12)
            Image(systemName: "sparkle")
                .font(StudioFont.symbol(11, weight: .semibold))
                .foregroundStyle(StudioColor.mutedText)
                .offset(x: 58, y: -8)
            Image(systemName: "sparkles")
                .font(StudioFont.symbol(10, weight: .semibold))
                .foregroundStyle(StudioColor.mutedText.opacity(0.72))
                .offset(x: -76, y: 10)
            Image(systemName: "sparkles")
                .font(StudioFont.symbol(10, weight: .semibold))
                .foregroundStyle(StudioColor.mutedText.opacity(0.72))
                .offset(x: 78, y: 12)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("激活 PromptStudio")
                .font(StudioFont.font(26, weight: .semibold))
                .foregroundStyle(StudioColor.text)
            Text("输入购买邮箱与激活码，完成授权后解锁 Pro 功能。")
                .font(StudioFont.font(14))
                .foregroundStyle(StudioColor.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    private var fields: some View {
        VStack(spacing: 16) {
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
        .padding(.top, 8)
    }

    private var primaryAction: some View {
        Button {
            Task {
                if await viewModel.activate(using: state.licenseManager) {
                    try? await Task.sleep(for: .milliseconds(800))
                    dismiss()
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
            .frame(height: 54)
            .background(Capsule().fill(primaryButtonColor))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(primaryButtonDisabled)
        .padding(.top, 4)
    }

    private var recoveryRow: some View {
        HStack(spacing: 8) {
            Button {
                Task { await viewModel.recover(using: state.licenseManager) }
            } label: {
                Label("找回激活码", systemImage: "arrow.counterclockwise")
                    .font(StudioFont.font(13, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(viewModel.canRecover ? StudioColor.secondaryText : StudioColor.mutedText)
            .disabled(!viewModel.canRecover)

            Spacer()

            Text("忘记激活码？可通过购买邮箱提交恢复请求。")
                .font(StudioFont.font(12))
                .foregroundStyle(StudioColor.mutedText)
        }
        .frame(height: 24)
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
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(statusBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(statusBorder, lineWidth: 1)
        )
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
        switch viewModel.feedback {
        case .loading:
            "激活中..."
        case .success:
            "正在进入 PromptStudio..."
        case .error:
            "重新激活"
        case .idle, .info:
            "立即激活"
        }
    }

    private var primaryButtonColor: Color {
        switch viewModel.feedback {
        case .loading:
            return Color(hex: 0x3A414B)
        case .success:
            return Color(hex: 0xE9F8EF)
        case .idle, .error, .info:
            return primaryButtonDisabled ? Color(hex: 0x4A4E55) : StudioColor.primaryAction
        }
    }

    private var primaryButtonTextColor: Color {
        switch viewModel.feedback {
        case .loading:
            return Color(hex: 0xD8DEE8)
        case .success:
            return Color(hex: 0x17351F)
        case .idle, .error, .info:
            return primaryButtonDisabled ? Color(hex: 0xAEB4BD) : StudioColor.primaryActionText
        }
    }

    private var primaryButtonDisabled: Bool {
        viewModel.isActivated || !viewModel.canSubmit
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

    func renameEditingDevice(using manager: LicenseManager) async {
        guard let editingDeviceID else { return }
        let label = editingLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            message = "设备名称不能为空。"
            return
        }
        busyDeviceID = editingDeviceID
        message = nil
        defer { busyDeviceID = nil }
        do {
            try await manager.renameDevice(activationId: editingDeviceID, label: label)
            cancelEditing()
            await load(using: manager)
        } catch {
            message = error.localizedDescription
        }
    }

    func deactivate(_ device: LicenseDevice, using manager: LicenseManager) async -> Bool {
        busyDeviceID = device.activationId
        message = nil
        defer { busyDeviceID = nil }
        do {
            try await manager.deactivateDevice(activationId: device.activationId)
            if device.isCurrent {
                return true
            }
            await load(using: manager)
            return false
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func isBusy(_ device: LicenseDevice) -> Bool {
        isLoading || busyDeviceID == device.activationId
    }
}

struct LicenseDeviceManagementSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = LicenseDeviceManagementViewModel()
    @State private var pendingRemoval: LicenseDevice?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                header
                    .padding(.top, 36)
                    .padding(.horizontal, 42)
                    .padding(.bottom, 24)

                deviceListContent
                    .padding(.horizontal, 42)
                    .padding(.bottom, 30)
            }
            .frame(width: 820, height: 620)
            .background(Color(hex: 0x32363A))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(StudioFont.symbol(20, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.76))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .padding(22)
        }
        .background(StudioColor.appBackground)
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
                        let removedCurrent = await viewModel.deactivate(device, using: state.licenseManager)
                        pendingRemoval = nil
                        if removedCurrent {
                            dismiss()
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
        VStack(spacing: 18) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "desktopcomputer")
                    .font(StudioFont.symbol(100, weight: .ultraLight))
                    .foregroundStyle(Color.white.opacity(0.22))
                Image(systemName: "laptopcomputer")
                    .font(StudioFont.symbol(70, weight: .ultraLight))
                    .foregroundStyle(Color.white.opacity(0.28))
                    .offset(x: 56, y: 18)
            }
            .frame(height: 118)
            .padding(.trailing, 40)

            Text("激活设备管理 (\(viewModel.activeDeviceCount)/\(viewModel.seatLimit))")
                .font(StudioFont.font(30, weight: .semibold))

            HStack(spacing: 0) {
                Text("当前序列号可以授权 \(viewModel.seatLimit) 台设备，如需扩增你原购买的序列号授权数，请 ")
                    .foregroundStyle(Color.white.opacity(0.62))
                Button("扩增授权数") {
                    openPurchasePage()
                }
                .buttonStyle(.plain)
                .foregroundStyle(StudioColor.blue)
                Text("。")
                    .foregroundStyle(Color.white.opacity(0.62))
            }
            .font(StudioFont.font(17))
        }
        .frame(maxWidth: .infinity)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let devices = viewModel.deviceList?.devices, !devices.isEmpty {
            VStack(spacing: 0) {
                ForEach(devices) { device in
                    deviceRow(device)
                    if device.id != devices.last?.id {
                        Rectangle()
                            .fill(Color.white.opacity(0.10))
                            .frame(height: 1)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .bottomLeading) {
                if let message = viewModel.message {
                    Text(message)
                        .font(StudioFont.font(12))
                        .foregroundStyle(Color(hex: 0xFFBBB5))
                        .padding(.top, 12)
                        .offset(y: 26)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func deviceRow(_ device: LicenseDevice) -> some View {
        HStack(spacing: 16) {
            Circle()
                .fill(device.isCurrent ? Color(hex: 0x4AE06D) : Color.white.opacity(0.28))
                .frame(width: 12, height: 12)

            Image(systemName: "apple.logo")
                .font(StudioFont.symbol(24, weight: .regular))
                .foregroundStyle(Color.white.opacity(device.isCurrent ? 0.78 : 0.52))

            VStack(alignment: .leading, spacing: 6) {
                if viewModel.editingDeviceID == device.activationId {
                    TextField("设备名称", text: $viewModel.editingLabel)
                        .textFieldStyle(.plain)
                        .font(StudioFont.font(19, weight: .medium))
                        .foregroundStyle(StudioColor.text)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(Color.black.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.18), lineWidth: 1))
                } else {
                    Text(device.label)
                        .font(StudioFont.font(19, weight: .medium))
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
                    Task { await viewModel.renameEditingDevice(using: state.licenseManager) }
                }
                .buttonStyle(CapsuleButtonStyle(filled: true))
                .disabled(viewModel.isBusy(device))
            } else {
                Button {
                    viewModel.beginEditing(device)
                } label: {
                    Image(systemName: "pencil")
                        .font(StudioFont.symbol(19, weight: .regular))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white.opacity(0.56))
                .disabled(viewModel.isBusy(device))

                Button {
                    pendingRemoval = device
                } label: {
                    Image(systemName: "trash")
                        .font(StudioFont.symbol(20, weight: .regular))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white.opacity(0.56))
                .disabled(viewModel.isBusy(device))
            }
        }
        .frame(height: 72)
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
