import Foundation
import SwiftUI
import Testing
@testable import PincerKit
@testable import PincerUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// #1093: an empty Generated Files, Files or Runs panel keeps its header (search field, filter picker) pinned at
/// the top, exactly where it sits when the panel has rows, instead of floating halfway down with the empty state.
/// Set `PINCER_SNAPSHOT_DIR` to also write each hosted state as a PNG.
@MainActor
@Suite("Panel empty states keep the header pinned (#1093)", .serialized, .timeLimit(.minutes(3)))
struct PanelEmptyStateLayoutHostedTests {
    static let panelSize = CGSize(width: 320, height: 800)
    /// The header sits right below the panel's top padding; anything lower means the content was centred.
    static let pinnedTopLimit: CGFloat = 60
    static let samePositionTolerance: CGFloat = 1

    // MARK: Fixtures

    private struct EmptyListError: Error {}

    private static func filesModel(_ key: String, files: Bool = false, fails: Bool = false) -> SessionFilesModel {
        SessionFilesModel(sessionKey: key, request: { method, _ in
            if fails { throw EmptyListError() }
            guard files, method == SessionFilesModel.listMethod else { return .object([:]) }
            return .object(["files": .array([.object(["path": "notes.md", "kind": "modified", "size": 12])])])
        })
    }

    /// The demo Gateway, connected, with a chat that has generated files and one that has none.
    private func demo() async throws -> (AppModel, GatewayStore, ScratchDefaults, filesKey: String, emptyKey: String) {
        let scratch = ScratchDefaults()
        GatewayProfileStore.save([.demo()], to: scratch.defaults)
        let app = AppModel(defaults: scratch.defaults, identity: UIFixtures.identity())
        let gateway = try #require(app.gateways.first)
        gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
        gateway.start(); gateway.reconnectIfNeeded()
        try #require(await eventually(timeout: .seconds(10)) { gateway.state.isConnected && gateway.bootstrapped })
        let filesKey = "agent:main:main"
        let main = gateway.assetsModel(for: filesKey)
        await main.refresh()
        try #require(!main.assets.isEmpty, "the demo main chat has generated files")
        var emptyKey: String?
        let candidates = gateway.sessions.values.filter { !$0.isSubagent && !$0.isPlaceholder && !$0.isArchived }.map(\.key).sorted()
        for key in candidates where key != filesKey {
            let model = gateway.assetsModel(for: key)
            await model.refresh()
            if model.loaded, model.assets.isEmpty { emptyKey = key; break }
        }
        return (app, gateway, scratch, filesKey, try #require(emptyKey, "a demo chat without generated files"))
    }

    // MARK: Generated Files

    @Test func assetsHeaderStaysPinnedWhenEmptyOrNoMatch() async throws {
        let (app, gateway, scratch, filesKey, emptyKey) = try await self.demo()
        defer { gateway.stop(); scratch.remove() }
        func panel(_ key: String) -> some View {
            AssetsPanel().environment(app).environment(gateway).environment(\.chatWindowKey, key).defaultAppStorage(gateway.defaults)
        }

        let withFiles = gateway.assetsModel(for: filesKey)
        let filled = try await PanelHost.measure(panel(filesKey), field: "Search files", snapshot: "assets-with-files") {
            withFiles.loaded && !withFiles.shown.isEmpty
        }
        let noMatch = try await PanelHost.measure(panel(filesKey), field: "Search files", snapshot: "assets-no-matching",
                                                  prepare: { withFiles.search = "zzz-no-such-file" }) {
            withFiles.loaded && withFiles.shown.isEmpty
        }
        withFiles.search = ""
        let emptyModel = gateway.assetsModel(for: emptyKey)
        let empty = try await PanelHost.measure(panel(emptyKey), field: "Search files", snapshot: "assets-empty") {
            emptyModel.loaded && emptyModel.assets.isEmpty
        }

        #expect(filled < Self.pinnedTopLimit, "with files the search field is at the top (\(filled)pt)")
        #expect(empty < Self.pinnedTopLimit, "No files yet: the search field stays at the top (\(empty)pt, \(filled)pt with files)")
        #expect(noMatch < Self.pinnedTopLimit, "No matching files: the search field stays at the top (\(noMatch)pt, \(filled)pt with files)")
        #expect(abs(empty - filled) <= Self.samePositionTolerance, "No files yet: header doesn't move (\(empty) vs \(filled))")
        #expect(abs(noMatch - filled) <= Self.samePositionTolerance, "No matching files: header doesn't move (\(noMatch) vs \(filled))")
    }

    // MARK: Files tab

    @Test func filesHeaderStaysPinnedWhenEmptyNoMatchOrFailed() async throws {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: UIFixtures.identity())
        gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
        defer { scratch.remove() }
        func panel(_ model: SessionFilesModel) -> some View {
            FilesPanelView(model: model, state: FilesSession()).environment(gateway).defaultAppStorage(gateway.defaults)
        }

        let withFiles = Self.filesModel("files", files: true)
        let filled = try await PanelHost.measure(panel(withFiles), field: "Search files", snapshot: "files-with-files") {
            withFiles.loaded && !withFiles.snapshot.isEmpty
        }
        let emptyModel = Self.filesModel("empty")
        let empty = try await PanelHost.measure(panel(emptyModel), field: "Search files", snapshot: "files-empty") {
            emptyModel.loaded && emptyModel.snapshot.isEmpty
        }
        let noMatchModel = Self.filesModel("nomatch")
        noMatchModel.setSearch("zzz-no-such-file")
        let noMatch = try await PanelHost.measure(panel(noMatchModel), field: "Search files", snapshot: "files-no-matching") {
            noMatchModel.loaded && noMatchModel.snapshot.isEmpty
        }
        let failedModel = Self.filesModel("failed", fails: true)
        let failed = try await PanelHost.measure(panel(failedModel), field: "Search files", snapshot: "files-error") {
            !failedModel.loaded && failedModel.error != nil
        }

        #expect(filled < Self.pinnedTopLimit, "with files the search field is at the top (\(filled)pt)")
        for (name, top) in [("No files yet", empty), ("No matching files", noMatch), ("Can't show files", failed)] {
            #expect(top < Self.pinnedTopLimit, "\(name): the search field stays at the top (\(top)pt, \(filled)pt with files)")
            #expect(abs(top - filled) <= Self.samePositionTolerance, "\(name): header doesn't move (\(top) vs \(filled))")
        }
    }

    // MARK: Runs

    @Test func runsPickerStaysPinnedWithNoChatSelected() async throws {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: UIFixtures.identity())
        gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
        defer { scratch.remove() }
        func panel(_ key: String?) -> some View {
            RunsPanel().environment(gateway).environment(\.chatWindowKey, key).defaultAppStorage(gateway.defaults)
        }
        let selected = try await PanelHost.measure(panel("agent:main:main"), segmented: true, snapshot: "runs-with-chat") { true }
        let none = try await PanelHost.measure(panel(nil), segmented: true, snapshot: "runs-no-chat") { gateway.focusedKey == nil }
        #expect(selected < Self.pinnedTopLimit, "with a chat the Tree/Timeline picker is at the top (\(selected)pt)")
        #expect(none < Self.pinnedTopLimit, "No chat selected: the picker stays at the top (\(none)pt, \(selected)pt with a chat)")
        #expect(abs(none - selected) <= Self.samePositionTolerance, "No chat selected: header doesn't move (\(none) vs \(selected))")
    }
}

/// Hosts a panel at a fixed, tall size and measures how far its search field (or segmented picker) sits below the top.
@MainActor
enum PanelHost {
    enum Failure: Error { case controlNotFound(String) }

    static func measure<V: View>(_ view: V, field placeholder: String? = nil, segmented: Bool = false, snapshot: String,
                                 prepare: () -> Void = {}, until ready: () -> Bool) async throws -> CGFloat {
        prepare()
        let size = PanelEmptyStateLayoutHostedTests.panelSize
        #if os(macOS)
        _ = NSApplication.shared
        let host = NSHostingView(rootView: AnyView(view))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        var top: CGFloat?
        let found = await eventually(timeout: .seconds(10)) {
            host.layoutSubtreeIfNeeded()
            guard ready() else { return false }
            top = self.top(in: host, placeholder: placeholder, segmented: segmented)
            return top != nil
        }
        // A few more passes so a late state change (empty view swapping in) lands before measuring.
        for _ in 0..<10 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        top = self.top(in: host, placeholder: placeholder, segmented: segmented)
        self.writeSnapshot(host, name: snapshot)
        guard found, let top else { throw Failure.controlNotFound(snapshot) }
        return top
        #else
        let controller = UIHostingController(rootView: AnyView(view))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState != .unattached }
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        let previous = scene?.windows.first(where: { $0.isKeyWindow })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        var top: CGFloat?
        let found = await eventually(timeout: .seconds(10)) {
            window.layoutIfNeeded()
            guard ready() else { return false }
            top = self.top(in: controller.view, placeholder: placeholder, segmented: segmented)
            return top != nil
        }
        for _ in 0..<10 { await Task.yield(); window.layoutIfNeeded() }
        top = self.top(in: controller.view, placeholder: placeholder, segmented: segmented)
        self.writeSnapshot(controller.view, name: snapshot)
        guard found, let top else { throw Failure.controlNotFound(snapshot) }
        // The safe area isn't part of the panel's own layout.
        return top - controller.view.safeAreaInsets.top
        #endif
    }

    #if os(macOS)
    private static func controls(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(self.controls) }

    private static func top(in host: NSView, placeholder: String?, segmented: Bool) -> CGFloat? {
        let control = self.controls(in: host).first { view in
            guard !view.isHiddenOrHasHiddenAncestor else { return false }
            if segmented { return view is NSSegmentedControl }
            guard let field = view as? NSTextField, field.isEditable else { return false }
            return placeholder == nil || field.placeholderString == placeholder
        }
        guard let control else { return nil }
        let rect = control.convert(control.bounds, to: host)
        return host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
    }

    /// `cacheDisplay` skips SwiftUI's layers, so this captures just the hosting window with `screencapture -l`
    /// (needs Screen Recording permission for the test runner; writes nothing without it).
    private static func writeSnapshot(_ view: NSView, name: String) {
        guard let dir = ProcessInfo.processInfo.environment["PINCER_SNAPSHOT_DIR"], !dir.isEmpty,
              let window = view.window else { return }
        window.display()
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                             url.appending(path: "\(name)-macos.png").path(percentEncoded: false)]
        try? capture.run()
        capture.waitUntilExit()
    }
    #else
    private static func controls(in view: UIView) -> [UIView] { [view] + view.subviews.flatMap(self.controls) }

    private static func top(in root: UIView, placeholder: String?, segmented: Bool) -> CGFloat? {
        let control = self.controls(in: root).first { view in
            guard !view.isHidden, view.window != nil else { return false }
            if segmented { return view is UISegmentedControl }
            guard let field = view as? UITextField else { return false }
            return placeholder == nil || field.placeholder == placeholder
        }
        guard let control else { return nil }
        return control.convert(control.bounds, to: root).minY
    }

    private static func writeSnapshot(_ view: UIView, name: String) {
        guard let dir = ProcessInfo.processInfo.environment["PINCER_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: url.appending(path: "\(name)-ios.png"))
    }
    #endif
}
