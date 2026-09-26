#if os(macOS)
import AppKit
import Carbon.HIToolbox
import PincerKit
import SwiftUI

/// A system-wide hotkey through Carbon's `RegisterEventHotKey`, which needs no Accessibility or
/// Input Monitoring permission (unlike global event monitors or event taps).
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    var onPress: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// 'PNCR', so presses of other apps' hotkeys are left alone.
    nonisolated static let signature: OSType = 0x504E_4352

    /// Replaces the registered shortcut; nil just unregisters. Returns Carbon's status
    /// (`eventHotKeyExistsErr` when another app holds the combo).
    @discardableResult
    func register(_ shortcut: HotKeyShortcut?) -> OSStatus {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        guard let shortcut else { return noErr }
        self.installHandler()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr { self.hotKey = ref }
        return status
    }

    private func installHandler() {
        guard self.handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
            // Carbon delivers application events on the main thread.
            MainActor.assumeIsolated { GlobalHotKey.shared.onPress?() }
            return noErr
        }, 1, &spec, nil, &self.handler)
    }
}

/// The floating Quick Capture panel: non-activating, so the app you're in stays frontmost.
final class QuickCapturePanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: QuickCaptureView.width, height: 160),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        self.level = .floating
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.becomesKeyOnlyIfNeeded = false
        self.isFloatingPanel = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = true
        // Still shows while Pincer is hidden (⌘H).
        self.canHide = false
        self.animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Resizes from SwiftUI (the picker opening, the message growing) keep the top edge where it
    /// is, so the panel grows downward instead of creeping up the screen.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(self.topAnchored(frameRect), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        super.setFrame(self.topAnchored(frameRect), display: displayFlag, animate: animateFlag)
    }

    private func topAnchored(_ rect: NSRect) -> NSRect {
        // Only a pure resize: moves (dragging, positioning) change the origin themselves.
        guard self.isVisible, rect.height != self.frame.height, rect.origin.y == self.frame.origin.y else { return rect }
        var rect = rect
        rect.origin.y = self.frame.maxY - rect.height
        return rect
    }

    /// Pincer usually isn't the active app while the panel is up, so the main menu may never see
    /// ⌘C, ⌘V and friends; send the standard editing actions to the first responder directly.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        let action: Selector?
        switch (key, modifiers) {
        case ("x", [.command]): action = #selector(NSText.cut(_:))
        case ("c", [.command]): action = #selector(NSText.copy(_:))
        case ("v", [.command]): action = #selector(NSText.paste(_:))
        case ("a", [.command]): action = #selector(NSResponder.selectAll(_:))
        case ("z", [.command]): action = Selector(("undo:"))
        case ("z", [.command, .shift]): action = Selector(("redo:"))
        default: action = nil
        }
        guard let action else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }

    /// The message field, which gets focus whenever the panel opens.
    var composer: NSTextView? {
        func find(_ view: NSView) -> NSTextView? {
            if let textView = view as? ComposerNSTextView { return textView }
            for subview in view.subviews {
                if let found = find(subview) { return found }
            }
            return nil
        }
        return self.contentView.flatMap(find)
    }
}

/// Owns the global hotkey, its settings, and the Quick Capture panel. One per app.
@MainActor
@Observable
final class QuickCaptureController: NSObject, NSWindowDelegate {
    static let shared = QuickCaptureController()

    private(set) var model: QuickCaptureModel?
    private(set) var isEnabled: Bool
    private(set) var shortcut: HotKeyShortcut
    /// Registration failed (another app holds the combo); shown in Settings.
    private(set) var registrationError: String?
    /// While the Settings recorder listens, so pressing the current combo records it.
    var isSuspended = false {
        didSet { if oldValue != self.isSuspended { self.applyRegistration() } }
    }
    /// Opens the main window when none exists; captured from a SwiftUI view.
    @ObservationIgnored var openWindow: OpenWindowAction?

    let settings = QuickCaptureSettings()
    @ObservationIgnored private var app: AppModel?
    @ObservationIgnored private var panel: QuickCapturePanel?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var mouseUpMonitors: [Any] = []
    @ObservationIgnored private var launched = false

    override private init() {
        self.isEnabled = self.settings.isEnabled
        self.shortcut = self.settings.shortcut
        super.init()
    }

    /// Hooks up the app; the rest happens once launching finishes, with or without a main window.
    func install(app: AppModel) {
        guard self.app == nil else { return }
        self.app = app
        self.model = QuickCaptureModel(app: app)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { QuickCaptureController.shared.launch() }
        }
        // Launching may already have finished by the time the scene is built.
        DispatchQueue.main.async { QuickCaptureController.shared.launch() }
    }

    /// Connects the Gateways and registers the hotkey. Safe to call more than once.
    func launch() {
        guard !self.launched, let app else { return }
        self.launched = true
        app.start()
        GlobalHotKey.shared.onPress = { [weak self] in self?.toggle() }
        self.applyRegistration()
    }

    // MARK: Settings

    var displayShortcut: String? { self.isEnabled ? self.shortcut.displayString : nil }

    /// The Go menu and menu bar item title, with the shortcut while it's on.
    var menuTitle: String { self.displayShortcut.map { "Quick Capture…  \($0)" } ?? "Quick Capture…" }

    func setEnabled(_ enabled: Bool) {
        self.settings.isEnabled = enabled
        self.isEnabled = enabled
        self.applyRegistration()
    }

    func setShortcut(_ shortcut: HotKeyShortcut) {
        self.settings.shortcut = shortcut
        self.settings.isEnabled = true
        self.shortcut = shortcut
        self.isEnabled = true
        self.applyRegistration()
    }

    func reset() {
        self.settings.reset()
        self.shortcut = self.settings.shortcut
        self.isEnabled = self.settings.isEnabled
        self.applyRegistration()
    }

    private func applyRegistration() {
        guard self.launched else { return }
        guard !self.isSuspended, let shortcut = self.settings.activeShortcut else {
            GlobalHotKey.shared.register(nil)
            if !self.isSuspended { self.registrationError = nil }
            return
        }
        let status = GlobalHotKey.shared.register(shortcut)
        switch status {
        case noErr: self.registrationError = nil
        case OSStatus(eventHotKeyExistsErr):
            self.registrationError = "\(shortcut.displayString) is used by another app. Choose another shortcut."
        default:
            self.registrationError = "Couldn’t turn on \(shortcut.displayString) (error \(status))."
        }
    }

    // MARK: Panel

    var isShowing: Bool { self.panel?.isVisible == true }

    /// The hotkey: opens the panel, focuses it if it lost focus, or hides it.
    func toggle() {
        if let panel, panel.isVisible {
            if panel.isKeyWindow {
                self.hide()
            } else {
                panel.makeKeyAndOrderFront(nil)
                self.focusComposer()
            }
            return
        }
        self.show()
    }

    func show() {
        guard let model, let app else { return }
        self.launch()
        model.prepare()
        let panel = self.panel ?? self.makePanel(model: model, app: app)
        panel.contentView?.layoutSubtreeIfNeeded()
        self.position(panel)
        panel.makeKeyAndOrderFront(nil)
        self.installKeyMonitor()
        self.focusComposer()
    }

    /// Hides the panel; the draft stays for next time.
    func hide() {
        self.removeMouseUpMonitors()
        self.model?.closePicker()
        self.panel?.orderOut(nil)
    }

    func focusComposer() {
        DispatchQueue.main.async {
            guard let panel = self.panel, let composer = panel.composer else { return }
            panel.makeFirstResponder(composer)
        }
    }

    /// Lets a SwiftUI field take focus from the message field.
    func clearFocus() {
        self.panel?.makeFirstResponder(nil)
    }

    func send(reveal: Bool) {
        guard let model, model.canSend else { return }
        Task {
            guard await model.send(reveal: reveal) else { return }
            if reveal { self.showMainWindow() }
            self.hide()
        }
    }

    /// Opens the target chat in Pincer without sending.
    func revealTarget() {
        guard let model, model.revealTarget() else { return }
        self.showMainWindow()
        self.hide()
    }

    /// Brings Pincer and its main window forward, opening one if every window was closed.
    func showMainWindow() {
        NSApp.unhide(nil)
        NSApp.activate()
        let main = NSApp.windows.first { window in
            window.identifier?.rawValue.hasPrefix("main") == true && (window.isVisible || window.isMiniaturized)
        }
        if let main {
            if main.isMiniaturized { main.deminiaturize(nil) }
            main.makeKeyAndOrderFront(nil)
        } else if let openWindow {
            openWindow(id: "main")
        } else {
            Self.performNewWindowMenuItem()
        }
    }

    /// Last resort when SwiftUI's `openWindow` was never captured: File › New Window.
    private static func performNewWindowMenuItem() {
        func find(in menu: NSMenu) -> (NSMenu, Int)? {
            for (index, item) in menu.items.enumerated() {
                if item.keyEquivalent == "n", item.keyEquivalentModifierMask == [.command], item.isEnabled, item.action != nil {
                    return (menu, index)
                }
                if let submenu = item.submenu, let found = find(in: submenu) { return found }
            }
            return nil
        }
        if let menu = NSApp.mainMenu, let (owner, index) = find(in: menu) {
            owner.performActionForItem(at: index)
        } else {
            NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
        }
    }

    private func makePanel(model: QuickCaptureModel, app: AppModel) -> QuickCapturePanel {
        let panel = QuickCapturePanel()
        let root = QuickCaptureView(model: model, controller: self)
            .environment(app)
            .themed()
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize]
        panel.contentView = hosting
        panel.delegate = self
        self.panel = panel
        return panel
    }

    /// Centered on the pointer's screen, its top about a fifth of the way down.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        panel.setContentSize(size)
        panel.setFrameTopLeftPoint(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - visible.height * 0.22))
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard self.panel?.isVisible == true else { return }
            // Clicking outside dismisses, keeping the draft. Dragging a file in from Finder also
            // takes key away, so while a button is down wait for the release to decide.
            if NSEvent.pressedMouseButtons != 0 {
                self.awaitMouseUp()
            } else {
                self.hide()
            }
        }
    }

    private func awaitMouseUp() {
        guard self.mouseUpMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        let handler: @MainActor () -> Void = {
            // After the event is handled, so a drop has landed and any click has taken effect.
            DispatchQueue.main.async { QuickCaptureController.shared.mouseReleased() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
            MainActor.assumeIsolated { handler() }
        }) {
            self.mouseUpMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            handler()
            return event
        }) {
            self.mouseUpMonitors.append(local)
        }
    }

    private func mouseReleased() {
        self.removeMouseUpMonitors()
        guard let panel, panel.isVisible, !panel.isKeyWindow else { return }
        if NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) {
            // Released over the panel, e.g. a file dropped in: take focus back.
            panel.makeKeyAndOrderFront(nil)
            self.focusComposer()
        } else {
            self.hide()
        }
    }

    private func removeMouseUpMonitors() {
        for monitor in self.mouseUpMonitors { NSEvent.removeMonitor(monitor) }
        self.mouseUpMonitors = []
    }

    // MARK: Keyboard

    /// Esc, Tab and ⌘-shortcuts reach the panel before its text views get them.
    private func installKeyMonitor() {
        guard self.keyMonitor == nil else { return }
        self.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let controller = QuickCaptureController.shared
            guard let panel = controller.panel, event.window === panel, controller.handle(event, in: panel) else { return event }
            return nil
        }
    }

    private static let digitKeyCodes: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
    /// ⌘-keys that still reach the menus from the panel: Select All, Copy, Paste, Cut, Undo/Redo,
    /// Quit and Settings. Others (⌘K, ⌘[, ⌘1…) would act on the main window behind the user's back.
    private static let passThroughCommandKeys: Set<UInt16> = [0, 8, 9, 7, 6, 12, 43]

    private func handle(_ event: NSEvent, in panel: NSPanel) -> Bool {
        guard let model else { return false }
        // Leave keys alone while an input method is composing text.
        if let textView = panel.firstResponder as? NSTextView, textView.hasMarkedText() { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        switch (event.keyCode, modifiers) {
        case (53, []):
            if model.isPickerOpen { model.closePicker() } else { self.hide() }
            return true
        case (38, [.command]):
            model.togglePicker()
            return true
        case (31, [.command]):
            self.revealTarget()
            return true
        case (_, [.command]) where isReturn:
            if !model.isPickerOpen { self.send(reveal: true) }
            return true
        case (13, [.command]):
            self.hide()
            return true
        case let (code, [.command]) where Self.digitKeyCodes[code] != nil:
            model.pickPinned(Self.digitKeyCodes[code]!)
            return true
        default:
            break
        }
        if model.isPickerOpen {
            switch (event.keyCode, modifiers) {
            case (126, []): model.moveHighlight(by: -1)
            case (125, []): model.moveHighlight(by: 1)
            case (48, []), (48, [.shift]): model.closePicker()
            case (_, []) where isReturn: model.pickHighlighted()
            default: return Self.swallows(event, modifiers)
            }
            return true
        }
        if event.keyCode == 48, modifiers.isEmpty, model.hasGateways {
            model.openPicker()
            return true
        }
        return Self.swallows(event, modifiers)
    }

    private static func swallows(_ event: NSEvent, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.contains(.command) && !self.passThroughCommandKeys.contains(event.keyCode)
    }
}
#endif
