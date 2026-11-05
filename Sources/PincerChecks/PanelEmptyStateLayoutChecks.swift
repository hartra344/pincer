#if os(macOS)
import AppKit
import Foundation
import SwiftUI
@testable import PincerKit
@testable import PincerUI

// #1093: an empty Generated Files, Files or Runs panel keeps its header pinned at the top, where it sits with rows,
// instead of letting the empty state's short content centre the whole column halfway down a tall panel.

private let pelSize = NSSize(width: 320, height: 800)
private let pelPinnedTop: CGFloat = 60

private struct PELFailure: Error {}

private func pelViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(pelViews) }

/// Points from the panel's top to its search field (or segmented picker), once `ready` holds; nil if never found.
@MainActor
private func pelHeaderTop<V: View>(_ view: V, segmented: Bool = false, label: String, prepare: () -> Void = {},
                                   until ready: () -> Bool) async -> CGFloat? {
    prepare()
    let host = NSHostingView(rootView: AnyView(view))
    host.sizingOptions = []
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: pelSize), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: pelSize)
    defer { window.contentView = nil; window.close() }
    func measure() -> CGFloat? {
        host.layoutSubtreeIfNeeded()
        let control = pelViews(host).first { view in
            guard !view.isHiddenOrHasHiddenAncestor else { return false }
            if segmented { return view is NSSegmentedControl }
            return (view as? NSTextField).map { $0.isEditable && $0.placeholderString == "Search files" } ?? false
        }
        guard let control else { return nil }
        let rect = control.convert(control.bounds, to: host)
        return host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
    }
    guard await waitFor(label, timeout: 10, every: 20, { ready() && measure() != nil }) else { return nil }
    for _ in 0..<10 { await Task.yield(); host.layoutSubtreeIfNeeded() }
    return measure()
}

@MainActor
private func pelCheck(_ name: String, empty: CGFloat?, filled: CGFloat?) {
    guard let empty, let filled else {
        check(false, "\(name): the panel header was found (empty \(String(describing: empty)), filled \(String(describing: filled)))")
        return
    }
    check(empty < pelPinnedTop && abs(empty - filled) <= 1,
          "\(name): the header stays pinned at the top (\(empty)pt; \(filled)pt with rows)")
}

@MainActor
private func pelFilesModel(_ key: String, files: Bool = false, fails: Bool = false) -> SessionFilesModel {
    SessionFilesModel(sessionKey: key, request: { method, _ in
        if fails { throw PELFailure() }
        guard files, method == SessionFilesModel.listMethod else { return .object([:]) }
        return .object(["files": .array([.object(["path": "notes.md", "kind": "modified", "size": 12])])])
    })
}

/// Files tab and Runs: offline, scripted models.
@MainActor
func runPanelEmptyStateLayoutChecks() async {
    _ = NSApplication.shared
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil

    func files(_ model: SessionFilesModel) -> some View {
        FilesPanelView(model: model, state: FilesSession()).environment(gateway).defaultAppStorage(defaults)
    }
    let withFiles = pelFilesModel("files", files: true)
    let filled = await pelHeaderTop(files(withFiles), label: "files with rows") { withFiles.loaded && !withFiles.snapshot.isEmpty }
    let empty = pelFilesModel("empty")
    pelCheck("Files, No files yet", empty: await pelHeaderTop(files(empty), label: "files empty") {
        empty.loaded && empty.snapshot.isEmpty
    }, filled: filled)
    let noMatch = pelFilesModel("nomatch")
    noMatch.setSearch("zzz-no-such-file")
    pelCheck("Files, No matching files", empty: await pelHeaderTop(files(noMatch), label: "files no match") {
        noMatch.loaded && noMatch.snapshot.isEmpty
    }, filled: filled)
    let failed = pelFilesModel("failed", fails: true)
    pelCheck("Files, Can't show files", empty: await pelHeaderTop(files(failed), label: "files error") {
        !failed.loaded && failed.error != nil
    }, filled: filled)

    func runs(_ key: String?) -> some View {
        RunsPanel().environment(gateway).environment(\.chatWindowKey, key).defaultAppStorage(defaults)
    }
    let selected = await pelHeaderTop(runs("agent:main:main"), segmented: true, label: "runs with chat") { true }
    pelCheck("Runs, No chat selected", empty: await pelHeaderTop(runs(nil), segmented: true, label: "runs no chat") {
        gateway.focusedKey == nil
    }, filled: selected)
}

/// Generated Files against the built-in demo: a chat with files, a search with no match, and a chat with none.
@MainActor
func runDemoPanelEmptyStateLayoutChecks() async {
    _ = NSApplication.shared
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    GatewayProfileStore.save([.demo()], to: defaults)
    let app = AppModel(defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    guard let gateway = app.gateways.first else {
        check(false, "panel layout demo: the demo Gateway is configured")
        return
    }
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded()
    defer { gateway.stop() }
    guard await waitFor("panel layout demo", timeout: 25, { gateway.state.isConnected && gateway.bootstrapped }) else {
        check(false, "panel layout demo connects")
        return
    }

    let filesKey = "agent:main:main"
    let withFiles = gateway.assetsModel(for: filesKey)
    await withFiles.refresh()
    var emptyKey: String?
    let candidates = gateway.sessions.values.filter { !$0.isSubagent && !$0.isPlaceholder && !$0.isArchived }.map(\.key).sorted()
    for key in candidates where key != filesKey {
        let model = gateway.assetsModel(for: key)
        await model.refresh()
        if model.loaded, model.assets.isEmpty { emptyKey = key; break }
    }
    guard !withFiles.assets.isEmpty, let emptyKey else {
        check(false, "panel layout demo: a chat with generated files and one without (\(withFiles.assets.count), \(String(describing: emptyKey)))")
        return
    }

    func assets(_ key: String) -> some View {
        AssetsPanel().environment(app).environment(gateway).environment(\.chatWindowKey, key).defaultAppStorage(gateway.defaults)
    }
    let filled = await pelHeaderTop(assets(filesKey), label: "assets with rows") { withFiles.loaded && !withFiles.shown.isEmpty }
    check(filled.map { $0 < pelPinnedTop } == true, "Generated Files: with files the search field is at the top (\(filled.map { "\($0)pt" } ?? "not found"))")
    pelCheck("Generated Files, No matching files", empty: await pelHeaderTop(assets(filesKey), label: "assets no match",
                                                                              prepare: { withFiles.search = "zzz-no-such-file" }) {
        withFiles.loaded && withFiles.shown.isEmpty
    }, filled: filled)
    withFiles.search = ""
    let empty = gateway.assetsModel(for: emptyKey)
    pelCheck("Generated Files, No files yet", empty: await pelHeaderTop(assets(emptyKey), label: "assets empty") {
        empty.loaded && empty.assets.isEmpty
    }, filled: filled)
}
#endif
