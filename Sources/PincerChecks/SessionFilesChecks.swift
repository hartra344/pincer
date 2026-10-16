import CoreGraphics
import Foundation
import ImageIO
import PincerKit
import Synchronization
import UniformTypeIdentifiers
@testable import PincerKit

// #974: the Files tab (sessions.files.list/get/set, artifacts.list) and the #1012 card thumbnails.

private func sfJSON(_ text: String) -> JSONValue {
    (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null
}

private func sfEscaped(_ text: String) -> String {
    String(data: (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
}

private func sfRPC(_ type: String, _ extra: [String: JSONValue] = [:]) -> GatewayError {
    var details: [String: JSONValue] = ["type": .string(type)]
    for (key, value) in extra { details[key] = value }
    return .rpc(code: "INVALID_REQUEST", message: "m", details: .object(details))
}

private let sfRetained = Mutex<[SessionFilesModel]>([])

/// A scripted Gateway for the offline checks.
private final class SFScript: Sendable {
    let reply = Mutex<JSONValue>(.null)
    let failure = Mutex<Error?>(nil)
    let sets = Mutex<[JSONValue]>([])
    let gets = Mutex<Int>(0)

    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        if method == SessionFilesModel.setMethod { sets.withLock { $0.append(params) } }
        if method == SessionFilesModel.getMethod { gets.withLock { $0 += 1 } }
        if method != SessionFilesModel.listMethod, let error = failure.withLock({ $0 }) { throw error }
        return reply.withLock { $0 }
    }

    func text(_ content: String, hash: String? = "h1") {
        let hashPart = hash.map { ",\"hash\":\"\($0)\"" } ?? ""
        reply.withLock {
            $0 = sfJSON("{\"file\":{\"path\":\"a.md\",\"kind\":\"modified\",\"previewKind\":\"text\",\"contentEncoding\":\"utf8\",\"content\":\(sfEscaped(content))\(hashPart)}}")
        }
    }

    @MainActor func model(admin: Bool = true, advertised: Set<String>? = nil) -> SessionFilesModel {
        SessionFilesModel(sessionKey: "agent:main:main", request: { [self] m, p in try await self.request(m, p) },
                          hasAdmin: { admin }, advertises: { advertised?.contains($0) ?? true }, debounce: .milliseconds(20))
    }

    @MainActor func document(admin: Bool = true, advertised: Set<String>? = nil) async -> (SessionFilesModel, SessionFileDocument) {
        let model = model(admin: admin, advertised: advertised)
        sfRetained.withLock { $0.append(model) }
        let document = model.open(path: "a.md")
        _ = await waitFor("script document", timeout: 5) { document.phase != .loading }
        return (model, document)
    }
}

private func sfSolidFrame(width: Int, height: Int) -> BrowserFrame? {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let _ = Optional(context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))),
          let _ = Optional(context.fill(CGRect(x: 0, y: 0, width: width, height: height))),
          let image = context.makeImage() else { return nil }
    return BrowserFrame(image: image, pageURL: nil, cssSize: CGSize(width: width, height: height), sequence: 1)
}

@MainActor
func runSessionFilesOfflineChecks() async {
    // Parsing
    let list = SessionFilesParser.list(sfJSON("""
    {"root":"/ws","gitCheckout":true,"files":[
      {"path":"a.md","name":"a.md","kind":"modified","missing":false,"size":10},
      {"path":"c.txt","kind":"read","missing":true},{"path":"","kind":"read"},{"path":"x","kind":"bogus"}],
     "browser":{"path":"","truncated":true,"entries":[
      {"path":"docs","name":"docs","kind":"directory","sessionKind":"mixed"},
      {"path":"a.md","name":"a.md","kind":"file","sessionKind":"modified","size":10},
      {"path":"z","name":"","kind":"file"},{"path":"q","name":"q","kind":"socket"}]}}
    """))
    check(list.root == "/ws" && list.gitCheckout == true, "files parse: root and git checkout")
    check(list.files.map(\.path) == ["a.md", "c.txt"], "files parse: junk and kindless rows are dropped")
    check(list.files[1].missing && list.files[1].name == "c.txt", "files parse: a missing row is Deleted and takes its name from the path")
    check(list.entries.map(\.path) == ["docs", "a.md"] && list.entries[0].isDirectory && list.entries[0].relevance == .mixed,
          "files parse: tree entries need a name and a file/directory kind")
    check(list.truncated, "files parse: truncated browser listing is flagged")
    let many = (0..<(SessionFilesParser.maxFiles + 5)).map { "{\"path\":\"f\($0)\",\"kind\":\"read\"}" }.joined(separator: ",")
    check(SessionFilesParser.list(sfJSON("{\"files\":[\(many)]}")).files.count == SessionFilesParser.maxFiles, "files parse: the row count is capped")
    let artifacts = SessionFilesParser.artifacts(sfJSON("""
    {"omittedOversized":true,"artifacts":[{"id":"a1","type":"image","title":"Map","sizeBytes":68},{"id":"","type":"file","title":"x"},{"id":"a2","type":"file"}]}
    """))
    check(artifacts.items.map(\.id) == ["a1"] && artifacts.omittedOversized, "files parse: artifacts need id, type and title; oversize flag kept")

    // Errors
    check(SessionFilesError.map(sfRPC("session_file_conflict", ["currentHash": "abc"])) == .conflict(currentHash: "abc"), "files errors: conflict carries the current hash")
    check(SessionFilesError.map(sfRPC("session_file_too_large", ["size": 300_000])) == .tooLarge(size: 300_000), "files errors: too large carries the size")
    check(SessionFilesError.map(sfRPC("session_file_not_found")) == .notFound, "files errors: not found")
    check(SessionFilesError.map(sfRPC("session_file_unsafe")) == .unsafe, "files errors: unsafe")
    check(SessionFilesError.map(sfRPC("device_folder_files_unavailable")) == .deviceFolder, "files errors: device folder")
    check(SessionFilesError.map(GatewayError.notConnected) == .notConnected, "files errors: not connected")
    let scope = GatewayError.rpc(code: "FORBIDDEN", message: "missing scope", details: ["code": "MISSING_SCOPE"])
    check(SessionFilesError.map(scope) == .missingScope, "files errors: missing scope")

    // Tree flattening
    typealias Entry = SessionFileTreeEntry
    let root = [Entry(path: "docs", name: "docs", isDirectory: true), Entry(path: "a.md", name: "a.md", isDirectory: false)]
    let kids = ["docs": [Entry(path: "docs/b.md", name: "b.md", isDirectory: false)]]
    let open = SessionFilesParser.flatten(root: root, children: kids, expanded: ["docs"], loading: [], search: "")
    check(open.map(\.entry.path) == ["docs", "docs/b.md", "a.md"] && open.map(\.depth) == [0, 1, 0], "files tree: an open folder nests its children")
    let searching = SessionFilesParser.flatten(root: root, children: kids, expanded: ["docs"], loading: [], search: "md")
    check(searching.map(\.entry.path) == ["docs", "a.md"], "files tree: a search shows the flat result without opening folders")
    let loop = SessionFilesParser.flatten(root: root, children: ["docs": [Entry(path: "docs", name: "docs", isDirectory: true)]],
                                          expanded: ["docs"], loading: [], search: "")
    check(loop.count < 10, "files tree: a cyclic listing terminates")

    // Models, chips and editing rules
    let script = SFScript()
    script.reply.withLock { $0 = sfJSON("{\"files\":[{\"path\":\"a\",\"kind\":\"modified\"},{\"path\":\"b\",\"kind\":\"read\"},{\"path\":\"c\",\"kind\":\"read\"}]}") }
    let model = script.model()
    await model.refresh()
    let sfOK1 = await waitFor("files chips", timeout: 5, { model.snapshot.counts.changed == 1 && model.snapshot.counts.read == 2 })
    check(sfOK1, "files chips: counts per group")
    model.filter = .read
    let sfOK2 = await waitFor("files read chip", timeout: 5, { model.snapshot.changed.isEmpty && model.snapshot.read.count == 2 })
    check(sfOK2, "files chips: Read shows only read files")
    check(model.snapshot.counts.changed == 1, "files chips: counts stay while another chip is selected")
    model.reset()
    check(!model.loaded && model.snapshot.isEmpty, "files model: reset forgets the listing")
    check(!script.model(advertised: []).isAvailable, "files model: hidden when the gateway doesn't advertise it")
    check(script.model().canEdit && !script.model(admin: false).canEdit && !script.model(advertised: ["sessions.files.list"]).canEdit,
          "files model: editing needs admin and sessions.files.set")

    script.text("hello\nworld\n")
    let (_, editable) = await script.document()
    check(editable.phase == .text && editable.isEditable, "files edit: text with a hash, uniform endings and admin is editable")
    script.text("x", hash: nil)
    let (_, noHash) = await script.document()
    check(!noHash.isEditable, "files edit: no hash, no editing")
    script.text("x")
    let (_, noAdmin) = await script.document(admin: false)
    check(noAdmin.phase == .text && !noAdmin.isEditable, "files edit: no admin, no editing")
    script.text("a\nb\r\n")
    let (_, mixed) = await script.document()
    check(mixed.hasMixedLineEndings && !mixed.isEditable, "files edit: mixed line endings are shown, never editable")

    script.text("old")
    let (_, doc) = await script.document()
    script.text("new", hash: "h2")
    let saved = await doc.save("new")
    check(saved == .saved && doc.hash == "h2" && script.sets.withLock { $0.last?["expectedHash"]?.string } == "h1",
          "files edit: save sends the hash it was read with and adopts the new one")
    let huge = await doc.save(String(repeating: "a", count: SessionFilesModel.maxPreviewBytes + 1))
    check(huge == .tooLarge, "files edit: over 256 KiB is refused before the request")
    script.failure.withLock { $0 = sfRPC("session_file_conflict", ["currentHash": "h9"]) }
    let conflicted = await doc.save("mine")
    check(conflicted == .conflict(currentHash: "h9"), "files edit: a changed file reports a conflict")
    script.failure.withLock { $0 = nil }
    script.text("theirs", hash: "h9")
    let getsBefore = script.gets.withLock { $0 }
    let overwritten = await doc.overwrite("mine")
    check(overwritten == .saved && script.gets.withLock { $0 } == getsBefore + 1 && script.sets.withLock { $0.last?["expectedHash"]?.string } == "h9",
          "files edit: Overwrite re-reads for the current hash, then saves")

    // Setting default and LRU
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    check((defaults.object(forKey: SessionFilesModel.showInPanelKey) as? Bool ?? true) == true, "files setting: defaults to ON")
    let gateway = GatewayStore(profile: GatewayProfile(name: "Files", url: "ws://127.0.0.1:1", authMode: .none), defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    let first = gateway.filesModel(for: "s0")
    check(gateway.filesModel(for: "s0") === first, "files cache: one model per session")
    for index in 1...(GatewayStore.filesModelLimit + 3) { _ = gateway.filesModel(for: "s\(index)") }
    check(gateway.filesModelCache.count == GatewayStore.filesModelLimit && gateway.filesModelCache["s0"] == nil, "files cache: bounded LRU drops the oldest model")

    // Thumbnails
    check(BrowserPanelModel.thumbnailKey(for: BrowserPageTab(targetId: "T1", route: BrowserRoute(profile: "p", target: "host"))) == "host|p|T1", "thumbnail key: host form")
    check(BrowserPanelModel.thumbnailKey(for: BrowserPageTab(targetId: "T1", route: BrowserRoute(profile: "p", target: "node", node: "n"))) == "node|n|p|T1", "thumbnail key: node form")
    check(BrowserPanelModel.thumbnailKey(for: BrowserPageTab(targetId: "T1")) == nil, "thumbnail key: tabs that didn't come from a card get none")
    if let frame = sfSolidFrame(width: 1280, height: 800), let thumb = BrowserPanelModel.makeThumbnail(frame.image) {
        check(thumb.width == 480 && thumb.mimeType == "image/jpeg" && (thumb.base64?.count ?? 0) > 0, "thumbnail: downscaled to 480 px wide JPEG")
        let sink = Mutex<[(Bool, String)]>([])
        let panel = BrowserPanelModel(request: { _, _ in .null }, hasAdmin: { true }, makeSource: { _ in nil })
        panel.thumbnailSink = { ref, key in sink.withLock { $0.append((ref != nil, key)) } }
        let tab = BrowserPageTab(targetId: "T1", route: BrowserRoute(profile: "p", target: "host"))
        let start = Date()
        panel.captureThumbnail(frame, tab: tab, now: start)
        let sfOK3 = await waitFor("thumbnail captured", timeout: 5, { sink.withLock { $0.count } == 1 })
        check(sfOK3, "thumbnail: the first frame is captured")
        panel.captureThumbnail(frame, tab: tab, now: start.addingTimeInterval(9.9))
        try? await Task.sleep(for: .milliseconds(150))
        check(sink.withLock { $0.count } == 1, "thumbnail: at most one per 10 s per tab")
        panel.captureThumbnail(frame, tab: tab, now: start.addingTimeInterval(10.0))
        try? await Task.sleep(for: .milliseconds(300))
        check(sink.withLock { $0.count } == 1, "thumbnail: an unchanged page isn't re-published")
        if let changed = sfSolidFrame(width: 1000, height: 700) {
            panel.captureThumbnail(changed, tab: tab, now: start.addingTimeInterval(20.0))
            let sfOK4 = await waitFor("thumbnail after change", timeout: 5, { sink.withLock { $0.count } == 2 })
            check(sfOK4, "thumbnail: a changed page is captured after 10 s")
        }
        panel.clearThumbnail(for: tab)
        check(sink.withLock { $0.last?.0 } == false && panel.thumbnailLast.isEmpty, "thumbnail: closing a tab clears its thumbnail and throttle")
    } else {
        check(false, "thumbnail: could not build a test frame")
    }

    let previews = BrowserPagePreviews()
    let ref = ImageRef(artifactId: nil, base64: "x", url: nil, mimeType: "image/jpeg", alt: nil, width: 1, height: 1)
    for index in 0..<(BrowserPagePreviews.maxScreenshots + 8) { previews.setScreenshot(ref, forTab: "k\(index)") }
    check(previews.screenshot(forTab: "k0") == nil && previews.screenshot(forTab: "k8") != nil && BrowserPagePreviews.maxScreenshots == 32,
          "thumbnail cap: 32 tabs, the oldest is dropped")
    previews.setScreenshot(nil, forTab: "k8")
    check(previews.screenshot(forTab: "k8") == nil, "thumbnail cap: nil removes a tab's screenshot")
    previews.reset()
    check(previews.screenshot(forTab: "k20") == nil, "thumbnail cap: reset clears every screenshot")
}

@MainActor
func runDemoSessionFilesChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    guard await waitFor("files Demo connection", timeout: 25, { gateway.state.isConnected && gateway.bootstrapped }) else {
        check(false, "files demo connects")
        return
    }
    let key = gateway.sessions.keys.sorted().first ?? "agent:main:main"
    let files = gateway.filesModel(for: key)
    check(files.isAvailable && files.hasAdmin && files.canEdit, "demo files: the tab is available and editable in the demo")
    await files.refresh()
    let sfOK5 = await waitFor("demo files listing", timeout: 10, { files.snapshot.counts.changed >= 3 && files.snapshot.counts.artifacts == 2 })
    check(sfOK5,
          "demo files: changed, read and artifact groups arrive (\(files.snapshot.counts))")
    check(files.snapshot.changed.contains { $0.path == "itinerary.md" } && files.snapshot.changed.contains { $0.missing },
          "demo files: changed files lead and a deleted file shows (\(files.snapshot.changed.map(\.path)))")
    check(files.snapshot.tree.contains { $0.entry.isDirectory && $0.entry.path == "docs" }, "demo files: the project tree has folders")
    files.toggleFolder("docs")
    let sfOK6 = await waitFor("demo folder expand", timeout: 10, { files.snapshot.tree.contains { $0.entry.path == "docs/packing.md" } })
    check(sfOK6, "demo files: a folder expands lazily")
    files.setSearch("budget")
    let sfOK7 = await waitFor("demo search", timeout: 10, { files.snapshot.counts.changed == 1 })
    check(sfOK7, "demo files: search narrows the groups")
    files.setSearch("")

    // Open text, edit, save
    let text = files.open(path: "itinerary.md")
    let sfOK8 = await waitFor("demo text", timeout: 10, { text.phase == .text })
    check(sfOK8 && text.content.contains("Japan trip") && text.isEditable, "demo files: a text file opens editable")
    let saved = await text.save(text.content + "- Day 4: Osaka\n")
    check(saved == .saved && text.content.contains("Osaka"), "demo files: edit and save succeeds")
    let again = files.open(path: "itinerary.md")
    _ = await waitFor("demo reopen", timeout: 10) { again.phase == .text }
    check(again.content.contains("Osaka"), "demo files: the saved text reads back")

    // Image, binary, too large, missing
    let image = files.open(path: "data/map.png")
    let sfOK9 = await waitFor("demo image", timeout: 10, { image.phase == .image })
    check(sfOK9 && !image.isEditable, "demo files: an image opens read-only")
    let binary = files.open(path: "data/archive.zip")
    let sfOK10 = await waitFor("demo binary", timeout: 10, { binary.phase == .unsupported })
    check(sfOK10, "demo files: a binary file has no preview")
    let big = files.open(path: DemoGateway.demoOversizedPath)
    let sfOK11 = await waitFor("demo too large", timeout: 10, { big.phase != .loading })
    check(sfOK11 && big.phase == .tooLarge(size: 3 * 1024 * 1024), "demo files: a file over 256 KiB is too large")
    let gone = files.open(path: "docs/old-plan.md")
    let sfOK12 = await waitFor("demo missing", timeout: 10, { gone.phase == .missing })
    check(sfOK12, "demo files: a deleted file is missing")

    // Conflict → Overwrite
    let conflict = files.open(path: DemoGateway.demoConflictPath)
    _ = await waitFor("demo conflict doc", timeout: 10) { conflict.phase == .text }
    let first = await conflict.save("# Notes\n\nMy version.\n")
    var currentHash: String?
    if case let .conflict(hash) = first { currentHash = hash }
    check(currentHash != nil && conflict.content.contains("Edit this"), "demo files: the first save of conflict-demo.md conflicts and keeps the draft's base")
    let overwritten = await conflict.overwrite("# Notes\n\nMy version.\n")
    check(overwritten == .saved && conflict.content == "# Notes\n\nMy version.\n", "demo files: Overwrite succeeds after a conflict")

    // External edit → conflict → Reload
    let standalone = DemoGateway()
    let externalModel = SessionFilesModel(sessionKey: key, request: { try await standalone.handle($0, $1) }, hasAdmin: { true })
    let external = externalModel.open(path: "docs/packing.md")
    _ = await waitFor("demo external doc", timeout: 10) { external.phase == .text }
    let original = external.content
    await standalone.simulateExternalFileEdit(path: "docs/packing.md")
    let stale = await external.save(original + "- [ ] Umbrella\n")
    check({ if case .conflict = stale { return true } else { return false } }(), "demo files: an external edit makes the next save conflict")
    await external.reload()
    check(external.content.contains("(Edited elsewhere.)"), "demo files: Reload shows the externally edited text")

    // A connection without admin can't edit
    let readOnly = SessionFilesModel(sessionKey: key, request: { try await gateway.connection.request($0, $1) }, hasAdmin: { false })
    let ro = readOnly.open(path: "README.md")
    let sfOK13 = await waitFor("demo read-only", timeout: 10, { ro.phase == .text })
    check(sfOK13 && !ro.isEditable, "demo files: without admin a text file is not editable")

    // The setting hides the tab; the model stays available
    defaults.set(false, forKey: SessionFilesModel.showInPanelKey)
    let shown = (defaults.object(forKey: SessionFilesModel.showInPanelKey) as? Bool ?? true) && files.isAvailable
    check(!shown && files.isAvailable, "demo files: turning the setting off hides the tab")
    defaults.removeObject(forKey: SessionFilesModel.showInPanelKey)
    check((defaults.object(forKey: SessionFilesModel.showInPanelKey) as? Bool ?? true) && files.isAvailable, "demo files: the tab is back with the default ON")

    // #1012: a thumbnail arrives for a card-routed tab
    let panel = gateway.browserPanel
    await panel.refreshTabs()
    let target = BrowserDemoPages.docs.targetId
    let tabKey = "host|openclaw|\(target)"
    panel.select(BrowserTabRef(targetId: target, profile: "openclaw", target: "host", url: URL(string: "https://docs.openclaw.ai/"), title: "Docs"))
    panel.setVisible(true, pixelSize: CGSize(width: 800, height: 600))
    let thumb = await waitFor("demo card thumbnail", timeout: 20) { gateway.pagePreviews.screenshot(forTab: tabKey) != nil }
    check(thumb, "demo files: a card-routed tab feeds its thumbnail (\(tabKey))")
    check((gateway.pagePreviews.screenshot(forTab: tabKey)?.width ?? .max) <= 480, "demo files: the thumbnail is at most 480 px wide")
    panel.stop()
}

@MainActor
func runLiveSessionFilesChecks(url: String, token: String) async {
    let admin = GatewayProfile(name: "Mock files", url: url, authMode: .token, access: .admin)
    admin.secret = token
    let gateway = GatewayStore(profile: admin)
    gateway.start()
    gateway.reconnectIfNeeded()
    guard await waitFor("mock for files", timeout: 25, { gateway.state.isConnected && gateway.bootstrapped }) else {
        check(false, "live files: mock connected")
        return
    }
    defer { gateway.stop() }
    let session = "agent:main:main"
    let model = gateway.filesModel(for: session)
    if !model.isAvailable {
        // MOCK_NO_SESSION_FILES=1: no methods in hello-ok and UNKNOWN_METHOD on call.
        check(!model.isAvailable, "live files: the tab is hidden when the gateway lacks the methods")
        let unsupported: SessionFilesError? = await {
            do { _ = try await gateway.connection.request(SessionFilesModel.listMethod, ["sessionKey": .string(session)]) } catch { return SessionFilesError.map(error) }
            return nil
        }()
        check(unsupported == .unsupported, "live files: calling a missing method maps to unsupported (\(String(describing: unsupported)))")
        return
    }

    await model.refresh()
    let sfOK14 = await waitFor("live files listing", timeout: 15, { model.snapshot.counts.changed >= 4 })
    check(sfOK14, "live files: changed, read and artifact groups arrive (\(model.snapshot.counts))")
    check(model.snapshot.counts.artifacts == 5 && model.snapshot.gitCheckout == true, "live files: the seeded artifacts and git state arrive")
    check(model.snapshot.changed.contains { $0.path == "src/index.ts" } && model.snapshot.read.contains { $0.path == "src/lib/legacy.ts" && $0.missing },
          "live files: changed files and a deleted read file")
    check(model.snapshot.tree.contains { $0.entry.path == "src" && $0.entry.isDirectory }, "live files: the project tree lists folders")
    model.toggleFolder("src")
    let sfOK15 = await waitFor("live folder", timeout: 10, { model.snapshot.tree.contains { $0.entry.path == "src/index.ts" } })
    check(sfOK15, "live files: a folder expands")
    model.setSearch("format")
    let sfOK16 = await waitFor("live search", timeout: 10, { model.snapshot.tree.contains { $0.entry.path == "src/lib/format.ts" } && model.snapshot.tree.allSatisfy { !$0.isExpanded } })
    check(sfOK16,
          "live files: a gateway search returns matching paths")
    model.setSearch("")

    // Unknown session → empty list; get → not found
    let unknown = try? await gateway.connection.request(SessionFilesModel.listMethod, ["sessionKey": "agent:nobody:none", "path": ""])
    check(unknown != nil && (unknown?["files"]?.array?.isEmpty ?? false), "live files: an unknown session lists nothing")
    let missing: SessionFilesError? = await {
        do { _ = try await gateway.connection.request(SessionFilesModel.getMethod, ["sessionKey": "agent:nobody:none", "path": "x.md"]) } catch { return SessionFilesError.map(error) }
        return nil
    }()
    check(missing == .notFound, "live files: get on an unknown session is session_file_not_found (\(String(describing: missing)))")
    let absent = model.open(path: "no/such/file.md")
    let sfOK17 = await waitFor("live absent file", timeout: 10, { absent.phase == .missing })
    check(sfOK17, "live files: a file that isn't there shows as missing")

    // Too large, unsafe, image, binary
    let build = model.open(path: "logs/build.log")
    let sfOK18 = await waitFor("live build.log", timeout: 10, { build.phase != .loading })
    check(sfOK18 && { if case .tooLarge = build.phase { return true } else { return false } }(),
          "live files: logs/build.log is over 256 KiB (\(build.phase))")
    let logo = model.open(path: "assets/logo.png")
    let sfOK19 = await waitFor("live image", timeout: 10, { logo.phase == .image })
    check(sfOK19, "live files: a PNG previews")
    let bin = model.open(path: "assets/hosts.bin")
    let sfOK20 = await waitFor("live binary", timeout: 10, { bin.phase == .unsupported })
    check(sfOK20, "live files: a binary file has no preview")
    let license = model.open(path: "LICENSE")
    _ = await waitFor("live LICENSE", timeout: 10) { license.phase != .loading }
    check(license.phase == .text && !license.isEditable, "live files: a read-only file has no hash and isn't editable")
    let forced = try? await gateway.connection.request(SessionFilesModel.setMethod, [
        "sessionKey": .string(session), "path": "LICENSE", "content": "x", "expectedHash": .string(String(repeating: "a", count: 64)),
    ])
    check(forced == nil, "live files: writing a read-only file is refused")
    let unsafe: SessionFilesError? = await {
        do {
            _ = try await gateway.connection.request(SessionFilesModel.setMethod, [
                "sessionKey": .string(session), "path": "LICENSE", "content": "x", "expectedHash": .string(String(repeating: "a", count: 64)),
            ])
        } catch { return SessionFilesError.map(error) }
        return nil
    }()
    check(unsafe == .unsafe, "live files: LICENSE maps to unsafe (\(String(describing: unsafe)))")

    // Conflict hooks and a plain save
    let volatile = model.open(path: "notes/volatile.md")
    _ = await waitFor("live volatile", timeout: 10) { volatile.phase == .text }
    let stale = await volatile.save("# Volatile\n\nMine.\n")
    check({ if case .conflict = stale { return true } else { return false } }(), "live files: notes/volatile.md changes after every read, so a save conflicts")
    let forceOverwrite = await volatile.overwrite("# Volatile\n\nMine.\n")
    check(forceOverwrite == .saved || { if case .conflict = forceOverwrite { return true } else { return false } }(),
          "live files: Overwrite re-reads for the hash (it may conflict again on a volatile file)")

    let probeA = model.open(path: "README.md")
    _ = await waitFor("live drift probe", timeout: 10) { probeA.phase == .text }
    let hashA = probeA.hash
    await probeA.reload()
    let drift = probeA.hash != hashA
    let notes = model.open(path: "NOTES.md")
    _ = await waitFor("live NOTES", timeout: 10) { notes.phase == .text }
    let stamp = "# Notes\n\nSaved by Pincer at \(Int(Date().timeIntervalSince1970)).\n"
    let outcome = await notes.save(stamp)
    if drift {
        check({ if case .conflict = outcome { return true } else { return false } }(), "live files: with MOCK_FILES_DRIFT=1 the first save conflicts")
        let over = await notes.overwrite(stamp)
        check(over == .saved && notes.content == stamp, "live files: Overwrite after drift saves")
    } else {
        check(outcome == .saved && notes.content == stamp, "live files: edit and save succeeds")
        let reread = model.open(path: "NOTES.md")
        _ = await waitFor("live NOTES reread", timeout: 10) { reread.phase == .text }
        check(reread.content == stamp, "live files: the saved text reads back")
        let second = await notes.save(stamp + "More.\n")
        check(second == .saved, "live files: a second save uses the new hash")
    }

    // Without admin: read works, set is refused, nothing is editable
    let reader = GatewayProfile(name: "Mock files (read)", url: url, authMode: .token)
    reader.secret = token
    let readGateway = GatewayStore(profile: reader)
    readGateway.start()
    readGateway.reconnectIfNeeded()
    defer { readGateway.stop() }
    guard await waitFor("mock read-only for files", timeout: 25, { readGateway.state.isConnected && readGateway.bootstrapped }) else {
        check(false, "live files: read-only connection")
        return
    }
    let readModel = readGateway.filesModel(for: session)
    check(readModel.isAvailable && !readModel.hasAdmin && !readModel.canEdit, "live files: without admin the tab shows but can't edit")
    let readDoc = readModel.open(path: "NOTES.md")
    _ = await waitFor("live read-only doc", timeout: 10) { readDoc.phase == .text }
    check(readDoc.phase == .text && !readDoc.isEditable, "live files: a read-only connection reads a file but can't edit it")
    let denied: SessionFilesError? = await {
        do {
            _ = try await readGateway.connection.request(SessionFilesModel.setMethod, [
                "sessionKey": .string(session), "path": "NOTES.md", "content": "x", "expectedHash": .string(String(repeating: "a", count: 64)),
            ])
        } catch { return SessionFilesError.map(error) }
        return nil
    }()
    check(denied == .missingScope, "live files: sessions.files.set without admin is rejected (\(String(describing: denied)))")
}

/// Filters and flattens a 5,000-entry listing off-main; the main actor only applies the result.
@MainActor
func checkSessionFilesPerfSmoke() async {
    let files = (0..<5_000).map { "{\"path\":\"dir\($0 % 50)/file\($0).swift\",\"kind\":\"\($0 % 4 == 0 ? "modified" : "read")\",\"size\":\($0)}" }
    let entries = (0..<1_000).map { "{\"path\":\"e\($0)\",\"name\":\"e\($0)\",\"kind\":\"\($0 % 5 == 0 ? "directory" : "file")\"}" }
    let listing = sfJSON("{\"root\":\"/ws\",\"files\":[\(files.joined(separator: ","))],\"browser\":{\"path\":\"\",\"entries\":[\(entries.joined(separator: ","))]}}")
    let clock = ContinuousClock()

    let parsed = await Task.detached { () -> (Duration, Int) in
        let start = ContinuousClock.now
        let list = SessionFilesParser.list(listing)
        let kids = Dictionary(uniqueKeysWithValues: list.entries.filter(\.isDirectory).map {
            ($0.path, (0..<20).map { SessionFileTreeEntry(path: "\($0)/\($0)", name: "c\($0)", isDirectory: false) })
        })
        let expanded = Set(kids.keys)
        var rows = 0
        for query in ["", "file4", "dir7/", "nomatch"] {
            let matching = list.files.filter { SessionFilesParser.matches($0.path, query) }
            rows += SessionFilesParser.flatten(root: list.entries, children: kids, expanded: expanded, loading: [], search: query).count + matching.count
        }
        return (ContinuousClock.now - start, rows)
    }.value
    let ms = { (d: Duration) in d.formatted(.units(allowed: [.milliseconds])) }
    print("  · perf smoke: parse + 4 filters/flattens of 5,000 files and 1,000 entries off-main in \(ms(parsed.0))")
    check(parsed.1 > 0 && parsed.0 < .seconds(2), "files perf: parse, filter and flatten a 5,000-entry listing off-main under 2 s")

    // End to end through the model: the main actor only pays for setSearch's input copy and the apply.
    let script = SFScript()
    script.reply.withLock { $0 = listing }
    let model = script.model()
    var worstGap = Duration.zero
    var last = clock.now
    let heartbeat = Task { @MainActor in
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
            let now = clock.now
            worstGap = max(worstGap, now - last)
            last = now
        }
    }
    last = clock.now
    await model.refresh()
    var searchCost = Duration.zero
    for query in ["file1", "file12", "dir3", ""] {
        searchCost += clock.measure { model.setSearch(query) }
        try? await Task.sleep(for: .milliseconds(30))
    }
    let applied = await waitFor("files perf snapshot", timeout: 15) { model.snapshot.counts.changed == 1_250 }
    heartbeat.cancel()
    var applyCost = Duration.zero
    applyCost = clock.measure {
        var snapshot = model.snapshot
        snapshot.tree = snapshot.tree.reversed()
        _ = snapshot.isEmpty
    }
    print("  · perf smoke: setSearch main-thread cost \(ms(searchCost)); worst main-actor stall \(ms(worstGap)); apply \(ms(applyCost))")
    check(applied, "files perf: the full listing's chips are counted (\(model.snapshot.counts))")
    check(searchCost < .milliseconds(100), "files perf: four searches cost the main thread under 100 ms in total")
    check(worstGap < .milliseconds(500), "files perf: the main actor never stalls 500 ms while a 5,000-entry listing builds")
    check(applyCost < .milliseconds(50), "files perf: applying a finished snapshot costs the main thread under 50 ms")
}
