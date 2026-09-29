import Foundation
import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Keeps the companion on the chat's latest reply showing what the agent is doing (thinking, a
/// tool and its badge, approval, compacting, the success and error poses). Every other row keeps
/// its idle still.
///
/// The chat header already animates the same state, so by default this row holds each state's
/// still pose and its timer only fires when a transient pose expires: one moving avatar per chat.
/// With `animates` on, it would step frames at the pose's low frame rate, only while the avatar is
/// on screen, its window visible, the app active and Reduce Motion off.
@MainActor
final class TranscriptLiveAvatar {
    /// Whether the row moves too, rather than leaving the motion to the header.
    static let animates = false

    private weak var chat: ChatStore?
    /// The latest reply's row.
    private var rowId: String?
    /// Avatar views by the row they show, so the live one is found when the latest row changes.
    private let views = NSMapTable<NSString, TranscriptAvatarView>.strongToWeakObjects()
    private weak var live: TranscriptAvatarView?
    private var signals = AvatarSignals.idle
    private var state = AvatarState.idle
    /// When `state` began, for the one-shot hop and wobble.
    private var since = Date.distantPast
    private var timer: Timer?
    /// The frame last drawn, so ticks that land on the same pose don't redraw.
    private var lastFrame: (state: AvatarState, pose: AvatarPose?)?
    private weak var lastView: TranscriptAvatarView?
    private var observers: [NSObjectProtocol] = []
    private var observing = false

    init() {
        #if os(macOS)
        let center = NotificationCenter.default
        self.observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil,
                                                 queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            })
        self.observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        })
        #else
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
                     UIAccessibility.reduceMotionStatusDidChangeNotification]
        {
            self.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            })
        }
        #endif
    }

    isolated deinit {
        self.timer?.invalidate()
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
            #if os(macOS)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            #endif
        }
    }

    func update(chat: ChatStore?) {
        guard chat !== self.chat || !self.observing else { return }
        self.chat = chat
        self.observe()
    }

    /// A row's avatar view was configured. `style` is nil when it shows the classic initial.
    func attach(_ view: TranscriptAvatarView, rowId: String, style: AvatarStyle?) {
        if let old = view.liveRowId, old != rowId, self.views.object(forKey: old as NSString) === view {
            self.views.removeObject(forKey: old as NSString)
        }
        view.liveRowId = rowId
        if style != nil {
            self.views.setObject(view, forKey: rowId as NSString)
        } else if self.views.object(forKey: rowId as NSString) === view {
            self.views.removeObject(forKey: rowId as NSString)
        }
        self.pickLive()
    }

    func detach(_ view: TranscriptAvatarView) {
        if let old = view.liveRowId, self.views.object(forKey: old as NSString) === view {
            self.views.removeObject(forKey: old as NSString)
        }
        view.liveRowId = nil
        self.pickLive()
    }

    /// The view moved in or out of a window.
    func moved(_ view: TranscriptAvatarView) {
        if view === self.live { self.tick() }
    }

    private func observe() {
        guard let chat else {
            self.observing = false
            self.rowId = nil
            self.signals = .idle
            self.pickLive()
            return
        }
        self.observing = true
        let (rowId, signals) = withObservationTracking {
            // Not a message another agent sent here: that one isn't this chat's agent working.
            (chat.entries.last { if case let .assistant(turn) = $0 { turn.sender == nil } else { false } }?.id, chat.avatarSignals)
        } onChange: { [weak self, weak chat] in
            Task { @MainActor in
                guard let self, let chat, chat === self.chat else { return }
                self.observe()
            }
        }
        let changed = rowId != self.rowId
        let signalsChanged = signals != self.signals
        self.signals = signals
        self.rowId = rowId
        // Streaming text changes the entries many times a second; only a new latest row or new
        // signals need a redraw here, the frame timer does the rest.
        if changed { self.pickLive() } else if signalsChanged { self.tick() }
    }

    private func pickLive() {
        let view = self.rowId.flatMap { self.views.object(forKey: $0 as NSString) }
        guard view !== self.live else { return }
        self.live?.showLive(nil)
        self.live = view
        self.lastFrame = nil
        self.tick()
    }

    private var isActive: Bool {
        guard Self.animates, let view = self.live, let window = view.window else { return false }
        #if os(macOS)
        return !view.isHiddenOrHasHiddenAncestor && window.occlusionState.contains(.visible) && !view.visibleRect.isEmpty
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        return UIApplication.shared.applicationState == .active && !UIAccessibility.isReduceMotionEnabled && !view.isHidden
            && view.convert(view.bounds, to: window).intersects(window.bounds)
        #endif
    }

    /// Draws the live avatar's current frame and schedules the next.
    private func tick() {
        self.timer?.invalidate()
        self.timer = nil
        guard let view = self.live else { return }
        let now = Date()
        let state = AvatarStateMachine.state(for: self.signals, now: now)
        if state != self.state {
            self.state = state
            self.since = now
        }
        let active = self.isActive
        let phase = AvatarMotion.phase(for: view.agentSeed)
        let pose = active
            ? AvatarMotion.pose(for: state, time: now.timeIntervalSinceReferenceDate, elapsed: now.timeIntervalSince(self.since),
                                animated: true, phase: phase)
            : nil
        if self.lastFrame?.state != state || self.lastFrame?.pose != pose || view !== self.lastView {
            view.showLive((state, pose))
            self.lastFrame = (state, pose)
            self.lastView = view
        }
        guard view.window != nil else { return }
        var next = AvatarStateMachine.nextTransition(for: self.signals, now: now)
        // Offscreen or inactive, only a transient pose's expiry is scheduled; a row scrolling back in is
        // reconfigured (attach), and windows, scene and Reduce Motion changes tick via observers.
        let wait: TimeInterval? = if active {
            AvatarMotion.frameInterval(for: state, plush: view.isPlush)
                ?? AvatarMotion.nextIdleChange(after: now.timeIntervalSinceReferenceDate, phase: phase) - now.timeIntervalSinceReferenceDate
        } else {
            nil
        }
        if let wait {
            let date = now.addingTimeInterval(max(wait, 0.02))
            next = next.map { min($0, date) } ?? date
        }
        guard let next else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
