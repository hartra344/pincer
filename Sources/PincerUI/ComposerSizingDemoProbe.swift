#if os(macOS) && DEBUG
import AppKit
import Observation
import PincerKit
import SwiftUI

@MainActor
private struct ComposerSizingDemoHost: View {
    @Bindable var chat: ChatStore
    let width: CGFloat

    var body: some View {
        ComposerTextView(
            placeholder: "Message",
            text: self.$chat.draft.text,
            maxLines: 12,
            onSubmit: {},
            onMedia: { _ in },
            autoFocus: { false })
            .frame(width: self.width, alignment: .leading)
    }
}

private final class ComposerSizingProbeWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
public extension ComposerSizingProbe {
    /// Runs the real Demo-backed native composer sizing path without activating the app.
    /// Set PINCER_DEV_NAMESPACE, PINCER_KEYCHAIN=memory, and PINCER_DRAFTS_DIR=off first.
    static func run() async -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        guard let namespace = environment["PINCER_DEV_NAMESPACE"], !namespace.isEmpty,
              environment["PINCER_KEYCHAIN"] == "memory",
              environment["PINCER_DRAFTS_DIR"] == "off"
        else {
            print("Composer sizing probe: set PINCER_DEV_NAMESPACE, PINCER_KEYCHAIN=memory, and PINCER_DRAFTS_DIR=off")
            return 2
        }

        let defaultsName = "chat.pincer.composer-sizing-probe.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            print("Composer sizing probe: couldn't create isolated defaults")
            return 2
        }
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let gateway = GatewayStore(profile: .demo(), defaults: defaults)
        gateway.start()
        defer { gateway.stop() }

        let readinessDeadline = ProcessInfo.processInfo.systemUptime + 15
        var garden: SessionRow?
        while ProcessInfo.processInfo.systemUptime < readinessDeadline {
            garden = gateway.sessions.values.first {
                $0.title.localizedCaseInsensitiveContains("Garden")
            }
            if gateway.state.isConnected, garden != nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard gateway.state.isConnected, let garden else {
            print("Composer sizing probe: Demo Gateway did not load its seeded Garden chat")
            return 2
        }

        let chat = gateway.chat(for: garden.key)
        let width: CGFloat = 360
        let host = NSHostingView(rootView: ComposerSizingDemoHost(chat: chat, width: width))
        let window = ComposerSizingProbeWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: width, height: 240),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: 240)
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.close()
        }

        let cases: [(String, String)] = [
            ("32KiB", String(repeating: "x", count: 32 * 1024)),
            ("128KiB", String(repeating: "y", count: 128 * 1024)),
            ("128KiB-trailing-edit", String(repeating: "y", count: 128 * 1024) + "z"),
        ]
        var failures = 0
        for (name, text) in cases {
            self.reset(enabled: true)
            chat.draft.text = text
            Self.layout(host, in: window)

            let sampleDeadline = ProcessInfo.processInfo.systemUptime + 2
            var matching: [ComposerSizingSample] = []
            var nativeScroll: NSScrollView?
            var nativeFrameWidth = 0.0
            var nativeBoundsWidth = 0.0
            var nativeHeight = 0.0
            var geometryConverged = false
            while ProcessInfo.processInfo.systemUptime < sampleDeadline {
                Self.layout(host, in: window)
                matching = self.samples.filter { $0.attributedLength == text.utf16.count }
                nativeScroll = Self.scrollView(in: host)
                nativeFrameWidth = Double(nativeScroll?.frame.width ?? 0)
                nativeBoundsWidth = Double(nativeScroll?.bounds.width ?? 0)
                nativeHeight = Double(nativeScroll?.frame.height ?? 0)
                if let sample = matching.last, nativeScroll != nil {
                    geometryConverged = abs(nativeFrameWidth - sample.width) <= 1.5
                        && abs(nativeFrameWidth - Double(width)) <= 1.5
                        && abs(nativeHeight - sample.returnedHeight) <= 1.5
                    if geometryConverged { break }
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard !matching.isEmpty else {
                print("Composer sizing probe: {\"case\":\"\(name)\",\"requested_width\":\(width),\"error\":\"measurement-timeout\"}")
                failures += 1
                continue
            }

            try? await Task.sleep(for: .milliseconds(5))
            Self.layout(host, in: window)
            matching = self.samples.filter { $0.attributedLength == text.utf16.count }
            nativeScroll = Self.scrollView(in: host)
            nativeFrameWidth = Double(nativeScroll?.frame.width ?? 0)
            nativeBoundsWidth = Double(nativeScroll?.bounds.width ?? 0)
            nativeHeight = Double(nativeScroll?.frame.height ?? 0)
            guard let current = matching.last else {
                print("Composer sizing probe: {\"case\":\"\(name)\",\"requested_width\":\(width),\"error\":\"measurement-lost-after-layout\"}")
                failures += 1
                continue
            }
            let elapsed = matching.reduce(UInt64(0)) { $0 &+ $1.elapsedNanoseconds }
            let mainCount = matching.filter(\.isMainThread).count
            let cap = current.lineHeight * Double(current.maxLines)
            geometryConverged = nativeScroll != nil
                && abs(nativeFrameWidth - current.width) <= 1.5
                && abs(nativeFrameWidth - Double(width)) <= 1.5
                && abs(nativeHeight - current.returnedHeight) <= 1.5
            let withinCap = nativeHeight > 0 && nativeHeight <= cap + 1.5
            let passed = mainCount == 0 && geometryConverged && withinCap
            if !passed { failures += 1 }
            print(String(
                format: "{\"case\":\"%@\",\"utf16\":%d,\"requested_width\":%.2f,\"measurements\":%d,\"samples\":[%@],\"sum_ns\":%llu,\"max_ns\":%llu,\"main_count\":%d,\"native_frame_width\":%.2f,\"native_bounds_width\":%.2f,\"native_height\":%.2f,\"measured_height\":%.2f,\"cap\":%.2f,\"geometry_converged\":%@,\"pass\":%@}",
                name, text.utf16.count, width, matching.count,
                matching.map { String(format: "{\"width\":%.2f,\"height\":%.2f,\"main\":%@}", $0.width, $0.returnedHeight, $0.isMainThread ? "true" : "false") }.joined(separator: ","), elapsed,
                matching.map(\.elapsedNanoseconds).max() ?? 0, mainCount,
                nativeFrameWidth, nativeBoundsWidth, nativeHeight, current.returnedHeight,
                cap, geometryConverged ? "true" : "false", passed ? "true" : "false"))
        }
        self.reset(enabled: false)
        print(failures == 0 ? "Composer sizing probe: OK" : "Composer sizing probe: FAIL (\(failures) case(s))")
        return failures == 0 ? 0 : 1
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView,
           scrollView.documentView is ComposerNSTextView
        {
            return scrollView
        }
        for child in view.subviews {
            if let found = self.scrollView(in: child) { return found }
        }
        return nil
    }

    private static func layout(_ host: NSHostingView<ComposerSizingDemoHost>, in window: NSWindow) {
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
    }
}
#endif
