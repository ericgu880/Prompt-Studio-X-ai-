import SwiftUI

struct PetView: View {
    @ObservedObject var coordinator: PetCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if coordinator.machine.state == .asking,
               let imageRequest = coordinator.pendingImageRequest {
                HStack(spacing: 12) {
                    petFace
                    imageConfirmationCard(imageRequest)
                        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                }
                .frame(width: 304, height: 134)
                .padding(8)
            } else if coordinator.machine.state == .asking,
               let request = coordinator.pendingRequest {
                HStack(spacing: 12) {
                    petFace
                    confirmationCard(request)
                        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                }
                .frame(width: 304, height: 134)
                .padding(8)
            } else {
                ZStack(alignment: .top) {
                    petFace
                        .frame(width: 86, height: 86)
                        .padding(.top, 28)
                        .padding(.bottom, 4)
                    if coordinator.machine.state == .success {
                        Label("已保存", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.green.opacity(0.92), in: Capsule())
                            .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
                            .padding(.top, 4)
                            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                            .accessibilityLabel("图片已保存")
                    }
                }
                .frame(width: 102, height: 118)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("隐藏桌宠") { coordinator.hideForSession() }
            Button("暂停网页采集 1 小时") { coordinator.pauseCapture(for: 3_600) }
            Divider()
            Button("打开 PromptStudio") { coordinator.openPromptStudio() }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: coordinator.machine.state)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("PromptStudio 桌宠")
        .accessibilityValue(accessibilityState)
    }

    @ViewBuilder
    private var petFace: some View {
        if let image = PetImageResource.desktopPet() {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 86, height: 86)
                .shadow(color: .black.opacity(0.24), radius: 9, y: 4)
        }
    }

    private func confirmationCard(_ request: PetCaptureRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("采集这段网页文字？")
                .font(.system(size: 12, weight: .semibold))
            Text(request.selectedText.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
            HStack(spacing: 6) {
                Button("取消") { coordinator.cancelPendingCapture() }
                    .buttonStyle(.bordered)
                Button("保存") { coordinator.confirmPendingCapture() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .frame(width: 198, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.15), lineWidth: 1))
    }

    private func imageConfirmationCard(_ request: PetImageCaptureRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let thumbnail = coordinator.pendingImageThumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 24))
                        .frame(width: 46, height: 46)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("采集这张网页图片？")
                        .font(.system(size: 12, weight: .semibold))
                    Text(acquisitionLabel(request.candidate.acquisitionMethod))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(request.candidate.pageTitle.isEmpty ? request.candidate.pageURL : request.candidate.pageTitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text(imageTitle(request))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                Button("取消") { coordinator.cancelPendingImageCapture() }
                    .buttonStyle(.bordered)
                Button("保存") { coordinator.confirmPendingImageCapture() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .frame(width: 198, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.15), lineWidth: 1))
    }

    private func acquisitionLabel(_ value: String) -> String {
        switch value {
        case "screenshot": "截图采集"
        case "extensionFetch": "扩展获取"
        case "loadedBytes": "已加载资源"
        default: "页面上下文"
        }
    }

    private func imageTitle(_ request: PetImageCaptureRequest) -> String {
        let value = request.candidate.altText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { return value }
        let file = request.candidate.originalFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !file.isEmpty { return file }
        return request.candidate.pageTitle.isEmpty ? "网页图片" : request.candidate.pageTitle
    }

    private var accessibilityState: String {
        switch coordinator.machine.state {
        case .idle: "空闲"
        case .asking: "等待确认"
        case .eating: "正在保存"
        case .success: "保存成功"
        case .cancelled: "已取消"
        case .error: "保存失败"
        case .hidden: "已隐藏"
        }
    }
}
