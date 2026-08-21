import PromptStudioCore
import SwiftUI

struct BatchImportProgressOverlay: View {
    @ObservedObject var state: ImportProgressState
    let onDismiss: () -> Void

    var body: some View {
        if let progress = state.progress {
            VStack {
                HStack {
                    Spacer()
                    BatchImportProgressView(
                        progress: progress,
                        failures: state.failures,
                        onDismiss: onDismiss
                    )
                }
                Spacer()
            }
            .padding(.top, 50)
            .padding(.trailing, 22)
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(70)
        }
    }
}

struct BatchImportProgressView: View {
    let progress: MediaImportProgress
    let failures: [MediaImportFailure]
    let onDismiss: () -> Void

    @State private var showsFailures = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                phaseIcon

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(StudioFont.font(13, weight: .semibold))
                        .foregroundStyle(StudioColor.text)

                    if let detail {
                        Text(detail)
                            .font(StudioFont.font(11))
                            .foregroundStyle(StudioColor.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 12)

                if progress.phase == .completed {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StudioColor.secondaryText)
                    .accessibilityLabel("关闭导入状态")
                }
            }

            if progress.phase != .completed {
                if let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(StudioColor.primaryAction)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if progress.phase == .completed, !failures.isEmpty {
                Button {
                    showsFailures.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showsFailures ? "chevron.down" : "chevron.right")
                        Text("查看 \(failures.count) 个失败项目")
                    }
                    .font(StudioFont.font(11, weight: .medium))
                    .foregroundStyle(StudioColor.primaryAction)
                }
                .buttonStyle(.plain)

                if showsFailures {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(failure.fileName)
                                        .font(StudioFont.font(11, weight: .semibold))
                                        .foregroundStyle(StudioColor.text)
                                    Text(failure.reason)
                                        .font(StudioFont.font(10))
                                        .foregroundStyle(StudioColor.secondaryText)
                                    Text(failure.path)
                                        .font(StudioFont.font(9))
                                        .foregroundStyle(StudioColor.tertiaryText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                }
            }
        }
        .padding(14)
        .frame(width: 330, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(StudioColor.panel.opacity(0.98))
                .shadow(color: Color.black.opacity(0.24), radius: 14, y: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(StudioColor.hairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var phaseIcon: some View {
        if progress.phase == .completed {
            Image(systemName: failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(failures.isEmpty ? Color.green : Color.orange)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private var title: String {
        switch progress.phase {
        case .scanning: "正在扫描文件…"
        case .preparing: "正在准备导入…"
        case .importing:
            if let total = progress.total {
                "正在导入 \(progress.current) / \(total)"
            } else {
                "正在导入…"
            }
        case .saving: "正在保存到资料库…"
        case .completed:
            failures.isEmpty
                ? "已导入 \(progress.successCount) 个素材"
                : "成功导入 \(progress.successCount) 个，\(progress.failureCount) 个失败"
        }
    }

    private var detail: String? {
        if let fileName = progress.currentFileName, !fileName.isEmpty {
            return fileName
        }
        if progress.phase == .completed, !failures.isEmpty {
            return "其他素材已正常保存"
        }
        return nil
    }
}
