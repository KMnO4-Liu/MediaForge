import AppKit
import Combine
import SwiftUI

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    private var terminationObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.isRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "转换尚未完成，确定退出？"
        alert.informativeText = "当前转换会被取消，未完成的临时文件会被清理。源文件不受影响。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "继续转换")
        alert.addButton(withTitle: "停止并退出")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        terminationObserver = store.$isRunning.filter { !$0 }.prefix(1).sink { _ in
            // Publish occurs before the stored property changes; reply on the next run-loop turn.
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        store.stop()
        return .terminateLater
    }
}

struct MediaForgeApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        Window("MediaForge · 媒体格式转换器", id: "main") {
            ContentView()
                .environmentObject(store)
                .tint(accent)
                .background(WindowCloseGuard(store: store))
                .onAppear { delegate.store = store }
                .onChange(of: store.appearance, initial: true) { _, appearance in
                    NSApp.appearance = appearance.nativeAppearance
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加媒体文件…", action: store.importFiles)
                    .keyboardShortcut("o", modifiers: .command).disabled(store.isRunning || !store.workspace.acceptsFiles)
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { store.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
