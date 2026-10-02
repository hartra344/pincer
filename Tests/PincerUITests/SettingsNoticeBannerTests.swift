#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
private final class ManualNoticeWaiter {
    private(set) var entered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func wait(_ duration: Duration) async {
        _ = duration
        self.entered = true
        await withCheckedContinuation { self.releaseContinuation = $0 }
    }

    func release() {
        self.releaseContinuation?.resume()
        self.releaseContinuation = nil
    }
}

/// The Channel Status view owns the same banner task used by the page; the injected waiter makes
/// the old four-second dismissal deterministic and the injected announcer records actual intent.
@MainActor
@Suite("Settings notice banner", .serialized)
struct SettingsNoticeBannerTests {
    @Test func channelErrorIsAnnouncedAndWaitsForExplicitDismissal() async throws {
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
        defer { waiter.release(); window.close() }

        let started = await eventually(timeout: .seconds(3)) { waiter.entered || !announcements.isEmpty }
        #expect(started, "the hosted notice starts its real SwiftUI task")
        #expect(announcements == [notice.text], "Channel Status should announce each new notice")
        if waiter.entered {
            waiter.release()
            let timedOut = await eventually(timeout: .seconds(3)) { dismissals > 0 }
            #expect(!timedOut, "an error notice stays visible after its timeout completes")
        }
        #expect(dismissals == 0, "an error notice stays visible after its timeout completes")
    }
}
#endif
