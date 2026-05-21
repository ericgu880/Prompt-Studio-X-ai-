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
                .task {
                    if appState.items.isEmpty {
                        appState.load()
                    }
                }
        }
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
                Button("预览") { appState.previewSelected() }
                    .keyboardShortcut(.space, modifiers: [])
            }

            CommandGroup(after: .appSettings) {
                Button("设置") { appState.modal = .settings }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
