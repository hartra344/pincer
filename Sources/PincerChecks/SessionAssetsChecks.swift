import Foundation
@testable import PincerKit

@MainActor
func runSessionAssetsOfflineChecks() async {
    func reply(_ id: String, _ seconds: TimeInterval, _ blocks: [ContentBlock], role: ChatRole = .assistant) -> ChatItem {
        var item = ChatItem(id: id, role: role, blocks: blocks)
        item.transcriptId = id
        item.timestamp = Date(timeIntervalSince1970: seconds)
        return item
    }
    let items = [
        reply("u", 1, [.file(FileRef(name: "hosts.csv", artifactId: "up"))], role: .user),
        reply("a1", 2, [.text("Done\nMEDIA:/tmp/report.pdf")]),
        reply("a2", 3, [.file(FileRef(name: "data.csv", artifactId: "csv"))]),
        reply("a3", 4, [.text("Updated\nMEDIA:/tmp/report.pdf")]),
    ]
    let scanned = SessionAssetScanner.scan(items)
    check(scanned.map(\.name) == ["report.pdf", "data.csv"], "assets: assistant files only, newest first (\(scanned.map(\.name)))")
    check(scanned.first?.messageId == "a3", "assets: a resent file points at its latest message")
    let merged = SessionAssetScanner.merge(scanned, server: [
        SessionArtifactItem(id: "artifact_1", type: "file", title: "report.pdf", mimeType: "application/pdf", sizeBytes: 2048),
        SessionArtifactItem(id: "artifact_2", type: "file", title: "archive.zip", mimeType: nil, sizeBytes: 9),
    ])
    check(merged.count == 3 && merged[0].sizeBytes == 2048 && merged[2].name == "archive.zip" && merged[2].messageId == nil,
          "assets: Gateway artifacts fill sizes and add older files (\(merged.map(\.name)))")
    check(SessionAssetScanner.filter(merged, filter: .files, search: "zip").map(\.name) == ["archive.zip"],
          "assets: filter and search narrow the list")
}

@MainActor
func runDemoSessionAssetsChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let (gateway, up) = await startStore(.demo(), waiting: "assets Demo connection", timeout: 25, reconnect: true,
                                         defaults: defaults,
                                         prepare: { $0.cacheRoot = nil; $0.outboxRoot = nil; $0.notifier = nil },
                                         until: { $0.state.isConnected && $0.bootstrapped })
    defer { gateway.stop() }
    guard up else {
        check(false, "assets demo connects")
        return
    }

    let main = gateway.assetsModel(for: "agent:main:main")
    main.setVisible(true, viewer: "check")
    let mainLoaded = await waitFor("demo assets", timeout: 10) { main.loaded }
    check(mainLoaded && Set(main.assets.map(\.name)).isSuperset(of: ["Disk usage chart", "disk-report.sh"]),
          "demo assets: the main chat lists its chart and script (\(main.assets.map(\.name)))")
    main.setVisible(false, viewer: "check")

    let key = "agent:main:dashboard:rate-limiter"
    let chat = gateway.chat(for: key)
    await chat.load()
    _ = await waitFor("rate-limiter history", timeout: 10) { chat.hasLoaded && !chat.items.isEmpty }
    let model = gateway.assetsModel(for: key)
    await model.refresh()
    let pdf = model.assets.first { $0.name == "rate-limiter-design.pdf" }
    check(pdf != nil && pdf?.messageId != nil, "demo assets: the generated PDF is listed with its message (\(model.assets.map(\.name)))")
    check(model.assets.filter { $0.name == "rate-limiter-design.pdf" }.count == 1, "demo assets: transcript and Gateway entries merge")
    if let pdf {
        let data = await gateway.files.data(for: pdf.fileRef, sessionKey: key)
        check(data.map { $0.starts(with: Data("%PDF".utf8)) } == true, "demo assets: the PDF downloads again")
        model.filter = .images
        check(!model.shown.contains(pdf), "demo assets: the Images filter hides the PDF")
        model.filter = .all
    }
}

@MainActor
func runLiveSessionAssetsChecks(url: String, token: String) async {
    let profile = GatewayProfile(name: "Mock assets", url: url, authMode: .token, access: .admin)
    profile.secret = token
    let (gateway, up) = await startStore(profile, waiting: "mock for assets", timeout: 25, reconnect: true,
                                         until: { $0.state.isConnected && $0.bootstrapped })
    guard up else {
        check(false, "live assets: mock connected")
        return
    }
    defer { gateway.stop() }
    let model = gateway.assetsModel(for: "agent:main:main")
    await model.refresh()
    let names = Set(model.assets.map(\.name))
    check(names.contains("release-notes.md") && !names.contains("hosts.csv"),
          "live assets: assistant artifacts arrive, uploads don't (\(names.sorted()))")
    check(model.assets.contains { $0.isImage }, "live assets: generated images are listed")
    if let notes = model.assets.first(where: { $0.name == "release-notes.md" }) {
        let data = await gateway.files.data(for: notes.fileRef, sessionKey: "agent:main:main")
        check(data.map { String(decoding: $0, as: UTF8.self).hasPrefix("# Release notes") } == true,
              "live assets: a listed file downloads with artifacts.download")
    }
}
