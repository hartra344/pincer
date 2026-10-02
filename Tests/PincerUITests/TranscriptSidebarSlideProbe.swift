#if os(iOS)
import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
@testable import PincerKit
@testable import PincerUI

/// Measures transcript row layouts while the real iPad split view changes column visibility.
@MainActor
@Suite("Transcript iPad sidebar slide probe", .serialized)
struct TranscriptSidebarSlideProbe {
    private static var keepAlive: [(UIWindow, UIHostingController<SidebarSlideHost>, TranscriptList.Coordinator)] = []

    @Test(.timeLimit(.minutes(2)))
    func recordsDetailWidthAndRowBuildsPerDisplayFrame() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(
            profile: GatewayProfile(name: "Sidebar probe", url: "ws://127.0.0.1:1", authMode: .none),
            defaults: scratch.defaults,
            identity: UIFixtures.identity())
        let key = "agent:sidebar-probe:main"
        let chat = gateway.chat(for: key)
        let transcriptContext = TranscriptContext(
            gateway: gateway,
            disclosure: TranscriptDisclosure(),
            agent: AgentSummary(id: "sidebar-probe", name: "Probe"),
            sessionKey: key,
            previewImage: { _ in },
            saveFile: { _, _ in },
            chat: chat)
        let rows = TranscriptUIKitHostedTests.rows(count: 1200, salt: "sidebar-probe")
        let state = SidebarSlideState()
        let transcript = TranscriptList(rows: rows, context: transcriptContext, isConnected: false)
        let controller = UIHostingController(rootView: SidebarSlideHost(state: state, transcript: transcript))

        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState != .unattached }
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: UIScreen.main.bounds)
        window.frame = scene?.coordinateSpace.bounds ?? UIScreen.main.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        for _ in 0..<8 { await Task.yield() }

        #expect(controller.view.traitCollection.horizontalSizeClass == .regular,
                "the split-view probe must run with iPad regular-width metrics")
        #expect(state.visibility == .all, "the real NavigationSplitView starts with both columns shown")

        let listReady = await eventually(timeout: .seconds(10)) {
            Self.transcriptCollectionView(in: controller.view) != nil
        }
        #expect(listReady, "the actual TranscriptList collection view is attached in the split detail")
        let collection = try #require(Self.transcriptCollectionView(in: controller.view))
        let coordinator = try #require(collection.delegate as? TranscriptList.Coordinator,
                                        "the visible collection view is driven by TranscriptList.Coordinator")
        let split = try #require(Self.splitViewController(in: controller),
                                  "the detail lives inside a native UISplitViewController")
        let host = TranscriptUIKitHostedTests.Host(coordinator: coordinator, view: collection, context: transcriptContext)
        Self.keepAlive.append((window, controller, coordinator))
        await TranscriptUIKitHostedTests.idle(host, cap: 20)

        #expect(Self.snapshot(split).primaryIsShown, "the native split view starts with its sidebar column visible")
        let hide = await Self.measureTransition(state, split: split, collection: collection, coordinator: coordinator,
                                                host: host, to: .detailOnly, from: .all)
        let show = await Self.measureTransition(state, split: split, collection: collection, coordinator: coordinator,
                                                host: host, to: .all, from: .detailOnly)

        Self.report(hide, name: "hide sidebar")
        Self.report(show, name: "show sidebar")
        #expect(hide.startNative.primaryIsShown && !hide.endNative.primaryIsShown,
                "the native split view hides its primary column")
        #expect(!show.startNative.primaryIsShown && show.endNative.primaryIsShown,
                "the native split view restores its primary column")
        for result in [hide, show] {
            #expect(abs(result.endWidth - result.startWidth) > 80, "the native transition changes detail geometry")
            #expect(result.widthChangingFrames >= 1, "the display link captures the native width change")
            #expect(result.widthChangingFrames <= 2, "UIKit applies final transcript width without per-frame reflow")
            #expect(result.framesWithRowBuilds <= result.widthChangingFrames * 4 + 2,
                    "row builds stay within a few settling frames per width change")
        }
    }

    private static func measureTransition(
        _ state: SidebarSlideState,
        split: UISplitViewController,
        collection: UICollectionView,
        coordinator: TranscriptList.Coordinator,
        host: TranscriptUIKitHostedTests.Host,
        to target: NavigationSplitViewVisibility,
        from expectedStart: NavigationSplitViewVisibility) async -> Measurement
    {
        #expect(state.visibility == expectedStart, "the split view begins this measurement in the expected column state")
        await TranscriptUIKitHostedTests.idle(host, cap: 10)
        let startWidth = collection.bounds.width
        let startNative = Self.snapshot(split)
        let initialBuilds = coordinator.renderer.layoutBuildCount
        let sampler = DisplayFrameSampler(collection: collection, coordinator: coordinator, split: split)
        sampler.start()
        state.toggle()
        // Drive the public native transition explicitly. This probe measures UIKit
        // transcript geometry; it does not verify the SwiftUI sidebar button binding.
        if target == .detailOnly { split.hide(.primary) } else { split.show(.primary) }
        let targetShowsPrimary = target != .detailOnly
        let nativeTransitioned = await eventually(timeout: .seconds(5)) {
            state.visibility == target && Self.snapshot(split).primaryIsShown == targetShowsPrimary
        }
        #expect(state.visibility == target, "column visibility reaches the requested \(target) state")
        #expect(nativeTransitioned, "the native UISplitViewController reflects the column visibility change")
        // The detail can keep its final model width while UIKit animates the sidebar's presentation.
        // Capture the whole default animation window rather than ending after six constant-width frames.
        try? await Task.sleep(for: .milliseconds(600))
        let sampled = await eventually(timeout: .seconds(5)) { sampler.samples.count >= 2 && sampler.stableFrameCount >= 6 }
        #expect(sampled, "the CADisplayLink captures multiple native frames during the transition")
        sampler.stop()
        await TranscriptUIKitHostedTests.idle(host, cap: 10)

        let samples = sampler.samples
        let endWidth = collection.bounds.width
        let endNative = Self.snapshot(split)
        let frameChanges = zip(samples, samples.dropFirst()).map { previous, next in
            (widthChanged: abs(next.width - previous.width) > 0.5,
             builds: max(0, next.buildCount - previous.buildCount),
             nativeChanged: previous.native != next.native)
        }
        return Measurement(
            startState: expectedStart,
            endState: state.visibility,
            startWidth: startWidth,
            endWidth: endWidth,
            startNative: startNative,
            endNative: endNative,
            frameCount: samples.count,
            widthChangingFrames: frameChanges.filter(\.widthChanged).count,
            nativeTransitionFrames: frameChanges.filter(\.nativeChanged).count,
            framesWithRowBuilds: frameChanges.filter { $0.builds > 0 }.count,
            rowBuildsDuringSamples: max(0, (samples.last?.buildCount ?? initialBuilds) - initialBuilds),
            maxRowBuildsInFrame: frameChanges.map(\.builds).max() ?? 0)
    }

    private static func report(_ result: Measurement, name: String) {
        print("iPad sidebar probe \(name): \(result.startState) → \(result.endState), "
            + "detail width \(Int(result.startWidth)) → \(Int(result.endWidth)), "
            + "primary \(result.startNative.primaryIsShown) → \(result.endNative.primaryIsShown) "
            + "(\(result.startNative.displayMode), \(result.startNative.primaryFrame) → "
            + "\(result.endNative.displayMode), \(result.endNative.primaryFrame)), "
            + "\(result.widthChangingFrames)/\(result.frameCount) sampled frames changed detail width, "
            + "\(result.nativeTransitionFrames) changed native split state, "
            + "\(result.framesWithRowBuilds) frames built rows, \(result.rowBuildsDuringSamples) total row builds, "
            + "max \(result.maxRowBuildsInFrame) builds/frame")
    }

    private static func transcriptCollectionView(in view: UIView) -> UICollectionView? {
        if let collection = view as? UICollectionView,
           collection.delegate is TranscriptList.Coordinator
        {
            return collection
        }
        for child in view.subviews {
            if let collection = self.transcriptCollectionView(in: child) { return collection }
        }
        return nil
    }

    private static func splitViewController(in controller: UIViewController) -> UISplitViewController? {
        if let split = controller as? UISplitViewController { return split }
        for child in controller.children {
            if let split = self.splitViewController(in: child) { return split }
        }
        if let presented = controller.presentedViewController {
            return self.splitViewController(in: presented)
        }
        return nil
    }

    fileprivate static func snapshot(_ split: UISplitViewController) -> NativeSplitSnapshot {
        let primaryIsShown: Bool
        if #available(iOS 26.0, *) {
            primaryIsShown = split.isShowing(.primary)
        } else {
            primaryIsShown = split.displayMode != .secondaryOnly
        }
        let primaryController = split.viewController(for: .primary)
        let primaryFrame = primaryController.flatMap { $0.isViewLoaded ? $0.view.frame : nil }
        return NativeSplitSnapshot(primaryIsShown: primaryIsShown,
                                   displayMode: String(describing: split.displayMode),
                                   primaryFrame: primaryFrame)
    }

    private struct Measurement {
        let startState: NavigationSplitViewVisibility
        let endState: NavigationSplitViewVisibility
        let startWidth: CGFloat
        let endWidth: CGFloat
        let startNative: NativeSplitSnapshot
        let endNative: NativeSplitSnapshot
        let frameCount: Int
        let widthChangingFrames: Int
        let nativeTransitionFrames: Int
        let framesWithRowBuilds: Int
        let rowBuildsDuringSamples: Int
        let maxRowBuildsInFrame: Int
    }
}

fileprivate struct NativeSplitSnapshot: Equatable {
    let primaryIsShown: Bool
    let displayMode: String
    let primaryFrame: CGRect?
}

@MainActor
@Observable
private final class SidebarSlideState {
    var visibility: NavigationSplitViewVisibility = .all

    func toggle() {
        withAnimation {
            self.visibility = SidebarToggle.toggled(self.visibility)
        }
    }
}

@MainActor
private struct SidebarSlideHost: View {
    @Bindable var state: SidebarSlideState
    let transcript: TranscriptList

    var body: some View {
        NavigationSplitView(columnVisibility: $state.visibility) {
                List { Text("Probe chat") }
            } detail: {
                self.transcript
                    .environment(\.sidebarToggle, SidebarToggle(isCollapsed: self.state.visibility == .detailOnly) {
                        self.state.toggle()
                    })
            }
    }
}

@MainActor
private final class DisplayFrameSampler: NSObject {
    struct Sample {
        let width: CGFloat
        let buildCount: Int
        let native: NativeSplitSnapshot
    }

    private weak var collection: UICollectionView?
    private let coordinator: TranscriptList.Coordinator
    private let split: UISplitViewController
    private var link: CADisplayLink?
    private(set) var samples: [Sample] = []
    private(set) var stableFrameCount = 0

    init(collection: UICollectionView, coordinator: TranscriptList.Coordinator, split: UISplitViewController) {
        self.collection = collection
        self.coordinator = coordinator
        self.split = split
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(self.captureFrame))
        self.link = link
        self.captureFrame()
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        self.link?.invalidate()
        self.link = nil
    }

    @objc private func captureFrame() {
        guard let collection = self.collection else { return }
        let width = collection.bounds.width
        let native = TranscriptSidebarSlideProbe.snapshot(self.split)
        if let previous = self.samples.last, abs(width - previous.width) <= 0.5, native == previous.native {
            self.stableFrameCount += 1
        } else {
            self.stableFrameCount = 0
        }
        self.samples.append(Sample(width: width,
                                   buildCount: self.coordinator.renderer.layoutBuildCount,
                                   native: native))
    }
}
#endif
