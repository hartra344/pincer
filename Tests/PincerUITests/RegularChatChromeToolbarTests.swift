#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import PincerKit
@testable import PincerUI

/// #1088: the trailing glass group of the regular-width (iPad) chat header, as UIKit actually lays it
/// out from the production `ChatChrome`: Runs, Browser, branch, model, thinking level and Chat Options.
@MainActor
struct RegularChatChromeHost: View {
    let app: AppModel
    let gateway: GatewayStore

    var body: some View {
        NavigationStack {
            Text("Regular chat chrome geometry")
                .modifier(ChatChrome())
        }
        .environment(self.app)
        .environment(self.gateway)
        .defaultAppStorage(self.gateway.defaults)
        .environment(\.horizontalSizeClass, .regular)
    }
}

@MainActor
struct RegularChatChromeToolbarTests {
    @MainActor
    struct Host {
        let controller: UIHostingController<RegularChatChromeHost>
        let window: UIWindow
        let previous: UIWindow?

        init(app: AppModel, gateway: GatewayStore, width: CGFloat, height: CGFloat) {
            let controller = UIHostingController(rootView: RegularChatChromeHost(app: app, gateway: gateway))
            controller.overrideUserInterfaceStyle = .light
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState != .unattached }
            self.previous = scene?.windows.first(where: { $0.isKeyWindow })
            let window: UIWindow
            if let scene { window = UIWindow(windowScene: scene) }
            else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height)) }
            window.frame = CGRect(x: 0, y: 0, width: width, height: height)
            window.rootViewController = controller
            self.controller = controller
            self.window = window
            window.makeKeyAndVisible()
        }

        func close() { self.window.isHidden = true; self.previous?.makeKeyAndVisible() }
    }

    /// One trailing control as UIKit placed it, and where its pixels actually landed.
    struct Item: CustomStringConvertible {
        let label: String
        let frame: CGRect
        /// Bounding box of the control's painted (non-glass) pixels, in bar coordinates.
        let ink: CGRect?
        var description: String { "\(self.label.isEmpty ? "?" : self.label) frame=\(self.frame.integral) ink=\(self.ink.map { "\($0.integral)" } ?? "nil")" }
    }

    struct Geometry: CustomStringConvertible {
        let width: CGFloat
        let bar: CGRect
        let title: CGRect?
        let leadingGroup: CGRect?
        let group: CGRect
        let ink: CGRect
        let items: [Item]
        var leadingInset: CGFloat { self.ink.minX - self.group.minX }
        var trailingInset: CGFloat { self.group.maxX - self.ink.maxX }
        var trailingMargin: CGFloat { self.bar.maxX - self.group.maxX }
        var leadingMargin: CGFloat? { self.leadingGroup.map { $0.minX - self.bar.minX } }
        var description: String {
            "width=\(Int(self.width)) bar=\(self.bar.integral) title=\(self.title.map { "\($0.integral)" } ?? "nil") leadingGroup=\(self.leadingGroup.map { "\($0.integral)" } ?? "nil") group=\(self.group) ink=\(self.ink) insets(leading=\(self.leadingInset), trailing=\(self.trailingInset)) margins(leading=\(self.leadingMargin.map { "\($0)" } ?? "nil"), trailing=\(self.trailingMargin)) inkMidY=\(self.ink.midY) groupMidY=\(self.group.midY) titleMidY=\(self.title.map { "\($0.midY)" } ?? "nil")\n    " + self.items.map(\.description).joined(separator: "\n    ")
        }
    }

    private static func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(self.descendants) }
    private static func typeName(_ view: UIView) -> String { String(describing: type(of: view)) }

    static func shotsDirectory() -> URL {
        if let path = ProcessInfo.processInfo.environment["PINCER_SHOTS_DIR"], !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        return FileManager.default.temporaryDirectory
    }

    /// Painted pixels. An offscreen `drawHierarchy` leaves the glass itself transparent and draws vibrant
    /// glyphs as translucent white, so anything with real alpha is a control's content.
    private static func inkBox(_ image: CGImage, scale: CGFloat, in rect: CGRect) -> CGRect? {
        let crop = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        guard let cropped = image.cropping(to: crop),
              let context = CGContext(data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8,
                                      bytesPerRow: cropped.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: cropped.width * cropped.height * 4)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<cropped.height {
            for x in 0..<cropped.width {
                let offset = (y * cropped.width + x) * 4
                let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2]), a = Int(bytes[offset + 3])
                _ = (r, g, b)
                guard a > 60 else { continue }
                // CGContext rows run bottom-up.
                let row = cropped.height - 1 - y
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: rect.minX + CGFloat(minX) / scale, y: rect.minY + CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    static func measure(app: AppModel, gateway: GatewayStore, key: String, width: CGFloat, height: CGFloat = 1024,
                        expectedLabels: [String], name: String) async throws -> Geometry {
        gateway.selectedKey = key
        let host = Host(app: app, gateway: gateway, width: width, height: height)
        defer { host.close() }
        let window = host.window
        func controllers(_ c: UIViewController) -> [UIViewController] { [c] + c.children.flatMap(controllers) }
        func findBar() -> UINavigationBar? {
            var bars = self.descendants(window).compactMap { $0 as? UINavigationBar }
            for case let nav as UINavigationController in controllers(host.controller) where !bars.contains(where: { $0 === nav.navigationBar }) {
                bars.append(nav.navigationBar)
            }
            return bars.first { $0.bounds.width > 0 && $0.topItem != nil }
        }
        // Hosted windows don't populate accessibility labels, so count the rendered trailing item hosts.
        func labels() -> [String] {
            guard let bar = findBar() else { return [] }
            let views = self.descendants(bar)
            guard let trailing = views.filter({ ["UIPlatformGlassInteractionView", "PlatterGlassView"].contains(self.typeName($0)) && $0.bounds.width > 1 })
                .map({ $0.convert($0.bounds, to: bar) }).max(by: { $0.maxX < $1.maxX }) else { return [] }
            return views.filter {
                let type = self.typeName($0)
                return (type.contains("UIKitBarItemHost") || type == "_UIButtonBarButton") && $0.bounds.width > 1 && $0.bounds.height > 1
                    && trailing.intersects($0.convert($0.bounds, to: bar))
            }.map { self.typeName($0) }
        }
        let ready = await eventually(timeout: .seconds(20)) {
            window.layoutIfNeeded()
            host.controller.view.layoutIfNeeded()
            // When the group doesn't fit, UIKit folds the model and thinking items into the overflow, leaving three controls.
            return findBar() != nil && labels().count >= min(3, expectedLabels.count)
        }
        _ = await eventually(timeout: .seconds(3)) {
            window.layoutIfNeeded()
            return labels().count >= expectedLabels.count
        }
        // Let the glass group settle after its items change size.
        try await Task.sleep(for: .milliseconds(600))
        window.layoutIfNeeded()
        let bar = try #require(findBar(), "the NavigationStack installs its native bar")
        if !ready {
            for view in self.descendants(window).prefix(300) {
                print("  #1088 window view \(self.typeName(view)) frame=\(view.convert(view.bounds, to: window)) label=\(view.accessibilityLabel ?? "nil")")
            }
        }
        try #require(ready, "bar=\(findBar().map { "\($0.frame)" } ?? "nil") trailing controls \(expectedLabels) appear; saw \(labels())")

        // Render the whole window (glass and vibrant glyphs only composite correctly there), then crop to the bar.
        let barInWindow = bar.convert(bar.bounds, to: window)
        let image = UIGraphicsImageRenderer(bounds: bar.bounds).image { context in
            let drawRect = CGRect(x: -barInWindow.minX, y: -barInWindow.minY, width: window.bounds.width, height: window.bounds.height)
            if !window.drawHierarchy(in: drawRect, afterScreenUpdates: true) { bar.layer.render(in: context.cgContext) }
        }
        let prefix = ProcessInfo.processInfo.environment["PINCER_SHOTS_PREFIX"].flatMap { $0.isEmpty ? nil : $0 } ?? "before"
        let url = self.shotsDirectory().appendingPathComponent("\(prefix)-hosted-\(name)-\(Int(width)).png")
        try #require(image.pngData()).write(to: url)
        print("#1088 hosted bar snapshot: \(url.path)")
        let cgImage = try #require(image.cgImage)

        let views = self.descendants(bar)
        let glass = views.filter { ["UIPlatformGlassInteractionView", "PlatterGlassView"].contains(self.typeName($0)) && $0.bounds.width > 1 }
            .map { $0.convert($0.bounds, to: bar) }
        let group = try #require(glass.max { $0.maxX < $1.maxX }, "a trailing glass group exists; glass=\(glass)")
        let leadingGroup = glass.filter { $0 != group }.min { $0.minX < $1.minX }
        let hosts = views.filter {
            let type = self.typeName($0)
            return (type.contains("UIKitBarItemHost") || type == "_UIButtonBarButton") && $0.bounds.width > 1 && $0.bounds.height > 1
        }
        var items: [Item] = []
        for view in hosts {
            let frame = view.convert(view.bounds, to: bar)
            guard group.intersects(frame) else { continue }
            if items.contains(where: { $0.frame.contains(frame) || frame.contains($0.frame) }) {
                items.removeAll { frame.contains($0.frame) && $0.frame != frame }
                if items.contains(where: { $0.frame.contains(frame) }) { continue }
            }
            items.append(Item(label: "", frame: frame, ink: self.inkBox(cgImage, scale: image.scale, in: frame.intersection(group))))
        }
        items.sort { $0.frame.minX < $1.frame.minX }
        let names = items.count < expectedLabels.count ? expectedLabels.filter { $0 != "Model" && $0 != "Thinking" } : expectedLabels
        items = zip(items, names + Array(repeating: "", count: max(0, items.count - names.count))).map {
            Item(label: $1, frame: $0.frame, ink: $0.ink)
        }
        let ink = try #require(self.inkBox(cgImage, scale: image.scale, in: group.insetBy(dx: 0, dy: 4)), "the trailing group paints its controls")
        let title = views.compactMap { $0 as? UILabel }.filter { !$0.isHidden && ($0.text?.isEmpty == false) && $0.window != nil }
            .map { $0.convert($0.bounds, to: bar) }.first { $0.midX < group.minX && $0.minX > (leadingGroup?.maxX ?? 0) }
        let geometry = Geometry(width: width, bar: bar.bounds, title: title, leadingGroup: leadingGroup, group: group, ink: ink, items: items)
        print("#1088 \(name) \(geometry)")
        for view in views where view.bounds.width > 0 && view.convert(view.bounds, to: bar).maxX > bar.bounds.midX {
            print("  native \(self.typeName(view)) frame=\(view.convert(view.bounds, to: bar)) label=\(view.accessibilityLabel ?? "nil")")
        }
        return geometry
    }

    static func connected(_ app: AppModel) async throws -> GatewayStore {
        let gateway = app.add(.demo(), secret: nil)
        gateway.cacheRoot = nil
        gateway.notifier = nil
        let keys = [Self.mainKey, Self.branchedKey, Self.runningKey]
        try #require(await eventually(timeout: .seconds(30)) {
            gateway.state.isConnected && keys.allSatisfy { gateway.sessions[$0] != nil }
        }, "seeded Demo chats are listed")
        for key in keys {
            await gateway.chat(for: key).load()
            await gateway.chat(for: key).refreshBranches()
        }
        try #require(gateway.chat(for: Self.branchedKey).branchHeaderChip != nil)
        try #require(gateway.hasRuns(sessionKey: Self.runningKey))
        return gateway
    }

    static let mainKey = "agent:main:dashboard:trip"
    static let branchedKey = "agent:main:dashboard:garden"
    static let runningKey = "agent:research:dashboard:launch-plan"
    static let longModel = "anthropic/claude-opus-5.5-extended-thinking-preview-2026-10-29"
    /// Detail-column widths: full-screen iPad Pro 13" landscape, 11" landscape, 13" with sidebar,
    /// 11" portrait, mini portrait, Split View halves and Slide Over-ish.
    static let widths: [CGFloat] = [1366, 1194, 1024, 834, 744, 507]

    /// The invariants #1088 broke, checked on one measured header.
    static func expectAligned(_ geometry: Geometry, _ context: String) {
        let g = geometry
        #expect(g.leadingInset >= 6 && g.trailingInset >= 6,
                "\(context): the group's controls keep at least 6pt of glass on both ends (leading \(g.leadingInset), trailing \(g.trailingInset))")
        #expect(abs(g.leadingInset - g.trailingInset) <= 4,
                "\(context): the controls sit centred in their glass group (leading inset \(g.leadingInset) vs trailing \(g.trailingInset))")
        #expect(g.group.minX >= g.bar.minX && g.trailingMargin >= 8,
                "\(context): the group stays inside the bar with a standard trailing margin (\(g.trailingMargin)), group \(g.group)")
        if let leadingGroup = g.leadingGroup {
            #expect(g.group.minX >= leadingGroup.maxX + 8,
                    "\(context): the trailing group \(g.group) doesn't run into the leading controls \(leadingGroup)")
        }
        if let leading = g.leadingMargin {
            #expect(abs(leading - g.trailingMargin) <= 4,
                    "\(context): trailing margin \(g.trailingMargin) matches the leading group's margin \(leading)")
        }
        #expect(abs(g.ink.midY - g.group.midY) <= 2,
                "\(context): the controls are vertically centred in the glass (ink midY \(g.ink.midY) vs group \(g.group.midY))")
        for item in g.items {
            if let ink = item.ink {
                #expect(ink.minX >= item.frame.minX - 0.5 && ink.maxX <= item.frame.maxX + 0.5,
                        "\(context): \(item.label)'s pixels stay inside its toolbar item (\(item))")
                #expect(abs(ink.midY - g.group.midY) <= 2.5,
                        "\(context): \(item.label) is vertically centred with the group (ink midY \(ink.midY) vs \(g.group.midY))")
            }
        }
        for (a, b) in zip(g.items, g.items.dropFirst()) {
            if let left = a.ink, let right = b.ink {
                #expect(right.minX - left.maxX >= 10,
                        "\(context): \(a.label) and \(b.label) keep a visible gap (\(right.minX - left.maxX))")
            }
        }
    }

    func trailingGroupIsAlignedAtRegularWidths() async throws {
        let scratch = ScratchDefaults()
        let app = AppModel(defaults: scratch.defaults)
        defer { for gateway in app.gateways { app.remove(gateway.id) }; scratch.remove() }
        let gateway = try await Self.connected(app)

        let cases: [(key: String, name: String, labels: [String])] = [
            (Self.runningKey, "runs", ["Runs", "Browser", "Model", "Thinking", "Chat Options"]),
            (Self.branchedKey, "branch", ["Browser", "Branch", "Model", "Thinking", "Chat Options"]),
        ]
        for width in Self.widths {
            for c in cases {
                let geometry = try await Self.measure(app: app, gateway: gateway, key: c.key, width: width,
                                                      expectedLabels: c.labels, name: c.name)
                Self.expectAligned(geometry, "\(c.name) @\(Int(width))pt")
            }
        }

        // A long model name and an expensive (warning-tinted) thinking level.
        let row = try #require(gateway.sessions[Self.runningKey])
        guard case var .object(fields) = row.raw else { Issue.record("row is an object"); return }
        fields["model"] = .string(Self.longModel)
        fields.removeValue(forKey: "modelProvider")
        fields["thinkingLevel"] = .string("xhigh")
        gateway.setSession(SessionRow(.object(fields)), for: Self.runningKey)
        for width in Self.widths {
            let geometry = try await Self.measure(app: app, gateway: gateway, key: Self.runningKey, width: width,
                                                  expectedLabels: ["Runs", "Browser", "Model", "Thinking", "Chat Options"], name: "long-model")
            Self.expectAligned(geometry, "long model @\(Int(width))pt")
            if width >= 744 {
                #expect(geometry.items.count == 5,
                        "long model @\(Int(width))pt: a long model name truncates instead of pushing the model and thinking pickers into the overflow menu (\(geometry.items.count) trailing controls, group \(geometry.group))")
            }
            if let model = geometry.items.first(where: { $0.label == "Model" }) {
                // The bounded title plus the picker's icon, indicator and padding.
                #expect(model.frame.width <= ChatToolbarLayout.modelLabelMaxWidth + 80,
                        "long model @\(Int(width))pt: the model picker stays bounded (\(model.frame.width)pt)")
            }
            #expect(geometry.group.minX > (geometry.title?.maxX ?? geometry.leadingGroup?.maxX ?? 0),
                    "long model @\(Int(width))pt: the trailing group doesn't run into the title or the leading controls")
        }
    }
}

@MainActor
extension TranscriptUIKitHostedTests {
    @Test(.timeLimit(.minutes(4)))
    func regularChatChromeTrailingGroupIsAligned() async throws {
        try await RegularChatChromeToolbarTests().trailingGroupIsAlignedAtRegularWidths()
    }
}
#endif
