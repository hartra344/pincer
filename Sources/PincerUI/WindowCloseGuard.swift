#if os(macOS)
import AppKit
import SwiftUI

/// Asks before its window closes (close button, ⌘W) while `shouldBlock` is true: calls
/// `onBlocked` instead, and hands back a `closer` that closes without asking. Wraps the window's
/// existing delegate, forwarding everything else to it.
struct WindowCloseGuard: NSViewRepresentable {
    let shouldBlock: @MainActor () -> Bool
    let onBlocked: @MainActor () -> Void
    @Binding var closer: (() -> Void)?

    func makeNSView(context: Context) -> GuardView {
        let view = GuardView()
        view.configure(self)
        return view
    }

    func updateNSView(_ view: GuardView, context: Context) {
        view.configure(self)
    }

    final class GuardView: NSView {
        private var proxy: CloseProxy?
        private var shouldBlock: @MainActor () -> Bool = { false }
        private var onBlocked: @MainActor () -> Void = {}
        private var setCloser: ((() -> Void)?) -> Void = { _ in }

        func configure(_ guardian: WindowCloseGuard) {
            self.shouldBlock = guardian.shouldBlock
            self.onBlocked = guardian.onBlocked
            self.setCloser = { guardian.closer = $0 }
            self.proxy?.shouldBlock = { [weak self] in self?.shouldBlock() ?? false }
            self.proxy?.onBlocked = { [weak self] in self?.onBlocked() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, self.proxy?.window !== window else { return }
            let proxy = CloseProxy(window: window, original: window.delegate)
            proxy.shouldBlock = { [weak self] in self?.shouldBlock() ?? false }
            proxy.onBlocked = { [weak self] in self?.onBlocked() }
            window.delegate = proxy
            self.proxy = proxy
            let setCloser = self.setCloser
            DispatchQueue.main.async {
                setCloser { [weak proxy] in proxy?.closeWithoutAsking() }
            }
        }
    }

    final class CloseProxy: NSObject, NSWindowDelegate {
        weak var window: NSWindow?
        weak var original: NSWindowDelegate?
        var shouldBlock: () -> Bool = { false }
        var onBlocked: () -> Void = {}
        private var bypass = false

        init(window: NSWindow, original: NSWindowDelegate?) {
            self.window = window
            self.original = original
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if !self.bypass, self.shouldBlock() {
                self.onBlocked()
                return false
            }
            return self.original?.windowShouldClose?(sender) ?? true
        }

        func closeWithoutAsking() {
            self.bypass = true
            self.window?.performClose(nil)
            self.bypass = false
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (self.original?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if let original, original.responds(to: selector) { return original }
            return super.forwardingTarget(for: selector)
        }
    }
}
#endif
