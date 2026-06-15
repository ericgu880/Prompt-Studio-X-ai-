import AppKit
import SwiftUI

@main
struct PromptStudioApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(PromptStudioAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("PromptStudio", id: "main") {
            PromptStudioView()
                .environmentObject(appState)
                .environment(\.font, StudioFont.body())
                .preferredColorScheme(.dark)
                .frame(minWidth: 1180, minHeight: 720)
                .background(WindowStartupConfigurator())
                .onAppear {
                    appDelegate.appState = appState
                }
                .task {
                    if appState.items.isEmpty {
                        appState.load()
                    }
                    await appState.licenseManager.refreshIfNeeded()
                }
                .onOpenURL { url in
                    appDelegate.appState = appState
                    WindowStartupConfigurator.showMainWindow()
                    appState.handleExternalFileOpen([url])
                    WindowStartupConfigurator.closeDuplicateMainWindows()
                }
        }
        .defaultSize(width: WindowStartupConfigurator.defaultContentSize.width, height: WindowStartupConfigurator.defaultContentSize.height)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("返回上一步") {
                    AppShortcutRouter.performUndoOrBack(appState)
                }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!AppShortcutRouter.canPerformUndoOrBack(appState))

                Button("前进一步") {
                    AppShortcutRouter.performRedoOrForward(appState)
                }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!AppShortcutRouter.canPerformRedoOrForward(appState))
            }

            CommandGroup(after: .newItem) {
                Button("新建 Prompt") { appState.openNewPromptComposer() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("导入素材") { appState.openImportAssets() }
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
                Button("高级筛选") { appState.openAdvancedFilters() }
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
                Button("设置") { appState.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
private final class PromptStudioAppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState? {
        didSet {
            flushPendingURLs()
        }
    }

    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        enqueueExternalOpen(urls: [URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        enqueueExternalOpen(urls: urls)
        sender.reply(toOpenOrPrint: .success)
    }

    @objc private func handleOpenDocuments(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let directObject = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        enqueueExternalOpen(urls: fileURLs(from: directObject))
    }

    private func fileURLs(from descriptor: NSAppleEventDescriptor) -> [URL] {
        if descriptor.numberOfItems > 0 {
            return (1...descriptor.numberOfItems).compactMap { index in
                guard let item = descriptor.atIndex(index) else { return nil }
                return fileURL(from: item)
            }
        }
        return fileURL(from: descriptor).map { [$0] } ?? []
    }

    private func fileURL(from descriptor: NSAppleEventDescriptor) -> URL? {
        if let url = descriptor.fileURLValue {
            return url
        }
        if let path = descriptor.stringValue, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private func enqueueExternalOpen(urls: [URL]) {
        guard !urls.isEmpty else { return }
        WindowStartupConfigurator.showMainWindow()
        if let appState {
            appState.handleExternalFileOpen(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
        WindowStartupConfigurator.closeDuplicateMainWindows()
    }

    private func flushPendingURLs() {
        guard let appState, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs.removeAll()
        WindowStartupConfigurator.showMainWindow()
        appState.handleExternalFileOpen(urls)
        WindowStartupConfigurator.closeDuplicateMainWindows()
    }
}

private struct WindowStartupConfigurator: NSViewRepresentable {
    static let defaultContentSize = NSSize(width: 1440, height: 900)
    static let minimumContentSize = NSSize(width: 1180, height: 720)
    @MainActor private static weak var mainWindow: NSWindow?

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
            guard WindowStartupConfigurator.registerMainWindow(window) else { return }
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

    @MainActor
    private static func registerMainWindow(_ window: NSWindow) -> Bool {
        if let mainWindow, mainWindow !== window {
            window.close()
            showMainWindow()
            return false
        }
        mainWindow = window
        closeDuplicateMainWindows()
        return true
    }

    @MainActor
    static func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if mainWindow == nil {
            mainWindow = NSApp.windows.first { isPromptStudioMainWindow($0) }
        }
        closeDuplicateMainWindows()
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            NSApp.windows.first { !$0.isMiniaturized }?.makeKeyAndOrderFront(nil)
        }
    }

    @MainActor
    static func closeDuplicateMainWindows() {
        guard let mainWindow else { return }
        for window in NSApp.windows where window !== mainWindow && isPromptStudioMainWindow(window) {
            window.close()
        }
    }

    @MainActor
    private static func isPromptStudioMainWindow(_ window: NSWindow) -> Bool {
        window.sheetParent == nil
            && !window.isMiniaturized
            && window.contentView != nil
            && window.styleMask.contains(.closable)
            && window.styleMask.contains(.resizable)
    }
}
