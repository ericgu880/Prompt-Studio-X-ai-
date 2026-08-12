import SwiftUI

struct PetView: View {
    @ObservedObject var coordinator: PetCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            blob
                .overlay(eyes)
                .overlay(mouth)

            if coordinator.machine.state == .asking,
               let request = coordinator.pendingRequest {
                confirmationCard(request)
                    .offset(x: 142, y: 0)
                    .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            }
        }
        .frame(width: 86, height: 86)
        .padding(8)
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

    private var blob: some View {
        Canvas { context, size in
            let phase: CGFloat
            if reduceMotion {
                phase = 0
            } else {
                phase = CGFloat(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4))
            }
            let breathing = reduceMotion ? 1 : 1 + sin(phase * .pi / 2) * 0.018
            let blobSize = min(size.width, size.height) * 0.84 * breathing
            let rect = CGRect(
                x: (size.width - blobSize) / 2,
                y: (size.height - blobSize) / 2,
                width: blobSize,
                height: blobSize
            )
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addCurve(
                to: CGPoint(x: rect.maxX, y: rect.midY),
                control1: CGPoint(x: rect.maxX * 0.78, y: rect.minY),
                control2: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.22)
            )
            path.addCurve(
                to: CGPoint(x: rect.midX, y: rect.maxY),
                control1: CGPoint(x: rect.maxX, y: rect.maxY * 0.82),
                control2: CGPoint(x: rect.maxX * 0.80, y: rect.maxY)
            )
            path.addCurve(
                to: CGPoint(x: rect.minX, y: rect.midY),
                control1: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.maxY),
                control2: CGPoint(x: rect.minX, y: rect.maxY * 0.80)
            )
            path.addCurve(
                to: CGPoint(x: rect.midX, y: rect.minY),
                control1: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.20),
                control2: CGPoint(x: rect.width * 0.22, y: rect.minY)
            )
            path.closeSubpath()

            let fill: Color = coordinator.machine.state == .error ? Color(red: 0.26, green: 0.19, blue: 0.28) : Color(red: 0.12, green: 0.12, blue: 0.16)
            context.fill(path, with: .color(fill))
            context.stroke(path, with: .color(Color.white.opacity(0.10)), lineWidth: 1)
        }
        .frame(width: 86, height: 86)
        .shadow(color: .black.opacity(0.24), radius: 9, y: 4)
    }

    private var eyes: some View {
        HStack(spacing: 12) {
            eye
            eye
        }
        .offset(y: -10)
    }

    private var eye: some View {
        Capsule(style: .continuous)
            .fill(Color.white.opacity(0.94))
            .frame(width: 8, height: coordinator.machine.state == .success ? 10 : 13)
    }

    private var mouth: some View {
        Group {
            switch coordinator.machine.state {
            case .asking:
                Capsule(style: .continuous)
                    .stroke(Color(red: 0.52, green: 0.40, blue: 0.62), lineWidth: 2)
                    .frame(width: 18, height: 10)
            case .eating:
                Circle()
                    .fill(Color(red: 0.52, green: 0.40, blue: 0.62))
                    .frame(width: 13, height: 13)
            case .success:
                Capsule(style: .continuous)
                    .fill(Color(red: 0.52, green: 0.40, blue: 0.62))
                    .frame(width: 21, height: 8)
            case .cancelled:
                Image(systemName: "minus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.52, green: 0.40, blue: 0.62))
            case .error:
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(red: 0.78, green: 0.44, blue: 0.48))
            case .idle, .hidden:
                Capsule(style: .continuous)
                    .fill(Color(red: 0.52, green: 0.40, blue: 0.62))
                    .frame(width: 16, height: 6)
            }
        }
        .offset(y: 11)
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
        .frame(width: 190, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.15), lineWidth: 1))
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
