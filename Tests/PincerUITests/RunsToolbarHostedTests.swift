#if os(iOS)
import CoreGraphics
import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
@testable import PincerKit
@testable import PincerUI

/// Exercises the real compact NavigationStack toolbar item, where iPhone's glass styling can
/// recolor the Runs symbol and hide activity conveyed by tint or symbol effects alone.
@MainActor
@Observable
private final class RunsToolbarPresentationState {
    var presented = false
}

@MainActor
private struct RunsToolbarHostContent: View {
    let gateway: GatewayStore
    let rootKey: String
    let presentation: RunsToolbarPresentationState

    var body: some View {
        NavigationStack {
            Text("Launch plan")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        RunsToolbarButton(isPresented: Binding(
                            get: { self.presentation.presented }, set: { self.presentation.presented = $0 }
                        ), isCompact: true, sessionKey: self.rootKey)
                    }
                }
        }
        .environment(self.gateway)
        .background(Color(uiColor: .systemBackground))
    }
}

@MainActor
private enum RunsToolbarHostedFixtures {
    @MainActor
    private final class DemoReadinessWaiter {
        private let gateway: GatewayStore
        private let rootKey: String
        private var continuation: AsyncStream<Bool>.Continuation?

        init(gateway: GatewayStore, rootKey: String) {
            self.gateway = gateway
            self.rootKey = rootKey
        }

        func stream() -> AsyncStream<Bool> {
            let pair = AsyncStream<Bool>.makeStream()
            self.continuation = pair.continuation
            pair.continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.cancel() }
            }
            self.observe()
            return pair.stream
        }

        private func observe() {
            guard let continuation = self.continuation else { return }
            var result: Bool?
            withObservationTracking {
                switch self.gateway.state {
                case .connected:
                    if self.gateway.sessions[self.rootKey] != nil { result = true }
                case .failed(_), .awaitingPairing(_, _):
                    result = false
                case .idle, .connecting, .reconnecting:
                    break
                }
            } onChange: { [weak self] in
                Task { @MainActor in self?.observe() }
            }

            if let result {
                continuation.yield(result)
                continuation.finish()
                self.continuation = nil
            }
        }

        func cancel() {
            self.continuation?.finish()
            self.continuation = nil
        }
    }

    static func waitForDemoReadiness(gateway: GatewayStore, rootKey: String) async -> Bool {
        let waiter = DemoReadinessWaiter(gateway: gateway, rootKey: rootKey)
        defer { waiter.cancel() }
        for await ready in waiter.stream() { return ready }
        return false
    }

    static func snapshot(_ view: UIView) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = view.window?.screen.scale ?? UIScreen.main.scale
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { renderer in
            if !view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) {
                view.layer.render(in: renderer.cgContext)
            }
        }
    }

    static func contentPixelCount(in image: UIImage) -> Int {
        guard let source = image.cgImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: source.width, height: source.height,
                                      bitsPerComponent: 8, bytesPerRow: source.width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { return 0 }
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: source.width * source.height * 4)
        let background = (bytes[0], bytes[1], bytes[2], bytes[3])
        var count = 0
        for pixel in 0..<(source.width * source.height) {
            let offset = pixel * 4
            let difference = abs(Int(bytes[offset]) - Int(background.0))
                + abs(Int(bytes[offset + 1]) - Int(background.1))
                + abs(Int(bytes[offset + 2]) - Int(background.2))
                + abs(Int(bytes[offset + 3]) - Int(background.3))
            if bytes[offset + 3] > 200, difference > 60 { count += 1 }
        }
        return count
    }

    static func redBadgePixelCount(in image: UIImage) -> Int {
        guard let source = image.cgImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: source.width, height: source.height,
                                      bitsPerComponent: 8, bytesPerRow: source.width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { return 0 }
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: source.width * source.height * 4)
        var count = 0
        for pixel in 0..<(source.width * source.height) {
            let offset = pixel * 4
            if bytes[offset] > 180, bytes[offset + 1] < 100, bytes[offset + 2] < 100, bytes[offset + 3] > 200 {
                count += 1
            }
        }
        return count
    }
}

@MainActor
extension TranscriptUIKitHostedTests {
    @Test(.timeLimit(.minutes(2)))
    func compactRunsToolbarPaintsCurrentCountWhileRunsAreActive() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: UIFixtures.identity())
        gateway.start()
        defer { gateway.stop() }

        let rootKey = "agent:research:dashboard:launch-plan"
        let connected = await RunsToolbarHostedFixtures.waitForDemoReadiness(gateway: gateway, rootKey: rootKey)
        #expect(connected, "the local DemoGateway reaches its seeded launch-plan chat; connection state: \(gateway.state), error: \(gateway.lastError ?? "none")")
        guard connected else { return }

        let runningKey = "agent:main:subagent:8b3d7f40-6e5c-4d8f-b194-4f5a6b7c8d04"
        let secondKey = "agent:research:subagent:badge-test-running"
        let presentation = RunsToolbarPresentationState()
        let root = RunsToolbarHostContent(gateway: gateway, rootKey: rootKey, presentation: presentation)
        let controller = UIHostingController(rootView: root)
        controller.overrideUserInterfaceStyle = .light

        func makeRow(_ key: String, active: Bool) -> SessionRow {
            SessionRow(.object([
                "key": .string(key), "label": .string("Badge fixture"),
                "spawnedBy": .string(rootKey), "parentSessionKey": .string(rootKey),
                "status": .string(active ? "running" : "done"),
                "hasActiveRun": .bool(active), "subagentRunState": .string(active ? "active" : "finished"),
            ]))!
        }

        func renderButton() throws -> UIImage {
            let button = RunsToolbarButton(isPresented: Binding(
                get: { presentation.presented }, set: { presentation.presented = $0 }
            ), isCompact: true, sessionKey: rootKey)
                .environment(gateway)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .frame(width: 40, height: 40)
            return try #require(ImageRenderer(content: button).uiImage)
        }

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState != .unattached })
        else {
            // SwiftPM's in-process runner has no UIWindowScene. Render the production button's
            // badge here; the scene-backed branch also checks its native glass-toolbar placement.
            #expect(gateway.subagentTree(rootKey: rootKey).runningCount == 1)
            #expect(RunsToolbarHostedFixtures.redBadgePixelCount(in: try renderButton()) >= 20,
                    "one active demo helper paints the production Runs icon badge")

            gateway.setSession(makeRow(secondKey, active: true), for: secondKey)
            #expect(gateway.subagentTree(rootKey: rootKey).runningCount == 2)
            #expect(RunsToolbarHostedFixtures.redBadgePixelCount(in: try renderButton()) >= 20,
                    "two active demo helpers keep the production Runs badge visible")

            gateway.setSession(makeRow(secondKey, active: false), for: secondKey)
            #expect(gateway.subagentTree(rootKey: rootKey).runningCount == 1)
            #expect(RunsToolbarHostedFixtures.redBadgePixelCount(in: try renderButton()) >= 20,
                    "one remaining helper keeps the badge visible")

            gateway.setSession(makeRow(runningKey, active: false), for: runningKey)
            #expect(gateway.subagentTree(rootKey: rootKey).runningCount == 0)
            let badgeCleared = await eventually(timeout: .seconds(5)) {
                (try? renderButton()).map { RunsToolbarHostedFixtures.redBadgePixelCount(in: $0) == 0 } ?? false
            }
            #expect(badgeCleared, "no active helpers removes the badge")

            presentation.presented = true
            let presentedIdle = try renderButton()
            #expect(RunsToolbarHostedFixtures.contentPixelCount(in: presentedIdle) > 0,
                    "the presented idle Runs button still renders its icon")
            #expect(RunsToolbarHostedFixtures.redBadgePixelCount(in: presentedIdle) == 0,
                    "an open, idle Runs panel does not show an activity badge")
            return
        }
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.isHidden = true
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKeyAndVisible()
        }

        #expect(gateway.subagentTree(rootKey: rootKey).runningCount == 1)
        let initialBadgePainted = await eventually(timeout: .seconds(5)) {
            controller.view.layoutIfNeeded()
            return RunsToolbarHostedFixtures.redBadgePixelCount(in: RunsToolbarHostedFixtures.snapshot(controller.view)) >= 20
        }
        #expect(initialBadgePainted, "the attached native toolbar paints the seeded running helper badge")
        controller.view.layoutIfNeeded()
        let oneActive = RunsToolbarHostedFixtures.snapshot(controller.view)
        #expect(RunsToolbarHostedFixtures.contentPixelCount(in: oneActive) > 100,
                "the hosted Launch plan body and toolbar render visible content")
        #expect(RunsToolbarHostedFixtures.redBadgePixelCount(in: oneActive) >= 20,
                "one active helper paints the red activity badge over the toolbar symbol")
        let onePath = FileManager.default.temporaryDirectory.appendingPathComponent("pincer-runs-toolbar-one-\(UUID().uuidString).png")
        let oneData = try #require(oneActive.pngData())
        try oneData.write(to: onePath)
        print("Runs toolbar count-one snapshot: \(onePath.path)")

        gateway.setSession(makeRow(secondKey, active: true), for: secondKey)
        await Task.yield()
        #expect(gateway.subagentTree(rootKey: rootKey).runningCount == 2)
        controller.view.layoutIfNeeded()
        let twoActive = RunsToolbarHostedFixtures.snapshot(controller.view)
        #expect(RunsToolbarHostedFixtures.contentPixelCount(in: twoActive) > 100,
                "the body remains painted with multiple helpers running")
        #expect(RunsToolbarHostedFixtures.redBadgePixelCount(in: twoActive) >= 20,
                "two active helpers keep the red activity badge visible")
        let twoPath = FileManager.default.temporaryDirectory.appendingPathComponent("pincer-runs-toolbar-two-\(UUID().uuidString).png")
        let twoData = try #require(twoActive.pngData())
        try twoData.write(to: twoPath)
        print("Runs toolbar count-two snapshot: \(twoPath.path)")

        gateway.setSession(makeRow(secondKey, active: false), for: secondKey)
        await Task.yield()
        #expect(gateway.subagentTree(rootKey: rootKey).runningCount == 1)
        controller.view.layoutIfNeeded()
        let oneAgain = RunsToolbarHostedFixtures.snapshot(controller.view)
        #expect(RunsToolbarHostedFixtures.redBadgePixelCount(in: oneAgain) >= 20,
                "the red activity badge remains when one helper is still active")

        gateway.setSession(makeRow(runningKey, active: false), for: runningKey)
        #expect(gateway.subagentTree(rootKey: rootKey).runningCount == 0)
        let nativeBadgeCleared = await eventually(timeout: .seconds(5)) {
            controller.view.layoutIfNeeded()
            return RunsToolbarHostedFixtures.redBadgePixelCount(in: RunsToolbarHostedFixtures.snapshot(controller.view)) == 0
        }
        #expect(nativeBadgeCleared, "the native toolbar removes its badge after the last helper stops")
        controller.view.layoutIfNeeded()
        let idleHidden = RunsToolbarHostedFixtures.snapshot(controller.view)
        #expect(RunsToolbarHostedFixtures.redBadgePixelCount(in: idleHidden) == 0,
                "zero running helpers remove the active badge from the compact toolbar")

        presentation.presented = true
        await Task.yield()
        controller.view.layoutIfNeeded()
        let presentedIdle = RunsToolbarHostedFixtures.snapshot(controller.view)
        #expect(RunsToolbarHostedFixtures.contentPixelCount(in: presentedIdle) > 100,
                "the open Runs panel state still renders the chat and toolbar")
        #expect(RunsToolbarHostedFixtures.redBadgePixelCount(in: presentedIdle) == 0,
                "an open, idle Runs panel does not show a running badge")
    }
}
#endif
