import AppKit
import SwiftUI

@main
struct PromptStudioApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            PromptStudioView()
                .environmentObject(appState)
                .environment(\.font, StudioFont.body())
                .preferredColorScheme(.dark)
                .frame(minWidth: 1180, minHeight: 720)
                .background(WindowStartupConfigurator())
                .task {
                    if appState.items.isEmpty {
                        appState.load()
                    }
                }
        }
        .defaultSize(width: WindowStartupConfigurator.defaultContentSize.width, height: WindowStartupConfigurator.defaultContentSize.height)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("新建 Prompt") { appState.openNewPromptComposer() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("导入素材") { appState.modal = .importAssets }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .pasteboard) {
                Button("剪切") {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                }
                    .keyboardShortcut("x", modifiers: .command)
                    .disabled(!AppKitBridge.isTextInputActive())
                Button("复制文件") {
                    if AppKitBridge.isTextInputActive() {
                        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                    } else {
                        appState.copySelectedFileForPasteboard()
                    }
                }
                    .keyboardShortcut("c", modifiers: .command)
                Button("粘贴导入") {
                    if AppKitBridge.isTextInputActive() {
                        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                    } else {
                        appState.pasteFilesFromPasteboard()
                    }
                }
                    .keyboardShortcut("v", modifiers: .command)
                Button("全选") {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
                    .keyboardShortcut("a", modifiers: .command)
                Button("编辑 Prompt") {
                    if let item = appState.selectedItem {
                        appState.requestInlineEdit(item)
                    }
                }
                    .keyboardShortcut("e", modifiers: .command)
            }

            CommandGroup(after: .sidebar) {
                Button("高级筛选") { appState.modal = .filters }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("网格视图") { appState.isListView = false }
                    .keyboardShortcut("1", modifiers: .command)
                Button("列表视图") { appState.isListView = true }
                    .keyboardShortcut("2", modifiers: .command)
                Button("预览") { appState.togglePreview() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("移到回收站") {
                    guard !AppKitBridge.isTextInputActive() else { return }
                    appState.moveSelectedToTrash()
                }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(appState.selectedItem == nil || appState.selectedItem?.isDeleted == true || AppKitBridge.isTextInputActive())
            }

            CommandGroup(after: .appSettings) {
                Button("设置") { appState.modal = .settings }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

private struct WindowStartupConfigurator: NSViewRepresentable {
    static let defaultContentSize = NSSize(width: 1440, height: 900)
    static let minimumContentSize = NSSize(width: 1180, height: 720)

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
            window.isRestorable = false
            applyDefaultWindowFrame(to: window)
        }

        @MainActor
        private func applyDefaultWindowFrame(to window: NSWindow) {
            window.minSize = WindowStartupConfigurator.minimumContentSize
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    Task { @MainActor in
                        window.setContentSize(WindowStartupConfigurator.defaultContentSize)
                        window.center()
                    }
                }
                return
            }
            window.setContentSize(WindowStartupConfigurator.defaultContentSize)
            window.center()
        }
    }
}
