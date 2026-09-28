import Foundation
import Testing
@testable import PincerKit

@Suite("Agent management")
struct AgentManagementTests {
    @Test func agentIdsMatchUpstream() {
        #expect(AgentManagement.agentId(forName: "  Night Owl ") == "night-owl")
        #expect(AgentManagement.agentId(forName: "Scout") == "scout")
        #expect(AgentManagement.agentId(forName: "a_b-C") == "a_b-c")
        #expect(AgentManagement.agentId(forName: "--Hi There--") == "hi-there")
        #expect(AgentManagement.agentId(forName: "Crème brûlée") == "cr-me-br-l-e")
        #expect(AgentManagement.agentId(forName: "!!!") == nil)
        #expect(AgentManagement.agentId(forName: String(repeating: "x", count: 80) + "!")?.count == 64)
    }

    @Test func hashesAndSizes() {
        #expect(AgentManagement.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(AgentManagement.byteCount("é🦞") == 6)
        #expect(AgentManagement.maxFileBytes == 2 * 1024 * 1024)
        #expect(AgentManagement.allowedFileNames == ["AGENTS.md", "SOUL.md", "IDENTITY.md", "USER.md", "BOOTSTRAP.md", "MEMORY.md"])
    }

    @Test func duplicateNames() {
        let roster = [AgentSummary(id: "main", name: "Claw"), AgentSummary(id: "scout-copy", name: "Scout Copy")]
        #expect(AgentManagement.duplicateName(for: "Claw", existing: roster) == "Claw Copy")
        #expect(AgentManagement.duplicateName(for: "Scout", existing: roster) == "Scout Copy 2")
        let draft = AgentDraft.duplicate(of: AgentSummary(id: "research", name: "Scout", emoji: "🔭", workspace: "/w", model: "m"),
                                         existing: roster)
        #expect(draft.name == "Scout Copy 2" && draft.workspace.isEmpty && draft.emoji == "🔭" && draft.model == "m")
    }

    @Test func draftValidation() {
        let roster = [AgentSummary(id: "main", name: "Claw")]
        #expect(AgentDraft(name: "Night Owl").validationError == nil)
        #expect(AgentDraft(name: "  ").validationError != nil)
        #expect(AgentDraft(name: "???").validationError != nil)
        #expect(AgentDraft(name: "OpenClaw").validationError != nil)
        #expect(AgentDraft(name: "crestodian").validationError != nil)
        #expect(AgentDraft(name: "Two\nLines").validationError != nil)
        #expect(AgentDraft(name: "Main").validationError(existing: roster) != nil)
        #expect(AgentDraft(name: "Claw").validationError(existing: roster) == nil, "names don't collide, ids do")
    }

    @Test func createAndUpdateParams() {
        #expect(AgentDraft(name: " Night Owl ", emoji: "🦉").createParams == ["name": "Night Owl", "emoji": "🦉"])
        let original = AgentDraft(name: "Scout", emoji: "🔭", model: "anthropic/claude-sonnet-5", workspace: "/w/scout")
        #expect(original.updateParams(agentId: "research", from: original) == nil)
        var draft = original
        draft.name = "Scout II"
        draft.model = ""
        #expect(draft.updateParams(agentId: "research", from: original) == ["agentId": "research", "name": "Scout II", "model": .null])
        draft = original
        draft.workspace = ""
        #expect(draft.updateParams(agentId: "research", from: original) == nil)
        #expect(!draft.changesWorkspace(from: original))
        draft.workspace = "/w/other"
        #expect(draft.changesWorkspace(from: original))
        #expect(draft.updateParams(agentId: "research", from: original)?["workspace"] == "/w/other")
    }

    @Test func parsesWireShapes() {
        let entry = AgentFileEntry(Fixtures.json(#"{"name":"SOUL.md","path":"/w/SOUL.md","missing":false,"size":12,"updatedAtMs":1700000000000,"hash":"ABCDEF","content":"hi"}"#))
        #expect(entry?.hash == "abcdef" && entry?.size == 12 && entry?.content == "hi")
        #expect(entry?.updatedAt == Date(timeIntervalSince1970: 1_700_000_000))
        let missing = AgentFileEntry(Fixtures.json(#"{"name":"MEMORY.md","path":"/w/MEMORY.md","missing":true,"expectedAbsent":true}"#))
        #expect(missing?.missing == true && missing?.expectedAbsent == true && missing?.hash == nil)
        #expect(AgentFileEntry(Fixtures.json(#"{"name":"BIG.md","size":2097153}"#))?.isTooLarge == true)
        let deleted = AgentDeleteResult(Fixtures.json(#"""
        {"ok":true,"agentId":"x","removedBindings":2,"removed":[{"path":"/w","method":"trash"},{"path":"/a","method":"missing"}],
         "failed":[{"path":"/s","reason":"EPERM"}],"purgeFailed":true}
        """#), agentId: "x")
        #expect(deleted.removedBindings == 2 && deleted.trashedPaths == ["/w"] && deleted.failed.first?.reason == "EPERM" && deleted.purgeFailed)
        let identity = AgentIdentity(Fixtures.json(#"{"agentId":"research","name":"Scout","nameSource":"agent","avatar":"S","emoji":"🔭"}"#),
                                     agentId: "research")
        #expect(identity.name == "Scout" && identity.nameSource == "agent" && identity.emoji == "🔭")
        let summary = AgentSummary(Fixtures.json(#"{"id":"coder","workspace":"/w/c","model":{"primary":"m"},"identity":{"name":"Forge","emoji":"🛠️","avatar":"a.png"}}"#))
        #expect(summary?.workspace == "/w/c" && summary?.model == "m" && summary?.avatar == "a.png" && summary?.title == "🛠️ Forge")
    }

    @Test func classifiesUpstreamErrors() {
        func rpc(_ code: String, _ message: String, _ details: JSONValue? = nil) -> Error {
            GatewayError.rpc(code: code, message: message, details: details)
        }
        #expect(AgentManagementError.classify(rpc("INVALID_REQUEST", "agent file \"SOUL.md\" changed since it was read",
                                                  ["type": "agent_file_conflict", "name": "SOUL.md", "currentHash": "AB"])) == .conflict(currentHash: "ab"))
        #expect(AgentManagementError.classify(rpc("INVALID_REQUEST", "agent file \"SOUL.md\" changed since it was read",
                                                  ["type": "agent_file_conflict", "name": "SOUL.md"])) == .conflict(currentHash: nil))
        #expect(AgentManagementError.classify(rpc("FORBIDDEN", "missing scope: operator.admin",
                                                  ["code": "MISSING_SCOPE", "scope": "operator.admin"])) == .needsAdmin)
        #expect(AgentManagementError.classify(rpc("UNKNOWN_METHOD", "unknown method: agents.create")) == .unsupported)
        #expect(AgentManagementError.classify(rpc("INVALID_REQUEST", "agent \"ghost\" not found")) == .notFound("agent \"ghost\" not found"))
        #expect(AgentManagementError.classify(rpc("INVALID_REQUEST", "\"openclaw\" is reserved")) == .validation("\"openclaw\" is reserved"))
    }

    // MARK: Model

    @MainActor
    final class Recorder {
        var calls: [(method: String, params: JSONValue)] = []
        var handler: (String, JSONValue) throws -> JSONValue = { _, _ in [:] }
        func request(_ method: String, _ params: JSONValue) throws -> JSONValue {
            self.calls.append((method, params))
            return try self.handler(method, params)
        }
    }

    @MainActor @Test func capabilities() {
        let recorder = Recorder()
        let all: Set<String> = ["agents.create", "agents.update", "agents.delete", "agents.files.list", "agents.files.get", "agents.files.set"]
        let admin = AgentManagementModel(methods: { all }, request: { try recorder.request($0, $1) })
        #expect(admin.canManageAgents && admin.canWriteFiles && admin.readOnlyReason == nil)
        let reader = AgentManagementModel(methods: { all }, scopes: { ["operator.read"] }, request: { try recorder.request($0, $1) })
        #expect(!reader.canManageAgents && !reader.canWriteFiles && reader.readOnlyReason == AgentManagement.needsAdminMessage)
        let demo = AgentManagementModel(scopes: { [] }, allowsWritesWithoutAdmin: true, request: { try recorder.request($0, $1) })
        #expect(demo.canManageAgents && demo.canWriteFiles)
        let old = AgentManagementModel(methods: { ["agents.list"] }, request: { try recorder.request($0, $1) })
        #expect(!old.managementSupported && !old.filesSupported && old.readOnlyReason == AgentManagement.unsupportedMessage)
    }

    @MainActor @Test func requestsSentAndRefused() async throws {
        let recorder = Recorder()
        var changed = 0
        let model = AgentManagementModel(onAgentsChanged: { changed += 1 }, request: { try recorder.request($0, $1) })
        recorder.handler = { _, _ in ["ok": true, "agentId": "night-owl"] }
        #expect(try await model.create(AgentDraft(name: "Night Owl")) == "night-owl")
        #expect(changed == 1 && recorder.calls.last?.params == ["name": "Night Owl"])
        await #expect(throws: AgentManagementError.self) { try await model.create(AgentDraft(name: "OpenClaw")) }
        #expect(recorder.calls.count == 1, "reserved names aren't sent")
        #expect(try await model.update(agentId: "x", original: AgentDraft(name: "A"), draft: AgentDraft(name: "A")) == false)
        #expect(recorder.calls.count == 1, "no-op updates aren't sent")
        _ = try await model.delete(agentId: "night-owl", deleteFiles: false)
        #expect(recorder.calls.last?.params == ["agentId": "night-owl", "deleteFiles": false] && changed == 2)
        _ = try await model.delete(agentId: "night-owl", deleteFiles: true)
        #expect(recorder.calls.last?.params == ["agentId": "night-owl", "deleteFiles": true], "deleteFiles is always explicit")
        recorder.calls = []

        await #expect(throws: AgentManagementError.tooLarge(bytes: AgentManagement.maxFileBytes + 1)) {
            try await model.setFile(agentId: "main", name: "SOUL.md", content: String(repeating: "a", count: AgentManagement.maxFileBytes + 1),
                                    expectedHash: nil, expectedMissing: true)
        }
        await #expect(throws: AgentManagementError.validation("unsupported file \"TOOLS.md\"")) {
            try await model.getFile(agentId: "main", name: "TOOLS.md")
        }
        #expect(recorder.calls.isEmpty, "oversized and unsupported files aren't sent")
        recorder.handler = { _, _ in ["ok": true] }
        _ = try await model.setFile(agentId: "main", name: "SOUL.md", content: "x", expectedHash: "ABC", expectedMissing: true)
        #expect(recorder.calls.last?.params["expectedHash"] == "abc" && recorder.calls.last?.params["expectedMissing"] == nil)
        _ = try await model.setFile(agentId: "main", name: "USER.md", content: "x", expectedHash: nil, expectedMissing: true)
        #expect(recorder.calls.last?.params["expectedMissing"] == true && recorder.calls.last?.params["expectedHash"] == nil)

        recorder.handler = { _, _ in
            throw GatewayError.rpc(code: "FORBIDDEN", message: "missing scope: operator.admin", details: ["code": "MISSING_SCOPE"])
        }
        await #expect(throws: AgentManagementError.needsAdmin) { try await model.create(AgentDraft(name: "Late")) }
        #expect(!model.hasAdmin && model.readOnlyReason == AgentManagement.needsAdminMessage)
        recorder.handler = { method, _ in throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: \(method)", details: nil) }
        await #expect(throws: AgentManagementError.unsupported) { try await model.listFiles(agentId: "main") }
        #expect(!model.filesSupported)
    }

    @MainActor @Test func duplicateCopiesFilesNotBindings() async throws {
        let recorder = Recorder()
        let source: [String: String] = ["AGENTS.md": "a", "SOUL.md": "s", "MEMORY.md": "m"]
        var target: [String: String] = ["AGENTS.md": "seeded", "SOUL.md": "s"]
        recorder.handler = { method, params in
            let agent = params["agentId"]?.string
            let name = params["name"]?.string ?? ""
            let files = agent == "src" ? source : target
            switch method {
            case "agents.create": return ["ok": true, "agentId": "copy"]
            case "agents.files.list":
                return ["files": .array(["AGENTS.md", "SOUL.md", "USER.md", "MEMORY.md"].map {
                    ["name": .string($0), "missing": .bool(files[$0] == nil)]
                })]
            case "agents.files.get":
                guard let content = files[name] else { return ["file": ["name": .string(name), "missing": true]] }
                return ["file": ["name": .string(name), "missing": false, "content": .string(content),
                                 "hash": .string(AgentManagement.sha256Hex(content))]]
            case "agents.files.set":
                target[name] = params["content"]?.string
                return ["ok": true]
            default: return [:]
            }
        }
        let model = AgentManagementModel(request: { try recorder.request($0, $1) })
        let draft = AgentDraft.duplicate(of: AgentSummary(id: "src", name: "Scout", emoji: "🔭", workspace: "/w/src"), existing: [])
        let result = try await model.duplicate(sourceId: "src", draft: draft, copyFiles: true)
        #expect(result.agentId == "copy" && result.failedFiles.isEmpty && Set(result.copiedFiles) == ["AGENTS.md", "SOUL.md", "MEMORY.md"])
        #expect(target == source.merging(["SOUL.md": "s"]) { $1 })
        let create = recorder.calls.first { $0.method == "agents.create" }?.params
        #expect(create == ["name": "Scout Copy", "emoji": "🔭"], "no workspace, no bindings")
        #expect(Set(recorder.calls.map(\.method)).isSubset(of: ["agents.create", "agents.files.list", "agents.files.get", "agents.files.set"]),
                "nothing touches bindings or config")
        let sets = recorder.calls.filter { $0.method == "agents.files.set" }
        #expect(sets.first { $0.params["name"] == "MEMORY.md" }?.params["expectedMissing"] == true, "absent target → expectedMissing")
        #expect(sets.first { $0.params["name"] == "AGENTS.md" }?.params["expectedHash"]?.string == AgentManagement.sha256Hex("seeded"),
                "seeded target → its hash")
        #expect(!sets.contains { $0.params["name"] == "SOUL.md" }, "identical files aren't rewritten")

        recorder.calls = []
        let plain = try await model.duplicate(sourceId: "src", draft: draft, copyFiles: false)
        #expect(plain.copiedFiles.isEmpty && recorder.calls.map(\.method) == ["agents.create"])
    }

    @MainActor @Test func deniedAdminKeepsEdits() async {
        let recorder = Recorder()
        recorder.handler = { method, _ in
            if method == "agents.files.set" {
                throw GatewayError.rpc(code: "FORBIDDEN", message: "missing scope: operator.admin", details: ["code": "MISSING_SCOPE"])
            }
            return ["file": ["name": "SOUL.md", "missing": false, "content": "v1", "hash": .string(AgentManagement.sha256Hex("v1"))]]
        }
        let model = AgentManagementModel(request: { try recorder.request($0, $1) })
        let editor = model.editor(agentId: "main", name: "SOUL.md")
        await editor.load()
        editor.text = "v2"
        #expect(await editor.save() == false)
        #expect(editor.error == .needsAdmin && editor.text == "v2" && editor.isDirty && editor.conflict == nil)
        #expect(!model.canWriteFiles && !editor.canEdit && model.readOnlyReason == AgentManagement.needsAdminMessage)
        #expect(model.hasUnsavedChanges, "the draft survives")
    }

    // MARK: Editor + demo

    /// The demo Gateway answers for real, so the editor runs against the same handler as the app's demo.
    @MainActor
    static func demoModel() -> (AgentManagementModel, DemoGateway) {
        let demo = DemoGateway()
        let model = AgentManagementModel(scopes: { [] }, allowsWritesWithoutAdmin: true,
                                         request: { method, params in try await demo.handle(method, params) })
        return (model, demo)
    }

    @MainActor @Test func editorConflictFlow() async throws {
        let (model, demo) = Self.demoModel()
        let editor = model.editor(agentId: "main", name: "SOUL.md")
        await editor.load()
        #expect(editor.hasLoaded && !editor.isDirty && !editor.canSave && editor.text.contains("Claw"))
        #expect(editor.entry?.hash == AgentManagement.sha256Hex(editor.text))
        editor.text += "\nmine"
        #expect(editor.isDirty && editor.canSave && model.hasUnsavedChanges)
        let mine = editor.text
        let loadedHash = editor.entry?.hash
        _ = try await demo.handle("agents.files.set", ["agentId": "main", "name": "SOUL.md", "content": "theirs",
                                                      "expectedHash": .string(loadedHash ?? "")])
        #expect(await editor.save() == false)
        #expect(editor.conflict?.theirs == "theirs" && editor.conflict?.yours == mine && editor.text == mine && !editor.canSave)
        #expect(editor.conflict?.theirsHash == AgentManagement.sha256Hex("theirs"))
        #expect(await editor.resolveConflictOverwrite())
        #expect(!editor.isDirty && editor.conflict == nil && editor.entry?.hash == AgentManagement.sha256Hex(mine))
        let onDisk = try await demo.handle("agents.files.get", ["agentId": "main", "name": "SOUL.md"])
        #expect(onDisk["file"]?["content"]?.string == mine)

        _ = try await demo.handle("agents.files.set", ["agentId": "main", "name": "SOUL.md", "content": "theirs again"])
        editor.text += "!"
        _ = await editor.save()
        await editor.resolveConflictKeepTheirs()
        #expect(editor.text == "theirs again" && !editor.isDirty && editor.conflict == nil)

        editor.text = String(repeating: "é", count: AgentManagement.maxFileBytes / 2) + "!"
        #expect(editor.exceedsLimit && !editor.canSave)
        #expect(await editor.save() == false)
        #expect(editor.error == .tooLarge(bytes: AgentManagement.maxFileBytes + 1))
        editor.revert()
        #expect(editor.text == "theirs again")
        model.closeEditor(editor)
        #expect(!model.hasUnsavedChanges)
    }

    @MainActor @Test func editorCreatesMissingFiles() async throws {
        let (model, demo) = Self.demoModel()
        let memory = AgentFileEditorModel(agentId: "research", name: "MEMORY.md", management: model)
        await memory.load()
        #expect(memory.isNew && memory.text.isEmpty && memory.canSave)
        memory.text = "- mine"
        _ = try await demo.handle("agents.files.set", ["agentId": "research", "name": "MEMORY.md", "content": "- theirs", "expectedMissing": true])
        #expect(await memory.save() == false)
        #expect(memory.conflict?.theirs == "- theirs" && memory.conflict?.theirsMissing == false)
        #expect(await memory.resolveConflictOverwrite())
        let saved = try await demo.handle("agents.files.get", ["agentId": "research", "name": "MEMORY.md"])
        #expect(saved["file"]?["content"]?.string == "- mine")
    }

    @Test func demoSeedsAndFileRules() async throws {
        let demo = DemoGateway()
        let list = try await demo.handle("agents.list", [:])
        let agents = list["agents"]?.array ?? []
        #expect(agents.compactMap { $0["id"]?.string } == ["main", "research", "coder", "kiko"])
        #expect(agents.first?["workspace"]?.string == "/Users/demo/.openclaw/workspace")
        #expect(agents.allSatisfy { $0["workspace"]?.string?.hasPrefix("/Users/demo/.openclaw/workspace") == true })

        let main = try await demo.handle("agents.files.list", ["agentId": "main"])
        #expect(main["files"]?.array?.compactMap { $0["name"]?.string } == ["AGENTS.md", "SOUL.md", "USER.md", "MEMORY.md"],
                "IDENTITY.md hidden; BOOTSTRAP.md hidden once set up")
        #expect(main["files"]?.array?.allSatisfy { $0["hash"] == nil && $0["content"] == nil } == true, "list has no content")
        let coder = try await demo.handle("agents.files.list", ["agentId": "coder"])
        #expect(coder["files"]?.array?.contains { $0["name"] == "BOOTSTRAP.md" && $0["missing"] == false } == true)
        #expect(coder["files"]?.array?.contains { $0["name"] == "SOUL.md" && $0["missing"] == true && $0["expectedAbsent"] == true } == true)

        let soul = try await demo.handle("agents.files.get", ["agentId": "main", "name": "SOUL.md"])
        let content = soul["file"]?["content"]?.string ?? ""
        #expect(soul["file"]?["hash"]?.string == AgentManagement.sha256Hex(content))
        #expect(soul["file"]?["size"]?.int == content.utf8.count)

        await #expect(throws: GatewayError.self) {
            try await demo.handle("agents.files.get", ["agentId": "main", "name": "TOOLS.md"])
        }
        do {
            _ = try await demo.handle("agents.files.set", ["agentId": "main", "name": "SOUL.md", "content": "x",
                                                          "expectedHash": .string(String(repeating: "0", count: 64))])
            Issue.record("stale hash accepted")
        } catch let GatewayError.rpc(code, message, details) {
            #expect(code == "INVALID_REQUEST" && message == "agent file \"SOUL.md\" changed since it was read")
            #expect(details?["type"] == "agent_file_conflict" && details?["currentHash"]?.string == AgentManagement.sha256Hex(content))
        }
        do {
            _ = try await demo.handle("agents.files.set", ["agentId": "main", "name": "SOUL.md", "content": "x",
                                                          "expectedHash": "abc", "expectedMissing": true])
            Issue.record("bad preconditions accepted")
        } catch let GatewayError.rpc(code, message, _) {
            #expect(code == "INVALID_REQUEST" && message.hasPrefix("invalid agents.files.set params"))
        }
    }

    @Test func demoAgentLifecycle() async throws {
        let demo = DemoGateway()
        let created = try await demo.handle("agents.create", ["name": "Night Owl", "emoji": "🦉", "model": "openai/gpt-5.6-sol"])
        #expect(created["agentId"] == "night-owl" && created["workspace"] == "/Users/demo/.openclaw/workspace-night-owl")
        await #expect(throws: GatewayError.rpc(code: "INVALID_REQUEST", message: "agent \"night-owl\" already exists", details: nil)) {
            try await demo.handle("agents.create", ["name": "NIGHT OWL"])
        }
        await #expect(throws: GatewayError.rpc(code: "INVALID_REQUEST", message: "\"openclaw\" is reserved", details: nil)) {
            try await demo.handle("agents.create", ["name": "OpenClaw"])
        }
        _ = try await demo.handle("agents.update", ["agentId": "night-owl", "name": "Heron", "model": .null])
        let row = try await demo.handle("agents.list", [:])["agents"]?.array?.first { $0["id"] == "night-owl" }
        #expect(row?["identity"]?["name"] == "Heron" && row?["model"] == nil)
        let identity = try await demo.handle("agent.identity.get", ["agentId": "night-owl"])
        #expect(identity["name"] == "Heron" && identity["emoji"] == "🦉")
        let unknown = try await demo.handle("agent.identity.get", ["agentId": "ghost"])
        #expect(unknown["name"] == "Assistant" && unknown["nameSource"] == "default")

        let deleted = try await demo.handle("agents.delete", ["agentId": "night-owl"])
        #expect(deleted["ok"] == true && deleted["removed"]?.array?.contains { $0["path"] == "/Users/demo/.openclaw/workspace-night-owl" } == true)
        await #expect(throws: GatewayError.rpc(code: "INVALID_REQUEST", message: "agent \"night-owl\" not found", details: nil)) {
            try await demo.handle("agents.files.list", ["agentId": "night-owl"])
        }
    }
}
