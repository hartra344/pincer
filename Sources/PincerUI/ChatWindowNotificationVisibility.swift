#if os(macOS)
import AppKit
import PincerKit
import SwiftUI

/// Native visibility governs notifications; keyboard focus still governs read tracking.
struct ChatWindowNotificationVisibility: NSViewRepresentable {
    let app: AppModel
    let ref: ChatWindowRef

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.configure(app: self.app, ref: self.ref)
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.configure(app: self.app, ref: self.ref)
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.detach() }

    final class ObserverView: NSView {
        let windowID = UUID()
        private var app: AppModel?
        private var ref: ChatWindowRef?
        private weak var observedWindow: NSWindow?
        private weak var closedWindow: NSWindow?
        private var registered = false

        func configure(app: AppModel, ref: ChatWindowRef) {
            if self.app !== app || self.ref != ref {
                self.detach()
                self.app = app
                self.ref = ref
            }
            self.attach()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.attach()
        }

        private func attach() {
            guard self.observedWindow !== self.window else { self.sampleVisibility(); return }
            self.detach()
            guard let window = self.window, window !== self.closedWindow,
                  let app = self.app, let ref = self.ref else { return }
            self.observedWindow = window
            // Register residency first, so the first sample cannot be lost.
            app.chatWindowOpened(ref, windowID: self.windowID)
            self.registered = true
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                center.addObserver(self, selector: #selector(self.visibilityChanged(_:)), name: name, object: window)
            }
            center.addObserver(self, selector: #selector(self.windowClosed(_:)), name: NSWindow.willCloseNotification, object: window)
            self.sampleVisibility()
        }

        /// Notifications request a fresh property sample; their payload never supplies visibility.
        @objc private func visibilityChanged(_ notification: Notification) { self.sampleVisibility() }

        func sampleVisibility() {
            guard self.registered, let window = self.observedWindow, let app = self.app, let ref = self.ref else { return }
            let visible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
            app.chatWindowVisibilityChanged(ref, windowID: self.windowID, isVisible: visible)
        }

        @objc private func windowClosed(_ notification: Notification) {
            self.closedWindow = self.observedWindow
            self.detach()
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            if self.registered, let app = self.app, let ref = self.ref {
                app.chatWindowClosed(ref, windowID: self.windowID)
            }
            self.registered = false
            self.observedWindow = nil
        }
    }
}
#endif
