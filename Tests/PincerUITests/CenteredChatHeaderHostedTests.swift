#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import PincerKit
@testable import PincerUI

@MainActor
struct CenteredChatHeaderContent: View {
    let app: AppModel
    let gateway: GatewayStore
    var phase = ScenePhase.active
    var dynamicTypeSize = DynamicTypeSize.large
    var activityProbe: AvatarActivityProbe?
    var geometryProbe: CompactChatHeaderGeometryProbe?
    var topChromeProbe: ChatTopChromeGeometryProbe?
    var body: some View {
        NavigationStack {
            if let key = gateway.selectedKey {
                ChatView(chat: gateway.chat(for: key))
                    .modifier(ChatChrome())
            }
        }
        .environment(app)
        .environment(gateway)
        .defaultAppStorage(gateway.defaults)
        .environment(\.horizontalSizeClass, .compact)
        .environment(\.scenePhase, phase)
        .dynamicTypeSize(dynamicTypeSize)
        .environment(\.avatarActivityProbe, activityProbe)
        .environment(\.compactChatHeaderGeometryProbe, geometryProbe)
        .environment(\.chatTopChromeGeometryProbe, topChromeProbe)
    }
}

@MainActor
enum CenteredChatHeaderNativeFixtures {
    static func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }

    /// Inspect the actual UIKit accessibility tree, including SwiftUI's virtual elements.
    static func objects(_ root: UIView) -> [NSObject] {
        var result: [NSObject] = [], seen: Set<ObjectIdentifier> = []
        func append(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            if let view = object as? UIView {
                for child in view.subviews { append(child) }
            }
            let count = object.accessibilityElementCount()
            if count >= 0 && count < 512 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject { append(child) }
                }
            }
        }
        append(root)
        return result
    }
    static func identified(_ identifier: String, in window: UIWindow) -> [NSObject] {
        objects(window).filter { ($0 as? UIAccessibilityIdentification)?.accessibilityIdentifier == identifier }
    }
    static func frame(_ object: NSObject, in window: UIWindow) -> CGRect {
        if let view = object as? UIView { return view.convert(view.bounds, to: window) }
        return window.convert(object.accessibilityFrame, from: nil)
    }
    static func labels(_ window: UIWindow) -> [String] { objects(window).compactMap(\.accessibilityLabel) }

    struct Host {
        let controller: UIHostingController<CenteredChatHeaderContent>
        let window: UIWindow
        let previous: UIWindow?
        let geometry: CenteredHeaderGeometryRecorder
        let topChrome: CenteredHeaderTopGeometryRecorder
        init(app: AppModel, gateway: GatewayStore, width: CGFloat, height: CGFloat = 844, dynamicTypeSize: DynamicTypeSize = .large, phase: ScenePhase = .active, activityProbe: AvatarActivityProbe? = nil) {
            let geometry = CenteredHeaderGeometryRecorder()
            self.geometry = geometry
            let probe = CompactChatHeaderGeometryProbe { part, frame in geometry.frames[part] = frame }
            let topChrome = CenteredHeaderTopGeometryRecorder()
            self.topChrome = topChrome
            let topProbe = ChatTopChromeGeometryProbe { part, frame in topChrome.frames[part] = frame }
            controller = UIHostingController(rootView: CenteredChatHeaderContent(app: app, gateway: gateway, phase: phase, dynamicTypeSize: dynamicTypeSize, activityProbe: activityProbe, geometryProbe: probe, topChromeProbe: topProbe))
            controller.overrideUserInterfaceStyle = .light
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState != .unattached }
            previous = scene?.windows.first(where: { $0.isKeyWindow })
            if let scene { window = UIWindow(windowScene: scene) }
            else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height)) }
            window.frame = CGRect(x: 0, y: 0, width: width, height: height)
            window.rootViewController = controller
            window.makeKeyAndVisible()
        }
        func close() { window.isHidden = true; previous?.makeKeyAndVisible() }
    }
    static func paintedPixelCount(_ image: CGImage, crop: CGRect) -> Int {
        guard let cropped = image.cropping(to: crop), let context = CGContext(data: nil, width: cropped.width, height: cropped.height,
            bitsPerComponent: 8, bytesPerRow: cropped.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data else { return 0 }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: cropped.width * cropped.height * 4)
        var painted = 0
        for pixel in 0..<(cropped.width * cropped.height) {
            let offset = pixel * 4
            let difference = abs(Int(bytes[offset]) - Int(bytes[0])) + abs(Int(bytes[offset + 1]) - Int(bytes[1]))
                + abs(Int(bytes[offset + 2]) - Int(bytes[2]))
            if difference > 45 { painted += 1 }
        }
        return painted
    }
    static func snapshot(_ window: UIWindow, width: CGFloat, suffix: String, avatar: CGRect? = nil) throws {
        var renderedHierarchy = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            renderedHierarchy = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            if !renderedHierarchy { window.layer.render(in: context.cgContext) }
        }
        print("Centered header package capture drawHierarchy=\(renderedHierarchy); layer fallback is diagnostic only, real app screenshot supplies appearance proof")
        if renderedHierarchy, let avatar {
            let cgImage = try #require(image.cgImage)
            let scale = image.scale
            let upper = CGRect(x: avatar.minX * scale, y: avatar.minY * scale,
                               width: avatar.width * scale, height: avatar.height * scale / 2)
            #expect(paintedPixelCount(cgImage, crop: upper) > 30,
                    "The actual painted upper avatar is visible over the native bar, not clipped or covered")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pincer-centered-header-\(Int(width))-\(suffix)\(renderedHierarchy ? "" : "-layer-diagnostic").png")
        try #require(image.pngData()).write(to: url)
        print("Centered header actual full UIKit host PNG: \(url.path)")
    }
}

@MainActor
final class CenteredHeaderGeometryRecorder { var frames: [CompactChatHeaderGeometryProbe.Part: CGRect] = [:] }

@MainActor
final class CenteredHeaderTopGeometryRecorder { var frames: [ChatTopChromeGeometryProbe.Part: CGRect] = [:] }

@MainActor
private final class CenteredHeaderActivityRecorder { var last: Bool?; var sawActive = false }

@MainActor
private struct CenteredChatHeaderHostedTests {
    private func connected(_ app: AppModel) async throws -> GatewayStore {
        let gateway = app.add(.demo(), secret: nil)
        gateway.cacheRoot = nil
        gateway.notifier = nil
        gateway.defaults.set(true, forKey: AvatarSettings.animatedKey)
        try #require(await eventually(timeout: .seconds(30)) {
            gateway.state.isConnected && gateway.sessions["agent:main:dashboard:trip"] != nil
                && gateway.sessions["agent:main:dashboard:garden"] != nil
        })
        for key in ["agent:main:dashboard:trip", "agent:main:dashboard:garden"] {
            await gateway.chat(for: key).load()
            await gateway.chat(for: key).refreshBranches()
        }
        return gateway
    }

    func actualCenteredIdentityAtAllCompactWidths() async throws {
        let scratch = ScratchDefaults()
        let app = AppModel(defaults: scratch.defaults)
        defer { for gateway in app.gateways { app.remove(gateway.id) }; scratch.remove() }
        let gateway = try await connected(app)
        for width: CGFloat in [320, 390, 430] {
            gateway.selectedKey = "agent:main:dashboard:trip"
            let host = CenteredChatHeaderNativeFixtures.Host(app: app, gateway: gateway, width: width)
            defer { host.close() }
            for key in ["agent:main:dashboard:trip", "agent:main:dashboard:garden", "agent:main:dashboard:trip"] {
                gateway.selectedKey = key
                let ready = await eventually(timeout: .seconds(15)) {
                    host.window.layoutIfNeeded()
                    return host.geometry.frames.count == 3 && host.geometry.frames.values.allSatisfy { $0.width > 0 && $0.height > 0 }
                }
                if !ready {
                    print("Centered header actual frame probe failed selected=\(key) frames=\(host.geometry.frames)")
                    try CenteredChatHeaderNativeFixtures.snapshot(host.window, width: width, suffix: "failed-geometry")
                }
                try #require(ready, "Actual finished header views must report their native global geometry")
                let avatar = try #require(host.geometry.frames[.avatar])
                let title = try #require(host.geometry.frames[.title])
                let reservation = try #require(host.geometry.frames[.reservation])
                #expect(reservation.height == 60 && title.maxY <= reservation.maxY + 1,
                        "Actual title must fit the reserved region rather than overlap transcript content")
                print("Centered header actual geometry width=\(width) key=\(key) avatar=\(avatar) title=\(title) reservation=\(reservation); title content is verified separately by real chatTitle unit and full-app screenshot")
                #expect(abs(host.window.bounds.width - width) < 1)
                #expect(abs(avatar.width - 64) < 1 && abs(avatar.height - 64) < 1)
                #expect(abs(avatar.midX - host.window.bounds.midX) <= 1 && abs(title.midX - host.window.bounds.midX) <= 1,
                        "Actual identity stays centered regardless of branch/action availability and side widths")
                #expect(title.minY >= avatar.maxY && title.maxY < 180)
                let bars = CenteredChatHeaderNativeFixtures.views(host.window).compactMap { $0 as? UINavigationBar }.filter { !$0.isHidden && $0.bounds.width > 0 }
                let bar = try #require(bars.first)
                let barFrame = bar.convert(bar.bounds, to: host.window)
                #expect(avatar.minY < barFrame.maxY && avatar.maxY > barFrame.maxY,
                        "The actual large avatar spans the native bar and reserved content region")
                #expect(bar.topItem?.title?.isEmpty != false, "The capsule is the current visible title")
                try CenteredChatHeaderNativeFixtures.snapshot(host.window, width: width, suffix: key.contains("garden") ? "garden" : "trip", avatar: avatar)
            }
        }
    }

    func actualAccessibilityAndLandscapeHeaderLeaveUsableChatGeometry() async throws {
        let scratch = ScratchDefaults()
        let app = AppModel(defaults: scratch.defaults)
        defer { for gateway in app.gateways { app.remove(gateway.id) }; scratch.remove() }
        let gateway = try await connected(app)
        gateway.selectedKey = "agent:main:dashboard:trip"
        for (width, height, type) in [(CGFloat(320), CGFloat(844), DynamicTypeSize.accessibility5), (430, 390, .large)] {
            let host = CenteredChatHeaderNativeFixtures.Host(app: app, gateway: gateway, width: width,
                                                           height: height, dynamicTypeSize: .large)
            defer { host.close() }
            try #require(await eventually(timeout: .seconds(15)) {
                host.geometry.frames.count == 3 && host.geometry.frames.values.allSatisfy { $0.height > 0 }
                    && CenteredChatHeaderNativeFixtures.views(host.window).contains { $0 is ComposerUITextView && $0.bounds.height > 0 }
            })
            let baselineTitle = try #require(host.geometry.frames[.title])
            let baselineReservation = try #require(host.geometry.frames[.reservation])
            if type == .accessibility5 {
                var content = host.controller.rootView
                content.dynamicTypeSize = type
                host.controller.rootView = content
                try #require(await eventually(timeout: .seconds(15)) {
                    host.window.layoutIfNeeded()
                    host.controller.view.layoutIfNeeded()
                    return (host.geometry.frames[.title]?.height ?? 0) > baselineTitle.height
                        && (host.geometry.frames[.reservation]?.height ?? 0) > baselineReservation.height
                }, "The same actual host must report its larger finished title and reservation")
            }
            await Task.yield()
            host.window.layoutIfNeeded()
            await Task.yield()
            host.controller.view.layoutIfNeeded()
            let avatar = try #require(host.geometry.frames[.avatar])
            let title = try #require(host.geometry.frames[.title])
            let reservation = try #require(host.geometry.frames[.reservation])
            print("Centered header measured typography type=\(type) host=\(width)x\(height) avatar=\(avatar) title=\(title) reservation=\(reservation)")
            #expect(abs(avatar.width - 64) < 1 && abs(avatar.height - 64) < 1)
            #expect(abs(avatar.midX - width / 2) <= 1 && abs(title.midX - width / 2) <= 1)
            #expect(title.minY >= avatar.maxY && title.maxY <= reservation.maxY + 1,
                    "Actual largest accessibility or landscape title must fit its measured reservation")
            if type == .accessibility5 { #expect(reservation.height > 60, "Actual accessibility typography needs more space than the default reservation") }
            let composer = try #require(CenteredChatHeaderNativeFixtures.views(host.window).compactMap { $0 as? ComposerUITextView }.first { $0.bounds.height > 0 })
            let composerFrame = composer.convert(composer.bounds, to: host.window)
            #expect(composerFrame.minY >= title.maxY && composerFrame.maxY <= host.window.bounds.maxY + 1,
                    "The actual composer remains visible below expanded identity chrome")
            let transcript = try #require(CenteredChatHeaderNativeFixtures.views(host.window).compactMap { $0 as? UICollectionView }.first { $0.bounds.height > 0 })
            #expect(transcript.bounds.height > 44, "The actual compact transcript retains a usable viewport")
            try CenteredChatHeaderNativeFixtures.snapshot(host.window, width: width,
                suffix: type == .accessibility5 ? "accessibility5" : "landscape", avatar: avatar)
            if type == .accessibility5 {
                var content = host.controller.rootView
                content.dynamicTypeSize = .large
                host.controller.rootView = content
                try #require(await eventually(timeout: .seconds(15)) {
                    host.window.layoutIfNeeded()
                    host.controller.view.layoutIfNeeded()
                    guard let title = host.geometry.frames[.title], let reservation = host.geometry.frames[.reservation] else { return false }
                    return abs(title.height - baselineTitle.height) < 1
                        && abs(reservation.height - baselineReservation.height) < 1
                }, "Same-host AX5→large must shrink both real finished title and reserved space")
                await Task.yield()
                host.window.layoutIfNeeded()
                let shrunkTitle = try #require(host.geometry.frames[.title])
                let shrunkReservation = try #require(host.geometry.frames[.reservation])
                #expect(shrunkTitle.maxY <= shrunkReservation.maxY + 1)
                #expect(abs(shrunkReservation.height - baselineReservation.height) < 1,
                        "The actual host must return to its measured baseline without an excess header gap")
                #expect(host.geometry.frames[.avatar] == avatar)
                print("Centered header actual same-host shrink title=\(shrunkTitle) reservation=\(shrunkReservation) baseline=\(baselineReservation)")
                try CenteredChatHeaderNativeFixtures.snapshot(host.window, width: width, suffix: "accessibility5-to-large", avatar: avatar)
            }
        }
    }

    func actualAvatarAdmissionRespectsInactiveAndSystemMotion() async throws {
        let scratch = ScratchDefaults()
        let app = AppModel(defaults: scratch.defaults)
        defer { for gateway in app.gateways { app.remove(gateway.id) }; scratch.remove() }
        let gateway = try await connected(app)
        gateway.selectedKey = "agent:main:dashboard:trip"
        for phase in [ScenePhase.inactive, .active] {
            let recorder = CenteredHeaderActivityRecorder()
            let probe = AvatarActivityProbe(seed: "main") { recorder.last = $0; recorder.sawActive = recorder.sawActive || $0 }
            let host = CenteredChatHeaderNativeFixtures.Host(app: app, gateway: gateway, width: 390,
                phase: phase, activityProbe: probe)
            defer { host.close() }
            let shouldAnimate = !UIAccessibility.isReduceMotionEnabled && phase == .active
            try #require(await eventually(timeout: .seconds(15)) {
                recorder.last == shouldAnimate && host.geometry.frames[.avatar]?.width == 64
            }, "Actual avatar render branch must report environment-controlled animation admission")
            if !shouldAnimate { #expect(!recorder.sawActive) }
            let avatar = try #require(host.geometry.frames[.avatar])
            #expect(abs(avatar.width - 64) < 1 && abs(avatar.height - 64) < 1)
            try CenteredChatHeaderNativeFixtures.snapshot(host.window, width: 390,
                suffix: phase == .inactive ? "inactive" : "system-motion", avatar: avatar)
        }
    }

    func compactOverflowUsesOneActualNativeBarAction() async throws {
        let scratch = ScratchDefaults()
        let app = AppModel(defaults: scratch.defaults)
        defer { for gateway in app.gateways { app.remove(gateway.id) }; scratch.remove() }
        let gateway = try await connected(app)
        gateway.selectedKey = "agent:main:dashboard:garden"
        let host = CenteredChatHeaderNativeFixtures.Host(app: app, gateway: gateway, width: 390)
        defer { host.close() }
        for key in ["agent:main:dashboard:garden", "agent:main:dashboard:trip", "agent:main:dashboard:garden"] {
            gateway.selectedKey = key
            try #require(await eventually(timeout: .seconds(15)) {
                host.geometry.frames.count == 3 && CenteredChatHeaderNativeFixtures.views(host.window)
                    .contains { $0 is UINavigationBar && $0.bounds.width > 0 }
            })
            let bar = try #require(CenteredChatHeaderNativeFixtures.views(host.window).compactMap { $0 as? UINavigationBar }.first { $0.bounds.width > 0 && !$0.isHidden })
            let frames = CenteredChatHeaderNativeFixtures.views(bar).filter {
                let name = String(describing: type(of: $0))
                return name == "_UIButtonBarButton" || name.contains("UIKitBarItemHost")
            }.map { $0.convert($0.bounds, to: bar) }.filter { $0.maxX > bar.bounds.midX }
            #expect(frames.count == 1 && frames.allSatisfy { $0.width > 1 && $0.height > 1 },
                    "Actual compact native bar retains one visible overflow and no blank Model/Branch/Runs slots")
        }
        // SwiftUI's package host does not expose its deferred menu through UIButton.menu.
        // Actual Model/Branch/Runs activation is verified in the full app UI test, separately
        // from this strict public native-bar geometry regression.
    }

    func fullChatFindAndApprovalsStayBelowIdentity() async throws {
        let scratch = ScratchDefaults()
        let app = AppModel(defaults: scratch.defaults)
        defer { for gateway in app.gateways { app.remove(gateway.id) }; scratch.remove() }
        let gateway = try await connected(app)
        let key = "agent:main:dashboard:trip"
        gateway.selectedKey = key
        let chat = gateway.chat(for: key)
        let host = CenteredChatHeaderNativeFixtures.Host(app: app, gateway: gateway, width: 390)
        defer { host.close() }
        try #require(await eventually(timeout: .seconds(15)) {
            (host.geometry.frames[.title]?.height ?? 0) > 0
        })
        _ = await chat.sendMessage("approve", includeLocation: false)
        try #require(await eventually(timeout: .seconds(20)) { gateway.approvals.contains { $0.sessionKey == key } },
                     "Real Demo approval event must populate the actual chat banner")
        // Inject the production request consumed by ChatView.onChange. Full route activation
        // is verified in the real app UI test; package-host AppModel.open also clears OS
        // notifications, whose bundle proxy is unavailable in this UIKit test process.
        app.findRequest = FindRequest(target: Notifier.Target(gatewayId: gateway.id, sessionKey: key), query: "trip", match: nil)
        try #require(await eventually(timeout: .seconds(15)) {
            (host.topChrome.frames[.find]?.height ?? 0) > 0 && (host.topChrome.frames[.approvals]?.height ?? 0) > 0
        }, "Real Find presentation and Demo approval must report actual finished control frames")
        let title = try #require(host.geometry.frames[.title])
        let find = try #require(host.topChrome.frames[.find])
        let approvals = try #require(host.topChrome.frames[.approvals])
        #expect(find.minY >= title.maxY && approvals.minY >= title.maxY,
                "Actual finished Find and approval chrome remain below the identity")
        #expect(find.minY >= approvals.maxY - 1)
        let tables = CenteredChatHeaderNativeFixtures.views(host.window).compactMap { $0 as? UICollectionView }.filter { !$0.isHidden && $0.bounds.height > 0 }
        let table = try #require(tables.first, "The full chat must retain its actual transcript viewport")
        try #require(await eventually(timeout: .seconds(15)) {
            table.adjustedContentInset.top >= approvals.height + find.height - 1
        }, "Actual transcript inset must reserve painted Find and approval controls")
        #expect(table.bounds.height > 200)
        try CenteredChatHeaderNativeFixtures.snapshot(host.window, width: 390, suffix: "find-approval")
    }
}

@MainActor
extension TranscriptUIKitHostedTests {
    @Test(.timeLimit(.minutes(2))) func centeredChatIdentityUsesActualCompactGeometry() async throws {
        try await CenteredChatHeaderHostedTests().actualCenteredIdentityAtAllCompactWidths()
    }
    @Test(.timeLimit(.minutes(2))) func centeredChatIdentityFitsAccessibilityAndLandscape() async throws {
        try await CenteredChatHeaderHostedTests().actualAccessibilityAndLandscapeHeaderLeaveUsableChatGeometry()
    }
    @Test(.timeLimit(.minutes(2))) func centeredChatIdentityPreservesActualAnimationAdmission() async throws {
        try await CenteredChatHeaderHostedTests().actualAvatarAdmissionRespectsInactiveAndSystemMotion()
    }
    @Test(.timeLimit(.minutes(2))) func centeredChatIdentityKeepsOneNativeOverflowAction() async throws {
        try await CenteredChatHeaderHostedTests().compactOverflowUsesOneActualNativeBarAction()
    }
    @Test(.timeLimit(.minutes(2))) func centeredChatIdentityPreservesFullChatFindAndApprovalGeometry() async throws {
        try await CenteredChatHeaderHostedTests().fullChatFindAndApprovalsStayBelowIdentity()
    }
}
#endif
