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
        }
}

@MainActor
private enum RunsToolbarHostedFixtures {
    static var keepAlive: [UIWindow] = []

    static func accessibilityLabels(in root: UIView) -> [String] {
        var labels: [String] = []
        var visited = Set<ObjectIdentifier>()
        Self.walk(root, labels: &labels, visited: &visited)
        return Array(Set(labels))
    }

    private static func walk(_ element: Any, labels: inout [String], visited: inout Set<ObjectIdentifier>) {
        guard let object = element as? NSObject,
              visited.insert(ObjectIdentifier(object)).inserted else { return }
        if let label = object.accessibilityLabel, !label.isEmpty { labels.append(label) }
        if let view = object as? UIView {
            for child in view.subviews { Self.walk(child, labels: &labels, visited: &visited) }
        }
        let count = object.accessibilityElementCount()
        guard count > 0, count < 2_000 else { return }
        for index in 0..<count {
            if let child = object.accessibilityElement(at: index) {
                Self.walk(child, labels: &labels, visited: &visited)
            }
        }
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
    @Test func compactRunsToolbarShowsAccessibleAndPaintedCountWhileRunsAreActive() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: UIFixtures.identity())
        gateway.start()
        defer { gateway.stop() }

        let connected = await eventually(timeout: .seconds(15)) {
            gateway.state.isConnected && gateway.sessions["agent:research:dashboard:launch-plan"] != nil
        }
        #expect(connected, "the local DemoGateway reaches its seeded launch-plan chat")
        guard connected else { return }

        let rootKey = "agent:research:dashboard:launch-plan"
        let runningKey = "agent:main:subagent:8b3d7f40-6e5c-4d8f-b194-4f5a6b7c8d04"
        let secondKey = "agent:research:subagent:badge-test-running"
        let presentation = RunsToolbarPresentationState()
        let root = RunsToolbarHostContent(gateway: gateway, rootKey: rootKey, presentation: presentation)
        let controller = UIHostingController(rootView: root)
        func makeRow(_ key: String, active: Bool) -> SessionRow {
            SessionRow(.object([
                "key": .string(key), "label": .string("Badge fixture"),
                "spawnedBy": .string(rootKey), "parentSessionKey": .string(rootKey),
                "status": .string(active ? "running" : "done"),
                "hasActiveRun": .bool(active), "subagentRunState": .string(active ? "active" : "finished"),
            ]))!
        }

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState != .unattached })
        else {
            // Package tests have no app scene. Render the same production button's icon label;
            // app-hosted runs below additionally exercise its real Liquid Glass toolbar container.
            func renderButton() throws -> UIImage {
                let button = RunsToolbarButton(isPresented: .constant(false), isCompact: true, sessionKey: rootKey)
                    .environment(gateway)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .frame(width: 40, height: 40)
                return try #require(ImageRenderer(content: button).uiImage)
            }
            let active = try renderButton()
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("pincer-runs-label-\(UUID().uuidString).png")
            try active.pngData()?.write(to: path)
            print("Runs headless label snapshot: \(path.path)")
            #expect(RunsToolbarHostedFixtures.redBadgePixelCount(in: active) >= 20,
                    "the production icon label paints the active badge even without symbol tint")
            gateway.setSession(makeRow(secondKey, active: true), for: secondKey)
            #expect(gateway.subagentTree(rootKey: rootKey).runningCount == 2)
            #expect(RunsToolbarHostedFixtures.redBadgePixelCount(in: try renderButton()) >= 20)
            gateway.setSession(makeRow(secondKey, active: false), for: secondKey)
            gateway.setSession(makeRow(runningKey, active: false), for: runningKey)
            #expect(gateway.subagentTree(rootKey: rootKey).runningCount == 0)
            #expect(RunsToolbarHostedFixtures.redBadgePixelCount(in: try renderButton()) == 0,
                    "an idle compact button cannot leave an active badge behind")
            return
        }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        RunsToolbarHostedFixtures.keepAlive.append(window)


        #expect(gateway.subagentTree(rootKey: rootKey).runningCount == 1)
        let initialVisible = await eventually(timeout: .seconds(5)) {
            let labels = RunsToolbarHostedFixtures.accessibilityLabels(in: controller.view)
            return labels.contains("Launch plan") && labels.contains(where: { $0.hasPrefix("Runs") })
        }
        #expect(initialVisible, "the connected host renders its body and seeded active Runs button")
        gateway.setSession(makeRow(secondKey, active: true), for: secondKey)
        #expect(gateway.subagentTree(rootKey: rootKey).runningCount == 2)

        let twoRunning = await eventually(timeout: .seconds(5)) {
            RunsToolbarHostedFixtures.accessibilityLabels(in: controller.view).contains("Runs — 2 helpers running")
        }
        #expect(twoRunning, "the actual primary toolbar item exposes the current running count")

        gateway.setSession(makeRow(secondKey, active: false), for: secondKey)
        #expect(gateway.subagentTree(rootKey: rootKey).runningCount == 1)
        let oneRunning = await eventually(timeout: .seconds(5)) {
            RunsToolbarHostedFixtures.accessibilityLabels(in: controller.view).contains("Runs — 1 helper running")
        }
        #expect(oneRunning, "the accessible count updates when a helper finishes")

        let snapshot = RunsToolbarHostedFixtures.snapshot(controller.view)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pincer-runs-toolbar-\(UUID().uuidString).png")
        let snapshotData = try #require(snapshot.pngData())
        try snapshotData.write(to: path)
        print("Runs toolbar active badge snapshot: \(path.path)")
        #expect(Self.paintedPixelCount(in: snapshot) > 100,
                "the snapshot contains painted toolbar/body content rather than an empty render")
        #expect(RunsToolbarHostedFixtures.redBadgePixelCount(in: snapshot) >= 20, "the active count badge is visibly painted in the native toolbar")

        gateway.setSession(makeRow(runningKey, active: false), for: runningKey)
        let idleHidden = await eventually(timeout: .seconds(5)) {
            !RunsToolbarHostedFixtures.accessibilityLabels(in: controller.view).contains(where: { $0.hasPrefix("Runs") })
        }
        #expect(idleHidden, "compact idle Runs button hides when the panel is closed")

        presentation.presented = true
        let presentedIdle = await eventually(timeout: .seconds(5)) {
            RunsToolbarHostedFixtures.accessibilityLabels(in: controller.view).contains("Runs")
        }
        #expect(presentedIdle, "the plain Runs button remains available while its panel is open")
    }

    static func paintedPixelCount(in image: UIImage) -> Int {
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
            if bytes[offset + 3] > 200, max(bytes[offset], max(bytes[offset + 1], bytes[offset + 2])) > 40 {
                count += 1
            }
        }
        return count
    }
}
#endif
