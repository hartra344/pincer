import CoreGraphics
import Observation
import SwiftUI
import Testing
#if os(macOS)
import AppKit
#else
import UIKit
#endif
@testable import PincerKit
@testable import PincerUI

@MainActor
@Observable
private final class ShowRunsMenuPresentation {
    var isPresented: Bool

    init(isPresented: Bool = false) { self.isPresented = isPresented }
}

/// #424: the chat menu should offer Runs only when its own chat has run activity, while an
/// already-open Runs panel must keep its close action available after that activity ends.
@MainActor
@Suite("Show Runs menu", .serialized)
struct ShowRunsMenuTests {
    private static let selectedKey = "agent:main:main"
    private static let paneKey = "agent:main:dashboard:notes"

    private struct Host: View {
        @Bindable var presentation: ShowRunsMenuPresentation
        let gateway: GatewayStore
        let sessionKey: String
        var explicitSessionKey: String? = nil

        var body: some View {
            ShowRunsButton(isPresented: self.$presentation.isPresented, sessionKey: self.explicitSessionKey)
                .environment(self.gateway)
                .environment(\.chatWindowKey, self.sessionKey)
                .buttonStyle(.plain)
                .frame(width: 180, height: 44)
                .background(Color.clear)
        }
    }

    @Test func emptySplitPaneDoesNotBorrowRunsFromTheSelectedChat() throws {
        #expect(Self.nontransparentPixelCount(in: Self.transparentImage()) == 0,
                "The pixel counter recognizes a known transparent render as empty")
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = self.gateway(scratch: scratch)
        gateway.setSession(self.helper(key: "agent:main:subagent:selected-run", parent: Self.selectedKey),
                           for: "agent:main:subagent:selected-run")
        gateway.selectedKey = Self.selectedKey

        #expect(gateway.hasRuns(sessionKey: Self.selectedKey))
        #expect(!gateway.hasRuns(sessionKey: Self.paneKey))
        let pixels = try Self.visiblePixels(gateway: gateway, sessionKey: Self.paneKey)
        #expect(pixels == 0,
                "The pane's explicit chat has no runs; activity in the main selected chat must not create a Show Runs item")
    }

    @Test func completedHelperKeepsShowRunsAvailableForItsPane() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = self.gateway(scratch: scratch)
        gateway.selectedKey = Self.selectedKey
        gateway.setSession(self.helper(key: "agent:main:subagent:finished", parent: Self.paneKey),
                           for: "agent:main:subagent:finished")

        #expect(gateway.subagentTree(rootKey: Self.paneKey).count == 1)
        #expect(try Self.visiblePixels(gateway: gateway, sessionKey: Self.paneKey) > 0,
                "A completed helper is still useful history in the Runs panel")
    }

    @Test func explicitMenuSessionKeyTakesPrecedenceOverWindowAndGatewaySelection() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = self.gateway(scratch: scratch)
        gateway.setSession(self.helper(key: "agent:main:subagent:selected-run", parent: Self.selectedKey),
                           for: "agent:main:subagent:selected-run")
        gateway.setSession(self.helper(key: "agent:main:subagent:window-run", parent: Self.paneKey),
                           for: "agent:main:subagent:window-run")
        gateway.selectedKey = Self.selectedKey

        let explicitKey = "agent:main:dashboard:explicit"
        #expect(gateway.hasRuns(sessionKey: Self.selectedKey))
        #expect(gateway.hasRuns(sessionKey: Self.paneKey))
        #expect(!gateway.hasRuns(sessionKey: explicitKey))
        #expect(try Self.visiblePixels(gateway: gateway, sessionKey: Self.paneKey,
                                       explicitSessionKey: explicitKey) == 0,
                "The menu's row key overrides both the chat-window key and main-window selection")

        gateway.setSession(self.helper(key: "agent:main:subagent:explicit-run", parent: explicitKey),
                           for: "agent:main:subagent:explicit-run")
        #expect(try Self.visiblePixels(gateway: gateway, sessionKey: Self.paneKey,
                                       explicitSessionKey: explicitKey) > 0,
                "Runs belonging only to the explicit menu row keep its item available")
    }

    @Test func timelineOnlyRunKeepsShowRunsAvailable() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = self.gateway(scratch: scratch)
        gateway.selectedKey = Self.selectedKey
        let changed = gateway.runTimelineState.apply(agent: .object([
            "runId": .string("timeline-only"),
            "seq": .number(1),
            "stream": .string("lifecycle"),
            "sessionKey": .string(Self.paneKey),
            "data": .object(["phase": .string("start")]),
        ]), receivedAt: Date(), sessionKey: Self.paneKey)
        #expect(changed)
        gateway.runTimelineRevision &+= 1
        #expect(gateway.hasRuns(sessionKey: Self.paneKey))

        #expect(try Self.visiblePixels(gateway: gateway, sessionKey: Self.paneKey) > 0,
                "A streamed timeline lane is sufficient even without a listed helper session")
    }

    @Test func presentedIdleRunsKeepsTheHideControl() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = self.gateway(scratch: scratch)
        gateway.selectedKey = Self.selectedKey

        let showPixels = try Self.visiblePixels(gateway: gateway, sessionKey: Self.paneKey)
        let hidePixels = try Self.visiblePixels(gateway: gateway, sessionKey: Self.paneKey, isPresented: true)
        #expect(showPixels == 0, "No activity means the closed menu omits Show Runs")
        #expect(hidePixels > 0, "An already-presented Runs panel keeps a visible way to close it")
    }

    @Test func removedHelperLeavesNoRunsMenuItem() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = self.gateway(scratch: scratch)
        gateway.selectedKey = Self.selectedKey

        let before = try Self.visiblePixels(gateway: gateway, sessionKey: Self.paneKey,
                                            capture: "empty-before")
        #expect(before == 0)
        gateway.setSession(self.helper(key: "agent:main:subagent:render-probe", parent: Self.paneKey),
                           for: "agent:main:subagent:render-probe")
        let positive = try Self.visiblePixels(gateway: gateway, sessionKey: Self.paneKey,
                                              capture: "positive")
        #expect(positive > 0)
        gateway.setSession(nil, for: "agent:main:subagent:render-probe")

        let afterRemoval = try Self.visiblePixels(gateway: gateway, sessionKey: Self.paneKey,
                                                 capture: "empty-after-removal")
        #expect(afterRemoval == 0, "A reopened menu after activity clears the item")
    }

    private func gateway(scratch: ScratchDefaults) -> GatewayStore {
        GatewayStore(
            profile: GatewayProfile(name: "Runs menu fixture", url: "ws://127.0.0.1:1", authMode: .none),
            defaults: scratch.defaults,
            identity: UIFixtures.identity())
    }

    private func helper(key: String, parent: String) -> SessionRow? {
        SessionRow(.object([
            "key": .string(key),
            "label": .string("Finished helper"),
            "spawnedBy": .string(parent),
            "parentSessionKey": .string(parent),
            "status": .string("done"),
        ]))
    }

    private static func visiblePixels(gateway: GatewayStore, sessionKey: String,
                                      isPresented: Bool = false,
                                      explicitSessionKey: String? = nil,
                                      uniqueViewIdentity: Bool = true,
                                      capture: String? = nil) throws -> Int
    {
        let presentation = ShowRunsMenuPresentation(isPresented: isPresented)
        let host = Host(presentation: presentation, gateway: gateway,
                        sessionKey: sessionKey, explicitSessionKey: explicitSessionKey)
        let content = uniqueViewIdentity ? AnyView(host.id(UUID())) : AnyView(host)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.isOpaque = false
        // Each independent render gets a fresh view identity. An empty conditional view may
        // legitimately produce no bitmap; positive assertions below still require visible pixels.
        guard let image = renderer.cgImage else {
            print("ShowRuns fixture capture=\(capture ?? "none") resolved=\(explicitSessionKey ?? sessionKey) selected=\(gateway.selectedKey ?? "nil") presented=\(isPresented) hasRuns=\(gateway.hasRuns(sessionKey: explicitSessionKey ?? sessionKey)) uniqueID=\(uniqueViewIdentity) noBitmap")
            return 0
        }
        let pixels = Self.nontransparentPixelCount(in: image)
        let resolvedKey = explicitSessionKey ?? sessionKey
        let hasRuns = gateway.hasRuns(sessionKey: resolvedKey)
        print("ShowRuns fixture capture=\(capture ?? "none") resolved=\(resolvedKey) selected=\(gateway.selectedKey ?? "nil") presented=\(isPresented) hasRuns=\(hasRuns) uniqueID=\(uniqueViewIdentity) pixels=\(pixels)")
        if let capture {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pincer-runs-menu-\(capture)-\(UUID().uuidString).png")
            #if os(macOS)
            if let rep = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try rep.write(to: url)
            }
            #else
            if let data = UIImage(cgImage: image).pngData() { try data.write(to: url) }
            #endif
            print("ShowRuns fixture image: \(url.path)")
        }
        return pixels
    }

    private static func nontransparentPixelCount(in image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { return 0 }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        return (0..<(width * height)).reduce(into: 0) { count, pixel in
            if bytes[pixel * 4 + 3] > 8 { count += 1 }
        }
    }

    private static func transparentImage() -> CGImage {
        let width = 4
        let height = 4
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                    | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}

#if os(iOS)
extension TranscriptUIKitHostedTests {
    @Test func showRunsMenuUsesTheExplicitChatWindowContext() throws {
        try ShowRunsMenuTests().emptySplitPaneDoesNotBorrowRunsFromTheSelectedChat()
    }

    @Test func showRunsMenuHonorsItsExplicitPaneSessionKey() throws {
        try ShowRunsMenuTests().explicitMenuSessionKeyTakesPrecedenceOverWindowAndGatewaySelection()
    }
}
#endif
