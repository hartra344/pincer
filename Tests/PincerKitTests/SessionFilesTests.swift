import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import PincerKit

/// A scripted `sessions.files.*` / `artifacts.list` gateway.
final class FilesGateway: Sendable {
    struct Call: Sendable { let method: String; let params: JSONValue }
    let calls = Mutex<[Call]>([])
    let listReply = Mutex<JSONValue>(Fixtures.json(#"{"files":[]}"#))
    let artifactsReply = Mutex<JSONValue?>(nil)
    let getReplies = Mutex<[JSONValue]>([])
    let failure = Mutex<[String: Error]>([:])
    let folders = Mutex<[String: JSONValue]>([:])

    func count(_ method: String) -> Int { calls.withLock { $0.filter { $0.method == method }.count } }
    func last(_ method: String) -> JSONValue? { calls.withLock { $0.last { $0.method == method }?.params } }

    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        calls.withLock { $0.append(Call(method: method, params: params)) }
        if let error = failure.withLock({ $0[method] }) { throw error }
        switch method {
        case "sessions.files.list":
            if let path = params["path"]?.string, !path.isEmpty, let folder = folders.withLock({ $0[path] }) { return folder }
            return listReply.withLock { $0 }
        case "artifacts.list":
            if let reply = artifactsReply.withLock({ $0 }) { return reply }
            throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method", details: nil)
        case "sessions.files.get":
            return getReplies.withLock { $0.count > 1 ? $0.removeFirst() : ($0.first ?? .null) }
        default:
            return getReplies.withLock { $0.first ?? .null }
        }
    }

    @MainActor func model(admin: Bool = true, advertised: Set<String>? = nil, agentId: String? = nil) -> SessionFilesModel {
        SessionFilesModel(
            sessionKey: "agent:main:main", agentId: agentId,
            request: { [self] m, p in try await self.request(m, p) },
            hasAdmin: { admin }, advertises: { advertised?.contains($0) ?? true }, debounce: .milliseconds(20))
    }
}

enum FilesFixtures {
    nonisolated(unsafe) static let retained = Mutex<[AnyObject]>([])
    static let listJSON = #"""
    {"root":"/ws","gitCheckout":true,
     "files":[
       {"path":"a.md","name":"a.md","kind":"modified","missing":false,"size":10,"updatedAtMs":5},
       {"path":"b.md","name":"b.md","kind":"modified","missing":false},
       {"path":"c.txt","name":"c.txt","kind":"read","missing":false},
       {"path":"gone.txt","kind":"read","missing":true},
       {"path":"","kind":"read"},
       {"path":"x.txt","kind":"bogus"}],
     "browser":{"path":"","entries":[
       {"path":"docs","name":"docs","kind":"directory","sessionKind":"mixed"},
       {"path":"a.md","name":"a.md","kind":"file","sessionKind":"modified","size":10},
       {"path":"z","name":"","kind":"file"},
       {"path":"q","name":"q","kind":"socket"}],"truncated":true}}
    """#

    static func get(_ extra: String) -> JSONValue {
        Fixtures.json(#"{"sessionKey":"s","file":{"path":"a.md","name":"a.md","kind":"modified",\#(extra)}}"#)
    }

    static func text(_ content: String, hash: String? = "h1") -> JSONValue {
        let escaped = String(data: try! JSONEncoder().encode(content), encoding: .utf8)!
        let hashPart = hash.map { #","hash":"\#($0)""# } ?? ""
        return get(#""previewKind":"text","contentEncoding":"utf8","content":\#(escaped)\#(hashPart)"#)
    }

    static func rpc(_ type: String, _ extra: [String: JSONValue] = [:]) -> GatewayError {
        var details: [String: JSONValue] = ["type": .string(type)]
        for (k, v) in extra { details[k] = v }
        return .rpc(code: "INVALID_REQUEST", message: "m", details: .object(details))
    }
}

@Suite("Session files parsing")
struct SessionFilesParserTests {
    @Test func listKeepsValidRowsAndDropsJunk() {
        let list = SessionFilesParser.list(Fixtures.json(FilesFixtures.listJSON))
        #expect(list.root == "/ws")
        #expect(list.gitCheckout == true)
        #expect(list.files.map(\.path) == ["a.md", "b.md", "c.txt", "gone.txt"])
        #expect(list.files[0].size == 10)
        #expect(list.files[0].updatedAtMs == 5)
        #expect(list.files[2].kind == .read)
        #expect(list.files[3].missing)
        #expect(list.files[3].name == "gone.txt")
        #expect(list.entries.map(\.path) == ["docs", "a.md"])
        #expect(list.entries[0].isDirectory)
        #expect(list.entries[0].relevance == .mixed)
        #expect(list.entries[1].relevance == .modified)
        #expect(list.truncated)
    }

    @Test func listWithoutBrowserAndEmptyRoot() {
        let list = SessionFilesParser.list(Fixtures.json(#"{"root":"","files":[]}"#))
        #expect(list.root == nil)
        #expect(list.entries.isEmpty)
        #expect(list.browserPath == nil)
        #expect(!list.truncated)
        #expect(SessionFilesParser.list(.null).files.isEmpty)
    }

    @Test func listCapsRows() {
        let files = (0..<(SessionFilesParser.maxFiles + 10)).map { #"{"path":"f\#($0)","kind":"read"}"# }.joined(separator: ",")
        let entries = (0..<(SessionFilesParser.maxEntries + 10)).map { #"{"path":"e\#($0)","name":"e","kind":"file"}"# }.joined(separator: ",")
        let list = SessionFilesParser.list(Fixtures.json(#"{"files":[\#(files)],"browser":{"entries":[\#(entries)]}}"#))
        #expect(list.files.count == SessionFilesParser.maxFiles)
        #expect(list.entries.count == SessionFilesParser.maxEntries)
    }

    @Test func artifactsParse() {
        let value = Fixtures.json(#"""
        {"omittedOversized":true,"artifacts":[
          {"id":"a1","type":"image","title":"Map","mimeType":"image/png","sizeBytes":68},
          {"id":"","type":"file","title":"no id"},
          {"id":"a2","type":"file"},
          {"id":"a3","type":"file","title":"notes.md"}]}
        """#)
        let result = SessionFilesParser.artifacts(value)
        #expect(result.items.map(\.id) == ["a1", "a3"])
        #expect(result.items[0].sizeBytes == 68)
        #expect(result.omittedOversized)
        #expect(SessionFilesParser.artifacts(.null).items.isEmpty)
        let many = (0..<(SessionFilesParser.maxArtifacts + 5)).map { #"{"id":"i\#($0)","type":"file","title":"t"}"# }.joined(separator: ",")
        #expect(SessionFilesParser.artifacts(Fixtures.json(#"{"artifacts":[\#(many)]}"#)).items.count == SessionFilesParser.maxArtifacts)
    }

    @Test func getAndSetShapes() {
        let text = SessionFileDocument.Loaded(FilesFixtures.text("hi\n", hash: "abc"))
        #expect(text.hash == "abc")
        guard case .text = text.kind else { Issue.record("not text"); return }
        #expect(text.text == "hi\n")
        let b64 = SessionFileDocument.Loaded(FilesFixtures.get(#""previewKind":"text","contentEncoding":"base64","content":"aGk=","hash":"h""#))
        #expect(b64.text == "hi")
        let image = SessionFileDocument.Loaded(FilesFixtures.get(#""previewKind":"image","contentEncoding":"base64","content":"AAAA","mimeType":"image/png""#))
        guard case .image = image.kind else { Issue.record("not image"); return }
        #expect(image.image?.mimeType == "image/png")
        let noContent = SessionFileDocument.Loaded(FilesFixtures.get(#""previewKind":"image""#))
        guard case .unsupported = noContent.kind else { Issue.record("not unsupported"); return }
        let binary = SessionFileDocument.Loaded(FilesFixtures.get(#""previewKind":"unsupported""#))
        guard case .unsupported = binary.kind else { Issue.record("not unsupported"); return }
        let big = SessionFileDocument.Loaded(FilesFixtures.get(#""size":300000"#))
        guard case .tooLarge(300_000) = big.kind else { Issue.record("not tooLarge"); return }
        let missing = SessionFileDocument.Loaded(FilesFixtures.get(#""missing":true"#))
        guard case .missing = missing.kind else { Issue.record("not missing"); return }
        // `set` replies carry the same `{file}` shape; a bare file works too.
        #expect(SessionFileDocument.Loaded(Fixtures.json(#"{"previewKind":"text","content":"x","hash":"z"}"#)).hash == "z")
    }

    @Test func lineEndingDetection() {
        let check = SessionFileDocument.Loaded.hasMixedLineEndings
        #expect(!check("a\nb\n"))
        #expect(!check("a\r\nb\r\n"))
        #expect(!check("a\rb\r"))
        #expect(!check("no newline"))
        #expect(check("a\nb\r\n"))
        #expect(check("a\rb\n"))
        #expect(check("a\r\nb\rc"))
    }
}

@Suite("Session files tree")
struct SessionFilesTreeTests {
    typealias Entry = SessionFileTreeEntry
    let root = [Entry(path: "docs", name: "docs", isDirectory: true), Entry(path: "a.md", name: "a.md", isDirectory: false)]
    let kids = ["docs": [Entry(path: "docs/b.md", name: "b.md", isDirectory: false),
                         Entry(path: "docs/sub", name: "sub", isDirectory: true)],
                "docs/sub": [Entry(path: "docs/sub/c.md", name: "c.md", isDirectory: false)]]

    @Test func collapsedShowsRootOnly() {
        let rows = SessionFilesParser.flatten(root: root, children: kids, expanded: [], loading: [], search: "")
        #expect(rows.map(\.entry.path) == ["docs", "a.md"])
        #expect(rows.allSatisfy { $0.depth == 0 && !$0.isExpanded })
    }

    @Test func expandedNestsDepthFirst() {
        let rows = SessionFilesParser.flatten(root: root, children: kids, expanded: ["docs", "docs/sub"], loading: [], search: "")
        #expect(rows.map(\.entry.path) == ["docs", "docs/b.md", "docs/sub", "docs/sub/c.md", "a.md"])
        #expect(rows.map(\.depth) == [0, 1, 1, 2, 0])
        #expect(rows[0].isExpanded)
    }

    @Test func loadingFolderAndMissingChildren() {
        let rows = SessionFilesParser.flatten(root: root, children: [:], expanded: ["docs"], loading: ["docs"], search: "")
        #expect(rows.map(\.entry.path) == ["docs", "a.md"])
        #expect(rows[0].isLoading)
        #expect(rows[0].isExpanded)
    }

    @Test func searchFlattensWithoutOpeningFolders() {
        let rows = SessionFilesParser.flatten(root: root, children: kids, expanded: ["docs"], loading: [], search: "md")
        #expect(rows.map(\.entry.path) == ["docs", "a.md"])
        #expect(!rows[0].isExpanded)
    }

    @Test func cycleTerminates() {
        let loop = ["docs": [Entry(path: "docs", name: "docs", isDirectory: true)]]
        let rows = SessionFilesParser.flatten(root: root, children: loop, expanded: ["docs"], loading: [], search: "")
        #expect(rows.count <= 4)
    }

    @Test func matchesIsCaseInsensitive() {
        #expect(SessionFilesParser.matches("Docs/ReadMe.md", "readme"))
        #expect(SessionFilesParser.matches("anything", ""))
        #expect(!SessionFilesParser.matches("a.md", "zzz"))
    }
}

@Suite("Session files errors")
struct SessionFilesErrorTests {
    @Test func mapsUpstreamTypes() {
        #expect(SessionFilesError.map(FilesFixtures.rpc("session_file_conflict", ["currentHash": "abc"])) == .conflict(currentHash: "abc"))
        #expect(SessionFilesError.map(FilesFixtures.rpc("session_file_conflict")) == .conflict(currentHash: nil))
        #expect(SessionFilesError.map(FilesFixtures.rpc("session_file_too_large", ["size": 300_000])) == .tooLarge(size: 300_000))
        #expect(SessionFilesError.map(FilesFixtures.rpc("session_file_not_found")) == .notFound)
        #expect(SessionFilesError.map(FilesFixtures.rpc("session_file_unsafe")) == .unsafe)
        #expect(SessionFilesError.map(FilesFixtures.rpc("device_folder_files_unavailable")) == .deviceFolder)
    }

    @Test func fallsBackToClassification() {
        #expect(SessionFilesError.map(GatewayError.notConnected) == .notConnected)
        let scope = GatewayError.rpc(code: "FORBIDDEN", message: "missing scope: operator.admin",
                                     details: ["code": "MISSING_SCOPE", "scope": "operator.admin"])
        #expect(SessionFilesError.map(scope) == .missingScope)
        let unknown = GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method", details: nil)
        #expect(SessionFilesError.map(unknown) == .unsupported)
        guard case .failed = SessionFilesError.map(FilesFixtures.rpc("something_else")) else {
            Issue.record("expected failed")
            return
        }
    }

    @Test func failedMessagesAreSanitizedAndEveryErrorHasAMessage() {
        let err = SessionFilesError.map(GatewayError.rpc(code: "UNAVAILABLE", message: "boom at https://secret.example/x?token=abc", details: nil))
        guard case let .failed(text) = err else { Issue.record("expected failed"); return }
        #expect(!text.contains("secret.example"))
        #expect(!text.contains("token=abc"))
        let all: [SessionFilesError] = [.conflict(currentHash: nil), .tooLarge(size: nil), .notFound, .unsafe, .deviceFolder,
                                        .missingScope, .unsupported, .notConnected, .failed("x")]
        #expect(all.allSatisfy { !$0.message.isEmpty })
    }
}

@MainActor
@Suite("Session files model")
struct SessionFilesModelTests {
    func loaded(_ gateway: FilesGateway, admin: Bool = true, advertised: Set<String>? = nil) async -> SessionFilesModel {
        gateway.artifactsReply.withLock {
            $0 = Fixtures.json(#"{"artifacts":[{"id":"a1","type":"image","title":"Map.png"},{"id":"a2","type":"file","title":"notes.md"}]}"#)
        }
        gateway.listReply.withLock { $0 = Fixtures.json(FilesFixtures.listJSON) }
        let model = gateway.model(admin: admin, advertised: advertised)
        await model.refresh()
        _ = await eventually { model.snapshot.counts.changed > 0 }
        return model
    }

    @Test func settingDefaultsOn() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        #expect(SessionFilesModel.showInPanelKey == "pincer.showFilesInWorkspacePanel")
        #expect(scratch.defaults.object(forKey: SessionFilesModel.showInPanelKey) == nil)
        // `@AppStorage(…) = true` is what the UI reads: unset means ON.
        let value = scratch.defaults.object(forKey: SessionFilesModel.showInPanelKey) as? Bool ?? true
        #expect(value)
        scratch.defaults.set(false, forKey: SessionFilesModel.showInPanelKey)
        #expect(scratch.defaults.bool(forKey: SessionFilesModel.showInPanelKey) == false)
    }

    @Test func capIsUpstreams256KiB() {
        #expect(SessionFilesModel.maxPreviewBytes == 256 * 1024)
    }

    @Test func chipCountsAndFiltering() async {
        let gateway = FilesGateway()
        let model = await loaded(gateway)
        #expect(model.loaded)
        #expect(model.snapshot.counts == .init(changed: 2, read: 2, artifacts: 2))
        #expect(model.snapshot.changed.map(\.path) == ["a.md", "b.md"])
        #expect(model.snapshot.read.map(\.path) == ["c.txt", "gone.txt"])
        #expect(!model.snapshot.tree.isEmpty)
        #expect(model.snapshot.treeTruncated)

        model.filter = .changed
        #expect(await eventually { model.snapshot.read.isEmpty && model.snapshot.tree.isEmpty })
        #expect(model.snapshot.changed.count == 2)
        #expect(model.snapshot.counts.read == 2)

        model.filter = .artifacts
        #expect(await eventually { model.snapshot.changed.isEmpty && model.snapshot.artifacts.count == 2 })

        model.filter = .read
        #expect(await eventually { model.snapshot.artifacts.isEmpty && model.snapshot.read.count == 2 })
    }

    @Test func localSearchFiltersGroupsAndCounts() async {
        let gateway = FilesGateway()
        let model = await loaded(gateway)
        model.setSearch("  map ")
        #expect(model.search == "map")
        #expect(await eventually { model.snapshot.counts == .init(changed: 0, read: 0, artifacts: 1) })
        model.setSearch("")
        #expect(await eventually { model.snapshot.counts.changed == 2 })
    }

    @Test func searchAsksTheGatewayAfterTheDebounce() async {
        let gateway = FilesGateway()
        let model = await loaded(gateway)
        let before = gateway.count("sessions.files.list")
        model.setSearch("md")
        #expect(await eventually { gateway.count("sessions.files.list") > before })
        #expect(gateway.last("sessions.files.list")?["search"]?.string == "md")
    }

    @Test func requestParamsCarrySessionAndAgent() async {
        let gateway = FilesGateway()
        let model = gateway.model(agentId: "main")
        await model.refresh()
        let list = gateway.last("sessions.files.list")
        #expect(list?["sessionKey"]?.string == "agent:main:main")
        #expect(list?["agentId"]?.string == "main")
        #expect(list?["path"]?.string == "")
        #expect(gateway.last("artifacts.list")?["agentId"]?.string == "main")
    }

    @Test func failingArtifactsOnlyHidesThatGroup() async {
        let gateway = FilesGateway()
        gateway.listReply.withLock { $0 = Fixtures.json(FilesFixtures.listJSON) }
        let model = gateway.model()
        await model.refresh()
        #expect(await eventually { model.snapshot.counts.changed == 2 })
        #expect(model.error == nil)
        #expect(model.snapshot.counts.artifacts == 0)
    }

    @Test func listFailureKeepsCachedRowsAndSetsError() async {
        let gateway = FilesGateway()
        let model = await loaded(gateway)
        gateway.failure.withLock { $0["sessions.files.list"] = GatewayError.notConnected }
        await model.refresh()
        #expect(model.error == .notConnected)
        #expect(model.snapshot.counts.changed == 2)
    }

    @Test func unavailableWithoutTheMethod() async {
        let gateway = FilesGateway()
        let model = gateway.model(advertised: [])
        #expect(!model.isAvailable)
        await model.refresh()
        #expect(model.error == .unsupported)
        #expect(gateway.count("sessions.files.list") == 0)
    }

    @Test func canEditNeedsAdminAndTheSetMethod() {
        let gateway = FilesGateway()
        #expect(gateway.model().canEdit)
        #expect(!gateway.model(admin: false).canEdit)
        #expect(!gateway.model(advertised: ["sessions.files.list", "sessions.files.get"]).canEdit)
        #expect(gateway.model(admin: false).isAvailable)
    }

    @Test func toggleFolderFetchesOnceThenReuses() async {
        let gateway = FilesGateway()
        gateway.listReply.withLock { $0 = Fixtures.json(FilesFixtures.listJSON) }
        gateway.folders.withLock {
            $0["docs"] = Fixtures.json(#"{"browser":{"path":"docs","entries":[{"path":"docs/b.md","name":"b.md","kind":"file"}]}}"#)
        }
        let model = gateway.model()
        await model.refresh()
        #expect(await eventually { !model.snapshot.tree.isEmpty })
        model.toggleFolder("docs")
        #expect(await eventually { model.snapshot.tree.map(\.entry.path) == ["docs", "docs/b.md", "a.md"] })
        let fetched = gateway.count("sessions.files.list")
        model.toggleFolder("docs")
        #expect(await eventually { model.snapshot.tree.map(\.entry.path) == ["docs", "a.md"] })
        model.toggleFolder("docs")
        #expect(await eventually { model.snapshot.tree.count == 3 })
        #expect(gateway.count("sessions.files.list") == fetched)
    }

    @Test func runEndedRefreshesOnlyWhenVisible() async {
        let gateway = FilesGateway()
        let model = gateway.model()
        model.runEnded()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(gateway.count("sessions.files.list") == 0)
        model.setVisible(true, viewer: "w1")
        #expect(await eventually { gateway.count("sessions.files.list") == 1 })
        model.runEnded()
        #expect(await eventually { gateway.count("sessions.files.list") == 2 })
        model.setVisible(false, viewer: "w1")
        model.runEnded()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(gateway.count("sessions.files.list") == 2)
    }

    @Test func resetForgetsEverything() async {
        let gateway = FilesGateway()
        let model = await loaded(gateway)
        model.reset()
        #expect(!model.loaded)
        #expect(model.snapshot.isEmpty)
        #expect(model.snapshot.counts == .init())
        #expect(model.error == nil)
    }
}

@MainActor
@Suite("Session file documents")
struct SessionFileDocumentTests {
    func open(_ gateway: FilesGateway, admin: Bool = true, advertised: Set<String>? = nil, path: String = "a.md") async -> SessionFileDocument {
        let model = gateway.model(admin: admin, advertised: advertised)
        // The document holds its model weakly; keep it alive for the test.
        FilesFixtures.retained.withLock { $0.append(model) }
        let document = model.open(path: path)
        _ = await eventually { document.phase != .loading }
        return document
    }

    @Test func textIsEditableWithHashAdminAndUniformEndings() async {
        let gateway = FilesGateway()
        gateway.getReplies.withLock { $0 = [FilesFixtures.text("hello\nworld\n")] }
        let document = await open(gateway)
        #expect(document.phase == .text)
        #expect(document.content == "hello\nworld\n")
        #expect(document.hash == "h1")
        #expect(document.isEditable)
        #expect(gateway.last("sessions.files.get")?["path"]?.string == "a.md")
    }

    @Test func notEditableWithoutAHash() async {
        let gateway = FilesGateway()
        gateway.getReplies.withLock { $0 = [FilesFixtures.text("read only", hash: nil)] }
        let document = await open(gateway)
        #expect(document.phase == .text)
        #expect(!document.isEditable)
    }

    @Test func notEditableWithoutAdmin() async {
        let gateway = FilesGateway()
        gateway.getReplies.withLock { $0 = [FilesFixtures.text("x")] }
        let document = await open(gateway, admin: false)
        #expect(document.phase == .text)
        #expect(!document.isEditable)
    }

    @Test func notEditableWithoutTheSetMethod() async {
        let gateway = FilesGateway()
        gateway.getReplies.withLock { $0 = [FilesFixtures.text("x")] }
        let document = await open(gateway, advertised: ["sessions.files.list", "sessions.files.get"])
        #expect(!document.isEditable)
    }

    @Test func notEditableWithMixedLineEndings() async {
        let gateway = FilesGateway()
        gateway.getReplies.withLock { $0 = [FilesFixtures.text("a\nb\r\n")] }
        let document = await open(gateway)
        #expect(document.hasMixedLineEndings)
        #expect(!document.isEditable)
    }

    @Test func imagesAndBinaryAreNeverEditable() async {
        let gateway = FilesGateway()
        gateway.getReplies.withLock { $0 = [FilesFixtures.get(#""previewKind":"image","contentEncoding":"base64","content":"AAAA","mimeType":"image/png","hash":"h""#)] }
        let image = await open(gateway)
        #expect(image.phase == .image)
        #expect(!image.isEditable)
        gateway.getReplies.withLock { $0 = [FilesFixtures.get(#""previewKind":"unsupported""#)] }
        #expect(await open(gateway).phase == .unsupported)
    }

    @Test func tooLargeAndMissingAndErrors() async {
        let gateway = FilesGateway()
        gateway.getReplies.withLock { $0 = [FilesFixtures.get(#""size":400000"#)] }
        #expect(await open(gateway).phase == .tooLarge(size: 400_000))
        gateway.getReplies.withLock { $0 = [FilesFixtures.get(#""missing":true"#)] }
        #expect(await open(gateway).phase == .missing)
        gateway.failure.withLock { $0["sessions.files.get"] = FilesFixtures.rpc("session_file_too_large", ["size": 999_999]) }
        #expect(await open(gateway).phase == .tooLarge(size: 999_999))
        gateway.failure.withLock { $0["sessions.files.get"] = FilesFixtures.rpc("session_file_not_found") }
        #expect(await open(gateway).phase == .missing)
        gateway.failure.withLock { $0["sessions.files.get"] = FilesFixtures.rpc("session_file_unsafe") }
        guard case .failed = await open(gateway).phase else { Issue.record("expected failed"); return }
    }

    @Test func saveSendsTheHashItWasReadWith() async {
        let gateway = FilesGateway()
        gateway.getReplies.withLock { $0 = [FilesFixtures.text("old")] }
        let document = await open(gateway)
        gateway.getReplies.withLock { $0 = [FilesFixtures.text("new", hash: "h2")] }
        let r1 = await document.save("new")
        #expect(r1 == .saved)
        let set = gateway.last("sessions.files.set")
        #expect(set?["expectedHash"]?.string == "h1")
        #expect(set?["content"]?.string == "new")
        #expect(set?["sessionKey"]?.string == "agent:main:main")
        #expect(document.hash == "h2")
        #expect(document.content == "new")
    }

    @Test func conflictLeavesTheDocumentAndOverwriteRereadsFirst() async {
        let gateway = FilesGateway()
        gateway.getReplies.withLock { $0 = [FilesFixtures.text("old")] }
        let document = await open(gateway)
        gateway.failure.withLock { $0["sessions.files.set"] = FilesFixtures.rpc("session_file_conflict", ["currentHash": "h9"]) }
        let r2 = await document.save("mine")
        #expect(r2 == .conflict(currentHash: "h9"))
        #expect(document.hash == "h1")
        #expect(document.content == "old")

        gateway.failure.withLock { $0["sessions.files.set"] = nil }
        gateway.getReplies.withLock { $0 = [FilesFixtures.text("theirs", hash: "h9")] }
        let gets = gateway.count("sessions.files.get")
        let r3 = await document.overwrite("mine")
        #expect(r3 == .saved)
        #expect(gateway.count("sessions.files.get") == gets + 1)
        #expect(gateway.last("sessions.files.set")?["expectedHash"]?.string == "h9")
    }

    @Test func overwriteFailsWhenTheFileIsGoneOrHasNoHash() async {
        let gateway = FilesGateway()
        gateway.getReplies.withLock { $0 = [FilesFixtures.text("old")] }
        let document = await open(gateway)
        gateway.failure.withLock { $0["sessions.files.get"] = FilesFixtures.rpc("session_file_not_found") }
        let r4 = await document.overwrite("x")
        #expect(r4 == .missing)
        gateway.failure.withLock { $0["sessions.files.get"] = nil }
        gateway.getReplies.withLock { $0 = [FilesFixtures.text("ro", hash: nil)] }
        guard case .failed = await document.overwrite("x") else { Issue.record("expected failed"); return }
    }

    @Test func overTheCapIsRefusedLocally() async {
        let gateway = FilesGateway()
        gateway.getReplies.withLock { $0 = [FilesFixtures.text("old")] }
        let document = await open(gateway)
        let sets = gateway.count("sessions.files.set")
        let huge = String(repeating: "a", count: SessionFilesModel.maxPreviewBytes + 1)
        let r5 = await document.save(huge)
        #expect(r5 == .tooLarge)
        #expect(gateway.count("sessions.files.set") == sets)
        // Exactly the cap is allowed.
        let exact = String(repeating: "a", count: SessionFilesModel.maxPreviewBytes)
        let r6 = await document.save(exact)
        #expect(r6 == .saved)
    }

    @Test func serverErrorsMapToResults() async {
        let gateway = FilesGateway()
        gateway.getReplies.withLock { $0 = [FilesFixtures.text("old")] }
        let document = await open(gateway)
        gateway.failure.withLock { $0["sessions.files.set"] = FilesFixtures.rpc("session_file_not_found") }
        let r7 = await document.save("x")
        #expect(r7 == .missing)
        gateway.failure.withLock { $0["sessions.files.set"] = FilesFixtures.rpc("session_file_too_large", ["size": 1]) }
        let r8 = await document.save("x")
        #expect(r8 == .tooLarge)
        gateway.failure.withLock { $0["sessions.files.set"] = FilesFixtures.rpc("session_file_unsafe") }
        guard case .failed = await document.save("x") else { Issue.record("expected failed"); return }
    }

    @Test func savingWithoutAHashIsRefused() async {
        let gateway = FilesGateway()
        gateway.getReplies.withLock { $0 = [FilesFixtures.text("ro", hash: nil)] }
        let document = await open(gateway)
        guard case .failed = await document.save("x") else { Issue.record("expected failed"); return }
        #expect(gateway.count("sessions.files.set") == 0)
    }

    @Test func reloadReplacesTheContent() async {
        let gateway = FilesGateway()
        gateway.getReplies.withLock { $0 = [FilesFixtures.text("one")] }
        let document = await open(gateway)
        gateway.getReplies.withLock { $0 = [FilesFixtures.text("two", hash: "h5")] }
        await document.reload()
        #expect(document.content == "two")
        #expect(document.hash == "h5")
    }
}

@MainActor
@Suite("Session files store cache")
struct SessionFilesStoreTests {
    let scratch = ScratchDefaults()

    func store() -> GatewayStore {
        GatewayStore(profile: GatewayProfile(name: "Files", url: "ws://127.0.0.1:1", authMode: .none),
                     defaults: scratch.defaults, identity: Fixtures.identity())
    }

    @Test func modelsAreCachedPerSessionAndBounded() {
        defer { scratch.remove() }
        let store = store()
        let first = store.filesModel(for: "s0")
        #expect(store.filesModel(for: "s0") === first)
        for i in 1...GatewayStore.filesModelLimit + 4 { _ = store.filesModel(for: "s\(i)") }
        #expect(store.filesModelCache.count == GatewayStore.filesModelLimit)
        #expect(store.filesModelOrder.count == GatewayStore.filesModelLimit)
        #expect(store.filesModelCache["s0"] == nil)
        #expect(store.filesModel(for: "s0") !== first)
    }

    @Test func touchingAModelKeepsItAlive() {
        defer { scratch.remove() }
        let store = store()
        let kept = store.filesModel(for: "keep")
        for i in 1..<GatewayStore.filesModelLimit {
            _ = store.filesModel(for: "s\(i)")
            _ = store.filesModel(for: "keep")
        }
        for i in 100..<105 {
            _ = store.filesModel(for: "n\(i)")
            _ = store.filesModel(for: "keep")
        }
        #expect(store.filesModel(for: "keep") === kept)
        #expect(store.filesModelCache.count <= GatewayStore.filesModelLimit)
    }

    @Test func evictionResetsTheModelAndResetClearsAll() async {
        defer { scratch.remove() }
        let store = store()
        let model = store.filesModel(for: "victim")
        #expect(!model.loaded)
        for i in 0..<GatewayStore.filesModelLimit { _ = store.filesModel(for: "o\(i)") }
        #expect(store.filesModelCache["victim"] == nil)
        store.resetFilesModels()
        #expect(store.filesModelCache.values.allSatisfy { !$0.loaded && $0.snapshot.isEmpty })
    }

    @Test func notAvailableOnAnUnconnectedStore() {
        defer { scratch.remove() }
        #expect(!store().filesModel(for: "s").isAvailable)
        #expect(!store().filesModel(for: "s").hasAdmin)
    }
}

@MainActor
@Suite("Browser card thumbnails")
struct BrowserThumbnailTests {
    static let cardTab = BrowserPageTab(targetId: "T1", route: BrowserRoute(profile: "openclaw", target: "host"))

    final class Sink: @unchecked Sendable {
        var calls: [(ImageRef?, String)] = []
    }

    func model(_ sink: Sink?) -> BrowserPanelModel {
        let model = BrowserPanelModel(request: { _, _ in .null }, hasAdmin: { true },
                                      makeSource: { FakeBrowserSource(ticket: $0) }, debounce: .milliseconds(5), retryDelay: .milliseconds(50))
        if let sink { model.thumbnailSink = { ref, key in sink.calls.append((ref, key)) } }
        return model
    }

    func bigFrame(width: Int = 1280, height: Int = 800) -> BrowserFrame {
        let cg = BrowserFrameDecoder.decode(BrowserFixtures.jpeg(width: width, height: height), maxPixelSize: 4096)!
        return BrowserFrame(image: cg, pageURL: nil, cssSize: CGSize(width: width, height: height), sequence: 1)
    }

    @Test func keysMatchThePreviewKeyForms() {
        #expect(BrowserPanelModel.thumbnailKey(for: Self.cardTab) == "host|openclaw|T1")
        let node = BrowserPageTab(targetId: "T2", route: BrowserRoute(profile: "p", target: "node", node: "n1"))
        #expect(BrowserPanelModel.thumbnailKey(for: node) == "node|n1|p|T2")
        #expect(BrowserPanelModel.thumbnailKey(for: BrowserPageTab(targetId: "T3")) == nil)
        #expect(BrowserPanelModel.thumbnailKey(for: BrowserPageTab(targetId: "T3", route: BrowserRoute(profile: ""))) == nil)
        #expect(BrowserPanelModel.thumbnailKey(for: BrowserPageTab(targetId: "T3", route: BrowserRoute(profile: "p", target: "node"))) == nil)
    }

    @Test func downscalesToAtMost480WideJPEG() throws {
        let ref = try #require(BrowserPanelModel.makeThumbnail(bigFrame().image))
        #expect(ref.mimeType == "image/jpeg")
        #expect(ref.width == 480)
        #expect(ref.height == 300)
        let encoded = try #require(ref.base64)
        let data = try #require(Data(base64Encoded: encoded))
        #expect(data.starts(with: [0xFF, 0xD8, 0xFF]))
        let small = try #require(BrowserPanelModel.makeThumbnail(bigFrame(width: 200, height: 100).image))
        #expect(small.width == 200)
    }

    @Test func throttlesToOncePerTenSecondsAndOnlyWhenTheFrameChanged() async {
        let sink = Sink()
        let model = model(sink)
        let frame = bigFrame(width: 100, height: 60)
        let start = Date(timeIntervalSince1970: 1_000_000)
        model.captureThumbnail(frame, tab: Self.cardTab, now: start)
        #expect(await eventually { sink.calls.count == 1 })
        #expect(sink.calls[0].1 == "host|openclaw|T1")
        #expect(sink.calls[0].0 != nil)
        model.captureThumbnail(frame, tab: Self.cardTab, now: start.addingTimeInterval(9.9))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sink.calls.count == 1)
        // Due, but the page is unchanged: nothing is delivered.
        model.captureThumbnail(frame, tab: Self.cardTab, now: start.addingTimeInterval(10))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(sink.calls.count == 1)
        model.captureThumbnail(bigFrame(width: 160, height: 90), tab: Self.cardTab, now: start.addingTimeInterval(20))
        #expect(await eventually { sink.calls.count == 2 })
    }

    @Test func throttleIsPerTab() async {
        let sink = Sink()
        let model = model(sink)
        let frame = bigFrame(width: 100, height: 60)
        let other = BrowserPageTab(targetId: "T9", route: BrowserRoute(profile: "openclaw", target: "host"))
        let now = Date()
        model.captureThumbnail(frame, tab: Self.cardTab, now: now)
        model.captureThumbnail(frame, tab: other, now: now)
        #expect(await eventually { sink.calls.count == 2 })
        #expect(Set(sink.calls.map(\.1)) == ["host|openclaw|T1", "host|openclaw|T9"])
    }

    @Test func tabsWithoutAProfileAndModelsWithoutASinkCaptureNothing() async {
        let sink = Sink()
        let model = model(sink)
        model.captureThumbnail(bigFrame(width: 50, height: 50), tab: BrowserPageTab(targetId: "X"), now: Date())
        let noSink = self.model(nil)
        noSink.captureThumbnail(bigFrame(width: 50, height: 50), tab: Self.cardTab, now: Date())
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sink.calls.isEmpty)
        #expect(noSink.thumbnailLast.isEmpty)
    }

    @Test func clearThumbnailDropsTheEntryAndTheThrottle() async {
        let sink = Sink()
        let model = model(sink)
        let now = Date()
        model.captureThumbnail(bigFrame(width: 100, height: 60), tab: Self.cardTab, now: now)
        #expect(await eventually { sink.calls.count == 1 })
        model.clearThumbnail(for: Self.cardTab)
        #expect(sink.calls.count == 2)
        #expect(sink.calls[1].0 == nil)
        #expect(model.thumbnailLast.isEmpty)
        // The throttle is gone: the next frame captures at once.
        model.captureThumbnail(bigFrame(width: 100, height: 60), tab: Self.cardTab, now: now.addingTimeInterval(0.1))
        #expect(await eventually { sink.calls.count == 3 })
    }

    @Test func closedTabIsNotResurrectedByAnInFlightCapture() async {
        let sink = Sink()
        let model = model(sink)
        model.captureThumbnail(bigFrame(), tab: Self.cardTab, now: Date())
        model.clearThumbnail(for: Self.cardTab)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(sink.calls.filter { $0.0 != nil }.isEmpty)
    }

    @Test func clearAllClearsEveryKey() async {
        let sink = Sink()
        let model = model(sink)
        let other = BrowserPageTab(targetId: "T9", route: BrowserRoute(profile: "openclaw", target: "host"))
        let frame = bigFrame(width: 100, height: 60)
        model.captureThumbnail(frame, tab: Self.cardTab, now: Date())
        model.captureThumbnail(frame, tab: other, now: Date())
        #expect(await eventually { sink.calls.count == 2 })
        model.clearAllThumbnails()
        #expect(sink.calls.filter { $0.0 == nil }.count == 2)
        #expect(model.thumbnailLast.isEmpty)
    }

    @Test func closingATabClearsItsThumbnail() async {
        let sink = Sink()
        let model = BrowserPanelModel(
            request: { _, params in
                params["path"]?.string == "/tabs" ? Fixtures.json(#"{"running":true,"tabs":[]}"#) : .object([:])
            },
            hasAdmin: { true }, makeSource: { FakeBrowserSource(ticket: $0) }, debounce: .milliseconds(5), retryDelay: .milliseconds(50))
        model.thumbnailSink = { ref, key in sink.calls.append((ref, key)) }
        model.tabs = [Self.cardTab]
        await model.closeTab("T1")
        #expect(model.tabs.isEmpty)
        #expect(sink.calls.contains { $0.0 == nil && $0.1 == "host|openclaw|T1" })
    }
}

@MainActor
@Suite("Browser page previews screenshots")
struct BrowserPagePreviewsScreenshotTests {
    func ref(_ n: Int) -> ImageRef {
        ImageRef(artifactId: nil, base64: "b\(n)", url: nil, mimeType: "image/jpeg", alt: nil, width: 1, height: 1)
    }

    @Test func capIs32AndOldestIsDropped() {
        let previews = BrowserPagePreviews()
        #expect(BrowserPagePreviews.maxScreenshots == 32)
        for i in 0..<40 { previews.setScreenshot(ref(i), forTab: "k\(i)") }
        #expect(previews.screenshot(forTab: "k0") == nil)
        #expect(previews.screenshot(forTab: "k7") == nil)
        #expect(previews.screenshot(forTab: "k8") != nil)
        #expect(previews.screenshot(forTab: "k39") != nil)
    }

    @Test func updatingRefreshesRecency() {
        let previews = BrowserPagePreviews()
        for i in 0..<32 { previews.setScreenshot(ref(i), forTab: "k\(i)") }
        previews.setScreenshot(ref(100), forTab: "k0")
        previews.setScreenshot(ref(33), forTab: "k32")
        #expect(previews.screenshot(forTab: "k0")?.base64 == "b100")
        #expect(previews.screenshot(forTab: "k1") == nil)
    }

    @Test func nilRemovesAndResetClears() {
        let previews = BrowserPagePreviews()
        previews.setScreenshot(ref(1), forTab: "a")
        previews.setScreenshot(ref(2), forTab: "b")
        previews.setScreenshot(nil, forTab: "a")
        #expect(previews.screenshot(forTab: "a") == nil)
        #expect(previews.screenshot(forTab: "b") != nil)
        previews.reset()
        #expect(previews.screenshot(forTab: "b") == nil)
        // A removed key doesn't hold a slot against the cap.
        for i in 0..<32 { previews.setScreenshot(ref(i), forTab: "n\(i)") }
        #expect(previews.screenshot(forTab: "n0") != nil)
    }
}
