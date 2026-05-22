import SwiftUI

@main
struct PromptStudioApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            PromptStudioView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1180, minHeight: 760)
                .background(WindowStartupConfigurator())
                .task {
                    if appState.items.isEmpty {
                        appState.load()
                    }
                }
        }
        .defaultSize(width: 1440, height: 1024)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("新建 Prompt") { appState.modal = .newPrompt }
                    .keyboardShortcut("n", modifiers: .command)
                Button("导入素材") { appState.modal = .importAssets }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }

            CommandGroup(after: .pasteboard) {
                Button("复制提示词") { appState.copySelectedPrompt() }
                    .keyboardShortcut("c", modifiers: .command)
                Button("编辑 Prompt") { appState.modal = .editPrompt }
                    .keyboardShortcut("e", modifiers: .command)
            }

            CommandGroup(after: .sidebar) {
                Button("网格视图") { appState.isListView = false }
                    .keyboardShortcut("1", modifiers: .command)
                Button("列表视图") { appState.isListView = true }
                    .keyboardShortcut("2", modifiers: .command)
                Button("预览") { appState.togglePreview() }
                    .keyboardShortcut(.space, modifiers: [])
            }

            CommandGroup(after: .appSettings) {
                Button("设置") { appState.modal = .settings }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

private struct WindowStartupConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.configure(window: nsView.window)
        }
    }

    final class Coordinator {
        private var didConfigure = false

        @MainActor
        func configure(window: NSWindow?) {
            guard !didConfigure, let window else { return }
            didConfigure = true
            window.minSize = NSSize(width: 1180, height: 760)
            window.setContentSize(NSSize(width: 1440, height: 1024))
            window.center()
        }
    }
}
