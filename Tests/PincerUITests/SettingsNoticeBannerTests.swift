#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
private final class ManualNoticeWaiter {
    private(set) var enteredCount = 0
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func wait(_ duration: Duration) async {
        _ = duration
        self.enteredCount += 1
        await withCheckedContinuation { self.releaseContinuations.append($0) }
    }

    func releaseNext() {
        guard !self.releaseContinuations.isEmpty else { return }
        self.releaseContinuations.removeFirst().resume()
    }

    func releaseAll() {
        for continuation in self.releaseContinuations { continuation.resume() }
        self.releaseContinuations.removeAll()
    }
}

/// The Channel Status view owns the same banner task used by the page; the injected waiter makes
/// the old four-second dismissal deterministic and the injected announcer records actual intent.
@MainActor
@Suite("Settings notice banner", .serialized)
struct SettingsNoticeBannerTests {
    @Test func channelErrorIsAnnouncedAndStaysUntilDismissed() async throws {
        let waiter = ManualNoticeWaiter()
        var announcements: [String] = []
        var dismissals = 0
        let notice = ChannelsModel.Notice(text: "Telegram could not reconnect.", isError: true)
        let banner = ChannelStatusNoticeView(notice: notice, dismiss: { dismissals += 1 },
                                             wait: { await waiter.wait($0) },
                                             announce: { announcements.append($0) })
        let host = NSHostingView(rootView: banner.frame(width: 460, height: 68))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        defer { waiter.releaseAll(); window.close() }

        let started = await eventually(timeout: .seconds(3)) { !announcements.isEmpty }
        #expect(started, "the hosted notice starts its real SwiftUI task")
        #expect(announcements == [notice.text], "Channel Status should announce each new notice")
        #expect(waiter.enteredCount == 0, "persistent errors do not start an auto-dismiss timer")
        #expect(dismissals == 0, "an error notice stays visible after its timeout completes")
    }

    @Test func successNoticeDismissesAfterItsTimeout() async throws {
        let waiter = ManualNoticeWaiter()
        var dismissals = 0
        let notice = ChannelsModel.Notice(text: "Telegram reconnected.", isError: false)
        let banner = ChannelStatusNoticeView(notice: notice, dismiss: { dismissals += 1 },
                                             wait: { await waiter.wait($0) }, announce: { _ in })
        let host = NSHostingView(rootView: banner.frame(width: 460, height: 68))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { waiter.releaseAll(); window.close() }

        #expect(await eventually(timeout: .seconds(3)) { waiter.enteredCount == 1 })
        waiter.releaseNext()
        #expect(await eventually(timeout: .seconds(3)) { dismissals == 1 }, "success expires after its timeout")
    }

    @Test func replacingNoticeCancelsTheOlderTimeout() async throws {
        let waiter = ManualNoticeWaiter()
        let oldID = UUID()
        let newID = UUID()
        var dismissed: [UUID] = []
        let host = NSHostingView(rootView: SettingsNoticeBanner(
            id: oldID, text: "Old result", severity: .success, announces: false,
            dismiss: { dismissed.append(oldID) }, wait: { await waiter.wait($0) }) { Text("Old result") }
            .frame(width: 460, height: 68))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { waiter.releaseAll(); window.close() }
        #expect(await eventually(timeout: .seconds(3)) { waiter.enteredCount == 1 })

        host.rootView = SettingsNoticeBanner(
            id: newID, text: "New result", severity: .success, announces: false,
            dismiss: { dismissed.append(newID) }, wait: { await waiter.wait($0) }) { Text("New result") }
            .frame(width: 460, height: 68)
        #expect(await eventually(timeout: .seconds(3)) { waiter.enteredCount == 2 })
        waiter.releaseNext()
        await Task.yield()
        #expect(dismissed.isEmpty, "a canceled older notice cannot dismiss its replacement")
        waiter.releaseNext()
        #expect(await eventually(timeout: .seconds(3)) { dismissed == [newID] })
    }

    @Test func escapeDismissesNoticeFromTheNativeWindow() async throws {
        var dismissals = 0
        var announcements: [String] = []
        let notice = ChannelsModel.Notice(text: "An action needs attention.", isError: true)
        let banner = ChannelStatusNoticeView(notice: notice, dismiss: { dismissals += 1 },
                                             wait: { _ in }, announce: { announcements.append($0) })
        let controller = NSHostingController(rootView: banner.frame(width: 460, height: 68))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 460, height: 68),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        controller.view.displayIfNeeded()
        defer { window.close() }
        #expect(await eventually(timeout: .seconds(3)) { announcements == [notice.text] },
                "the hosted notice is rendered before keyboard input")
        #expect(window.makeFirstResponder(controller.view), "the hosted notice receives the native key event")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil,
                                      characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                      isARepeat: false, keyCode: 53)
        #expect(escape != nil)
        if let escape { NSApp.sendEvent(escape) }
        #expect(await eventually(timeout: .seconds(2)) { dismissals == 1 },
                "Escape activates the notice's accessible dismiss button")
    }
}
#endif
