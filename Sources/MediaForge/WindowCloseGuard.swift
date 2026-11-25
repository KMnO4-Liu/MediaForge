import AppKit
import SwiftUI

/// Ask before a running job's window closes, not after the last window has disappeared.
/// Preserve SwiftUI's own window delegate by forwarding every other delegate method.
struct WindowCloseGuard: NSViewRepresentable {
    let store: AppStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.onWindow = { [weak coordinator = context.coordinator] window in coordinator?.attach(to: window) }
        return view
    }

    func updateNSView(_ nsView: WindowObserverView, context: Context) {
        if let window = nsView.window { context.coordinator.attach(to: window) }
    }

    final class WindowObserverView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private weak var store: AppStore?
        private var originalDelegate: NSWindowDelegate?

        init(store: AppStore) { self.store = store }

        func attach(to window: NSWindow) {
            guard window.delegate !== self else { return }
            originalDelegate = window.delegate
            window.delegate = self
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (originalDelegate?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if originalDelegate?.responds(to: selector) == true { return originalDelegate }
            return super.forwardingTarget(for: selector)
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard let store, store.isRunning else {
                return originalDelegate?.windowShouldClose?(sender) ?? true
            }
            let alert = NSAlert()
            alert.messageText = "转换正在进行"
            alert.informativeText = "窗口会保持打开，以便查看进度。可以继续等待，或停止转换后再关闭窗口。"
            alert.addButton(withTitle: "继续转换")
            alert.addButton(withTitle: "停止转换")
            if alert.runModal() == .alertSecondButtonReturn { store.stop() }
            return false
        }
    }
}
