import Foundation
import PincerKit

// Agent management + workspace files (#34): pure helpers and the model against a fake request,
// then the demo and a (mock) Gateway end to end.

/// Records requests and answers them from `handler`.
@MainActor
final class FakeAgentGateway {
    var calls: [(method: String, params: JSONValue)] = []
    var handler: (String, JSONValue) throws -> JSONValue = { _, _ in [:] }

    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        self.calls.append((method, params))
        return try self.handler(method, params)
    }
}

@MainActor
func checkAgentManagement() async {
    print("Agent management")
    check(AgentManagement.agentId(forName: "  Night Owl ") == "night-owl", "id from a spaced name")
    check(AgentManagement.agentId(forName: "Scout") == "scout" && AgentManagement.agentId(forName: "a_b-C") == "a_b-c",
          "valid ids are lowercased as is")
    check(AgentManagement.agentId(forName: "!!!") == nil && AgentManagement.agentId(forName: "   ") == nil, "no id characters → nil")
    check(AgentManagement.agentId(forName: "--Hi There--") == "hi-there", "leading/trailing dashes stripped")
    check(AgentManagement.agentId(forName: "Crème brûlée") == "cr-me-br-l-e", "non-ASCII letters become dashes like upstream")
    check(AgentManagement.agentId(forName: String(repeating: "x", count: 80) + "!")?.count == 64, "ids cut to 64 characters")
    check(AgentManagement.sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "sha256 of empty")
    check(AgentManagement.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 of abc")
    check(AgentManagement.byteCount("é🦞") == 6, "byte count is UTF-8 bytes")
    check(AgentManagement.maxFileBytes == 2_097_152, "2 MiB cap")
    let roster = [AgentSummary(id: "main", name: "Claw"), AgentSummary(id: "scout-copy", name: "Scout Copy")]
    check(AgentManagement.duplicateName(for: "Scout", existing: roster) == "Scout Copy 2", "duplicate name skips taken ids")
    check(AgentManagement.duplicateName(for: "Claw", existing: roster) == "Claw Copy", "first duplicate name")

    // Drafts.
    var draft = AgentDraft(name: " Night Owl ", emoji: "🦉", model: "", workspace: "")
    check(draft.createParams == ["name": "Night Owl", "emoji": "🦉"], "create params skip empty fields (\(draft.createParams))")
    check(draft.validationError == nil && draft.derivedId == "night-owl", "valid draft")
    check(AgentDraft(name: "OpenClaw").validationError != nil && AgentDraft(name: "crestodian").validationError != nil, "reserved ids")
    check(AgentDraft(name: "  ").validationError != nil && AgentDraft(name: "???").validationError != nil, "empty or id-less names")
    check(AgentDraft(name: "Two\nLines").validationError != nil, "one-line names")
    check(AgentDraft(name: "Claw").validationError(existing: roster) == nil
          && AgentDraft(name: "Main").validationError(existing: roster) != nil, "existing id refused")
    let original = AgentDraft(name: "Scout", emoji: "🔭", model: "anthropic/claude-sonnet-5", workspace: "/w/scout")
    check(original.updateParams(agentId: "research", from: original) == nil, "unchanged draft sends nothing")
    draft = original
    draft.name = "Scout II"
    draft.model = ""
    check(draft.updateParams(agentId: "research", from: original) == ["agentId": "research", "name": "Scout II", "model": .null],
          "update sends changed fields; cleared model → null")
    draft = original
    draft.workspace = ""
    check(draft.updateParams(agentId: "research", from: original) == nil && !draft.changesWorkspace(from: original),
          "a cleared workspace is left alone")
    draft.workspace = "/w/other"
    check(draft.changesWorkspace(from: original), "a new workspace is a workspace change")
    let dupe = AgentDraft.duplicate(of: AgentSummary(id: "research", name: "Scout", emoji: "🔭", workspace: "/w/scout", model: "m"),
                                    existing: roster)
    check(dupe.name == "Scout Copy 2" && dupe.workspace.isEmpty && dupe.emoji == "🔭" && dupe.model == "m",
          "duplicate draft: new name, same identity/model, fresh workspace")

    // Wire parsing.
    let entry = AgentFileEntry(json(#"{"name":"SOUL.md","path":"/w/SOUL.md","missing":false,"size":12,"updatedAtMs":1700000000000,"hash":"ABCDEF","content":"hi"}"#))
    check(entry?.hash == "abcdef" && entry?.size == 12 && entry?.content == "hi" && entry?.updatedAt != nil, "file entry parsed")
    let absent = AgentFileEntry(json(#"{"name":"MEMORY.md","path":"/w/MEMORY.md","missing":true,"expectedAbsent":true}"#))
    check(absent?.missing == true && absent?.expectedAbsent == true && absent?.hash == nil, "missing file entry")
    check(AgentFileEntry(json(#"{"name":"BIG.md","size":2097153}"#))?.isTooLarge == true, "over-cap entry")
    let deleted = AgentDeleteResult(json(#"{"ok":true,"agentId":"x","removedBindings":2,"removed":[{"path":"/w","method":"trash"},{"path":"/a","method":"missing"}],"failed":[{"path":"/s","reason":"EPERM"}]}"#), agentId: "x")
    check(deleted.removedBindings == 2 && deleted.trashedPaths == ["/w"] && deleted.failed.first?.reason == "EPERM", "delete result parsed")

    // Error classification (upstream shapes).
    func rpc(_ code: String, _ message: String, _ details: JSONValue? = nil) -> Error {
        GatewayError.rpc(code: code, message: message, details: details)
    }
    check(AgentManagementError.classify(rpc("INVALID_REQUEST", "agent file \"SOUL.md\" changed since it was read",
                                            ["type": "agent_file_conflict", "name": "SOUL.md", "currentHash": "AB"]))
          == .conflict(currentHash: "ab"), "conflict with currentHash")
    check(AgentManagementError.classify(rpc("INVALID_REQUEST", "agent file \"SOUL.md\" changed since it was read",
                                            ["type": "agent_file_conflict", "name": "SOUL.md"])) == .conflict(currentHash: nil),
          "conflict without currentHash")
    check(AgentManagementError.classify(rpc("FORBIDDEN", "missing scope: operator.admin", ["code": "MISSING_SCOPE", "scope": "operator.admin"]))
          == .needsAdmin, "missing scope → needs admin")
    check(AgentManagementError.classify(rpc("UNKNOWN_METHOD", "unknown method: agents.create")) == .unsupported, "unknown method")
    check(AgentManagementError.classify(rpc("INVALID_REQUEST", "agent \"ghost\" not found")) == .notFound("agent \"ghost\" not found"), "not found")
    check(AgentManagementError.classify(rpc("INVALID_REQUEST", "\"openclaw\" is reserved")) == .validation("\"openclaw\" is reserved"),
          "other INVALID_REQUEST verbatim")

    // The model against a fake Gateway.
    let fake = FakeAgentGateway()
    var changed = 0
    let model = AgentManagementModel(methods: { Set(["agents.list", "agents.create", "agents.update", "agents.delete",
                                                     "agents.files.list", "agents.files.get", "agents.files.set"]) },
                                     onAgentsChanged: { changed += 1 },
                                     request: { try await fake.request($0, $1) })
    check(model.canManageAgents && model.canWriteFiles && model.readOnlyReason == nil, "admin + advertised → editable")
    fake.handler = { _, _ in ["ok": true, "agentId": "night-owl", "name": "Night Owl", "workspace": "/w"] }
    let created = try? await model.create(AgentDraft(name: "Night Owl"))
    check(created == "night-owl" && changed == 1 && fake.calls.last?.method == "agents.create", "create refreshes the roster")
    do {
        _ = try await model.create(AgentDraft(name: "OpenClaw"))
        check(false, "reserved name refused before sending")
    } catch {
        check(fake.calls.count == 1 && AgentManagementError.classify(error) != .unsupported, "reserved name refused before sending")
    }
    fake.handler = { _, _ in ["ok": true, "agentId": "night-owl"] }
    let noop = try? await model.update(agentId: "night-owl", original: AgentDraft(name: "A"), draft: AgentDraft(name: "A"))
    check(noop == false && fake.calls.count == 1, "no-op update isn't sent")
    fake.handler = { _, _ in ["ok": true, "agentId": "night-owl", "removedBindings": 1, "removed": [["path": "/w", "method": "trash"]]] }
    let removed = try? await model.delete(agentId: "night-owl", deleteFiles: false)
    check(removed?.removedBindings == 1 && fake.calls.last?.params["deleteFiles"] == false && changed == 2,
          "delete always sends deleteFiles")
    let tooBig = String(repeating: "a", count: AgentManagement.maxFileBytes + 1)
    let sentBefore = fake.calls.count
    do {
        _ = try await model.setFile(agentId: "main", name: "SOUL.md", content: tooBig, expectedHash: nil, expectedMissing: true)
        check(false, "over-cap write refused")
    } catch {
        check(AgentManagementError.classify(error) == .tooLarge(bytes: AgentManagement.maxFileBytes + 1) && fake.calls.count == sentBefore,
              "over-cap write refused before sending")
    }
    fake.handler = { _, params in ["ok": true, "agentId": "main", "workspace": "/w", "file": ["name": params["name"] ?? "", "path": "/w/x", "missing": false, "content": params["content"] ?? ""]] }
    _ = try? await model.setFile(agentId: "main", name: "SOUL.md", content: "x", expectedHash: "ABC", expectedMissing: true)
    check(fake.calls.last?.params["expectedHash"] == "abc" && fake.calls.last?.params["expectedMissing"] == nil,
          "expectedHash wins, lowercased, never both")
    _ = try? await model.setFile(agentId: "main", name: "USER.md", content: "x", expectedHash: nil, expectedMissing: true)
    check(fake.calls.last?.params["expectedMissing"] == true && fake.calls.last?.params["expectedHash"] == nil, "expectedMissing for new files")
    let beforeBadName = fake.calls.count
    let badName = try? await model.getFile(agentId: "main", name: "../etc/passwd")
    check(badName == nil && fake.calls.count == beforeBadName, "unsupported file names aren't sent")
    fake.handler = { method, _ in throw GatewayError.rpc(code: "FORBIDDEN", message: "missing scope: operator.admin",
                                                        details: ["code": "MISSING_SCOPE", "scope": "operator.admin"]) }
    _ = try? await model.create(AgentDraft(name: "Late"))
    check(!model.hasAdmin && model.readOnlyReason == AgentManagement.needsAdminMessage, "scope error turns editing off")
    let noAdmin = AgentManagementModel(scopes: { ["operator.read"] }, request: { try await fake.request($0, $1) })
    check(!noAdmin.canManageAgents && !noAdmin.canWriteFiles && noAdmin.readOnlyReason == AgentManagement.needsAdminMessage,
          "without operator.admin → read-only")
    let demoLike = AgentManagementModel(scopes: { [] }, allowsWritesWithoutAdmin: true, request: { try await fake.request($0, $1) })
    check(demoLike.canManageAgents && demoLike.canWriteFiles, "the demo edits without admin")
    let old = AgentManagementModel(methods: { ["agents.list"] }, request: { try await fake.request($0, $1) })
    check(!old.managementSupported && !old.filesSupported && old.readOnlyReason == AgentManagement.unsupportedMessage,
          "older gateway → unsupported")
    fake.handler = { method, _ in throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: \(method)", details: nil) }
    let unknownList = AgentManagementModel(request: { try await fake.request($0, $1) })
    _ = try? await unknownList.listFiles(agentId: "main")
    check(!unknownList.supports("agents.files.list") && !unknownList.filesSupported, "UNKNOWN_METHOD → method marked unsupported")

    // Editor: dirty tracking, conflict flow, both resolutions.
    var disk: [String: String] = ["SOUL.md": "v1"]
    fake.handler = { method, params in
        let name = params["name"]?.string ?? ""
        switch method {
        case "agents.files.get":
            guard let content = disk[name] else { return ["file": ["name": .string(name), "path": .string("/w/\(name)"), "missing": true]] }
            return ["file": ["name": .string(name), "path": .string("/w/\(name)"), "missing": false, "content": .string(content),
                             "hash": .string(AgentManagement.sha256Hex(content))]]
        case "agents.files.set":
            let current = disk[name].map(AgentManagement.sha256Hex)
            if params["expectedMissing"] == true, current != nil || false {
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "agent file \"\(name)\" changed since it was read",
                                       details: ["type": "agent_file_conflict", "name": .string(name)])
            }
            if let expected = params["expectedHash"]?.string, expected != current {
                var details: [String: JSONValue] = ["type": "agent_file_conflict", "name": .string(name)]
                if let current { details["currentHash"] = .string(current) }
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "agent file \"\(name)\" changed since it was read", details: .object(details))
            }
            let content = params["content"]?.string ?? ""
            disk[name] = content
            return ["ok": true, "file": ["name": .string(name), "path": .string("/w/\(name)"), "missing": false, "content": .string(content),
                                         "hash": .string(AgentManagement.sha256Hex(content)), "size": .number(Double(content.utf8.count))]]
        default:
            return [:]
        }
    }
    let files = AgentManagementModel(request: { try await fake.request($0, $1) })
    let editor = AgentFileEditorModel(agentId: "main", name: "SOUL.md", management: files)
    await editor.load()
    check(editor.hasLoaded && editor.text == "v1" && !editor.isDirty && !editor.canSave, "editor loads clean")
    editor.text = "v2 mine"
    check(editor.isDirty && editor.canSave, "typing makes it dirty")
    disk["SOUL.md"] = "v2 theirs"
    let firstSave = await editor.save()
    check(!firstSave && editor.conflict?.theirs == "v2 theirs" && editor.conflict?.yours == "v2 mine"
          && editor.conflict?.theirsHash == AgentManagement.sha256Hex("v2 theirs") && editor.text == "v2 mine" && !editor.canSave,
          "stale hash → conflict with both versions, draft kept")
    let overwrote = await editor.resolveConflictOverwrite()
    check(overwrote && disk["SOUL.md"] == "v2 mine" && !editor.isDirty && editor.conflict == nil
          && editor.entry?.hash == AgentManagement.sha256Hex("v2 mine"), "overwrite uses their hash and saves")
    editor.text = "v3 mine"
    disk["SOUL.md"] = "v3 theirs"
    _ = await editor.save()
    await editor.resolveConflictKeepTheirs()
    check(editor.text == "v3 theirs" && !editor.isDirty && editor.conflict == nil && disk["SOUL.md"] == "v3 theirs",
          "keep theirs drops the draft")
    editor.text = String(repeating: "é", count: AgentManagement.maxFileBytes / 2 + 1)
    check(editor.exceedsLimit && !editor.canSave, "over the cap → can't save")
    let bigSave = await editor.save()
    check(!bigSave && editor.error == .tooLarge(bytes: AgentManagement.maxFileBytes + 2) && disk["SOUL.md"] == "v3 theirs",
          "over-cap save refused locally")
    editor.revert()
    check(editor.text == "v3 theirs" && !editor.isDirty, "revert")
    let newFile = AgentFileEditorModel(agentId: "main", name: "MEMORY.md", management: files)
    await newFile.load()
    check(newFile.isNew && newFile.text.isEmpty, "missing file opens as new")
    newFile.text = "- remember"
    disk["MEMORY.md"] = "created elsewhere"
    let raced = await newFile.save()
    check(!raced && newFile.conflict?.theirs == "created elsewhere" && newFile.conflict?.theirsMissing == false,
          "expectedMissing race → conflict")
    let forced = await newFile.resolveConflictOverwrite()
    check(forced && disk["MEMORY.md"] == "- remember", "overwrite after a create race")
}

// MARK: Demo

@MainActor
func runDemoAgents(_ gateway: GatewayStore) async {
    print("Agents (demo)")
    let management = gateway.agentManagement
    check(management.canManageAgents && management.canWriteFiles && management.readOnlyReason == nil, "demo edits agents without admin")
    check(gateway.agents.first { $0.id == "main" }?.workspace?.hasSuffix("/workspace") == true, "demo agents carry a workspace")
    do {
        let mainFiles = try await management.listFiles(agentId: "main")
        check(mainFiles.files.map(\.name) == ["AGENTS.md", "SOUL.md", "USER.md", "MEMORY.md"] && mainFiles.files.allSatisfy { !$0.missing },
              "demo main workspace files (\(mainFiles.files.map(\.name)))")
        let coderFiles = try await management.listFiles(agentId: "coder")
        check(coderFiles.files.contains { $0.name == "BOOTSTRAP.md" && !$0.missing }
              && coderFiles.files.contains { $0.name == "SOUL.md" && $0.missing && $0.expectedAbsent },
              "demo coder is mid-onboarding with an optional SOUL.md")
        let soul = try await management.getFile(agentId: "main", name: "SOUL.md")
        check(soul.content?.contains("Claw") == true && soul.hash == soul.content.map(AgentManagement.sha256Hex), "demo file hash")
        let identity = try await management.identity(agentId: "research")
        check(identity.name == "Scout" && identity.emoji == "🔭", "demo agent.identity.get")

        let agentId = try await management.create(AgentDraft(name: "Demo Owl", emoji: "🦉", model: "openai/gpt-5.6-sol"))
        check(agentId == "demo-owl" && gateway.agents.contains { $0.id == "demo-owl" && $0.emoji == "🦉" && $0.model == "openai/gpt-5.6-sol" },
              "demo create shows up in the roster")
        let owlFiles = try await management.listFiles(agentId: agentId)
        check(owlFiles.files.contains { $0.name == "BOOTSTRAP.md" && !$0.missing }, "demo new agent gets seeded files")
        var original = AgentDraft(gateway.agents.first { $0.id == agentId }!)
        var draft = original
        draft.name = "Demo Heron"
        draft.model = ""
        _ = try await management.update(agentId: agentId, original: original, draft: draft)
        let renamed = gateway.agents.first { $0.id == agentId }
        check(renamed?.name == "Demo Heron" && renamed?.model == nil, "demo rename + model cleared")
        let idFile = try await management.getFile(agentId: agentId, name: "IDENTITY.md")
        check(idFile.content?.contains("Demo Heron") == true, "demo rename rewrites IDENTITY.md")
        original = draft

        let editor = management.editor(agentId: agentId, name: "SOUL.md")
        await editor.load()
        editor.text += "\nLoves the night shift.\n"
        let saved = await editor.save()
        check(saved && !editor.isDirty, "demo editor saves")
        let loaded = editor.entry?.hash
        _ = try await management.setFile(agentId: agentId, name: "SOUL.md", content: "someone else", expectedHash: loaded, expectedMissing: false)
        editor.text += "mine"
        let stale = await editor.save()
        check(!stale && editor.conflict?.theirs == "someone else", "demo stale save → conflict")
        await editor.resolveConflictKeepTheirs()
        check(editor.text == "someone else" && editor.conflict == nil, "demo keep theirs")
        management.closeEditor(editor)
        do {
            _ = try await management.setFile(agentId: agentId, name: "SOUL.md", content: "x", expectedHash: loaded, expectedMissing: false)
            check(false, "demo refuses a stale hash")
        } catch {
            if case .conflict(let current) = AgentManagementError.classify(error) {
                check(current == AgentManagement.sha256Hex("someone else"), "demo conflict carries currentHash")
            } else {
                check(false, "demo conflict error (\(error))")
            }
        }

        let copy = try await management.duplicate(sourceId: agentId, draft: AgentDraft.duplicate(of: renamed!, existing: gateway.agents),
                                                  copyFiles: true)
        let copiedSoul = try await management.getFile(agentId: copy.agentId, name: "SOUL.md")
        check(copy.failedFiles.isEmpty && copy.copiedFiles.contains("SOUL.md") && copiedSoul.content == "someone else",
              "demo duplicate copies workspace files (\(copy.copiedFiles), \(copy.failedFiles))")

        let deleted = try await management.delete(agentId: copy.agentId, deleteFiles: true)
        check(deleted.trashedPaths.contains { $0.hasSuffix("workspace-\(copy.agentId)") }, "demo delete trashes the workspace")
        _ = try await management.delete(agentId: agentId, deleteFiles: true)
        check(!gateway.agents.contains { $0.id == agentId || $0.id == copy.agentId }, "demo deleted agents leave the roster")
        do {
            _ = try await management.listFiles(agentId: agentId)
            check(false, "demo deleted agent is gone")
        } catch {
            check(AgentManagementError.classify(error) == .notFound("agent \"\(agentId)\" not found"), "demo deleted agent → not found")
        }
        do {
            _ = try await management.create(AgentDraft(name: "Research"))
            check(false, "demo duplicate id refused")
        } catch {
            check(AgentManagementError.classify(error) == .validation("agent \"research\" already exists"),
                  "demo duplicate id refused (\(AgentManagementError.classify(error).message))")
        }
    } catch {
        check(false, "demo agent management (\(AgentManagementError.classify(error).message))")
    }
}

// MARK: Live

/// Against the mock: `admin` has Full Management; a fresh store reads without it. Only touches agents
/// it creates, so later live checks see the seeded roster.
@MainActor
func runLiveAgents(profile: GatewayProfile, gateway: GatewayStore, admin: GatewayStore) async {
    print("Agents (live)")
    let advertised = admin.hello?.methods ?? []
    guard advertised.contains(AgentManagement.createMethod) else {
        // MOCK_NO_AGENT_MANAGEMENT=1
        check(!admin.agentManagement.managementSupported && admin.agentManagement.readOnlyReason == AgentManagement.unsupportedMessage,
              "gateway without agents.create → unsupported")
        return
    }
    // A fresh connection without Full Management (the shared one may have been dropped by earlier checks).
    let readerProfile = GatewayProfile(name: "Agents reader", url: profile.url, authMode: .token)
    readerProfile.secret = profile.secret
    let readerStore = GatewayStore(profile: readerProfile)
    readerStore.start()
    _ = await waitFor("agents reader") { readerStore.state.isConnected && readerStore.hello != nil }
    defer { readerStore.stop() }
    check(readerStore.hello?.scopes.contains(GatewayConnection.adminScope) == false, "agents reader has no operator.admin")
    let reader = readerStore.agentManagement
    check(!reader.hasAdmin && !reader.canManageAgents && reader.readOnlyReason == AgentManagement.needsAdminMessage,
          "without Full Management → read-only")
    let management = admin.agentManagement
    check(management.canManageAgents && management.canWriteFiles, "admin manages agents")
    let suffix = String(UUID().uuidString.prefix(6)).lowercased()
    do {
        let readable = try await reader.listFiles(agentId: "main")
        check(readable.files.map(\.name) == ["AGENTS.md", "SOUL.md", "USER.md", "MEMORY.md"], "reader lists files (operator.read)")
        do {
            _ = try await reader.create(AgentDraft(name: "Nope \(suffix)"))
            check(false, "reader can't create")
        } catch {
            check(AgentManagementError.classify(error) == .needsAdmin, "reader create → needs admin")
        }
        do {
            let soul = try await reader.getFile(agentId: "main", name: "SOUL.md")
            _ = try await reader.setFile(agentId: "main", name: "SOUL.md", content: "x", expectedHash: soul.hash, expectedMissing: false)
            check(false, "reader can't write files")
        } catch {
            check(AgentManagementError.classify(error) == .needsAdmin, "reader files.set → needs admin")
        }

        // Create.
        let name = "Check Owl \(suffix)"
        let agentId = try await management.create(AgentDraft(name: name, emoji: "🦉", model: "openai/gpt-5.6-sol"))
        check(agentId == "check-owl-\(suffix)", "create derives the id (\(agentId))")
        let row = admin.agents.first { $0.id == agentId }
        check(row?.name == name && row?.emoji == "🦉" && row?.model == "openai/gpt-5.6-sol" && row?.workspace?.hasSuffix("workspace-\(agentId)") == true,
              "created agent in the roster (\(String(describing: row)))")
        let seeded = try await management.listFiles(agentId: agentId)
        check(seeded.files.filter { !$0.missing }.map(\.name) == ["AGENTS.md", "SOUL.md", "USER.md", "BOOTSTRAP.md"]
              && seeded.files.contains { $0.name == "MEMORY.md" && $0.missing && $0.expectedAbsent }, "new workspace seeded")
        do {
            _ = try await management.create(AgentDraft(name: name.uppercased()))
            check(false, "existing id refused")
        } catch {
            check(AgentManagementError.classify(error) == .validation("agent \"\(agentId)\" already exists"),
                  "existing id → gateway message (\(AgentManagementError.classify(error).message))")
        }

        // Update + identity.
        let original = AgentDraft(row!)
        var draft = original
        draft.name = "Check Heron \(suffix)"
        draft.emoji = "🪶"
        draft.model = ""
        _ = try await management.update(agentId: agentId, original: original, draft: draft)
        let updated = admin.agents.first { $0.id == agentId }
        check(updated?.name == draft.name && updated?.emoji == "🪶" && updated?.model == nil, "update: name, emoji, model cleared")
        let identity = try await management.identity(agentId: agentId)
        check(identity.name == draft.name && identity.emoji == "🪶" && identity.nameSource == "agent", "agent.identity.get after update")
        let identityFile = try await management.getFile(agentId: agentId, name: "IDENTITY.md")
        check(identityFile.content?.contains(draft.name) == true, "IDENTITY.md rewritten")

        // Edit, save, conflict with another admin, both resolutions.
        let otherProfile = GatewayProfile(name: "Other agents admin", url: profile.url, authMode: .token, access: .admin)
        otherProfile.secret = profile.secret
        let other = GatewayStore(profile: otherProfile)
        other.start()
        _ = await waitFor("other admin") { other.state.isConnected && other.hello != nil }
        let editor = management.editor(agentId: agentId, name: "SOUL.md")
        await editor.load()
        check(editor.hasLoaded && !editor.isNew && editor.entry?.hash == editor.entry?.content.map(AgentManagement.sha256Hex), "editor loads SOUL.md")
        editor.text += "\n- Answers in haiku.\n"
        let saved = await editor.save()
        check(saved && !editor.isDirty && editor.entry?.hash == AgentManagement.sha256Hex(editor.text), "save → new hash")
        let theirs = try await other.agentManagement.getFile(agentId: agentId, name: "SOUL.md")
        _ = try await other.agentManagement.setFile(agentId: agentId, name: "SOUL.md", content: "# SOUL.md\n\nOther admin was here.\n",
                                                    expectedHash: theirs.hash, expectedMissing: false)
        editor.text += "- Mine.\n"
        let mine = editor.text
        let stale = await editor.save()
        check(!stale && editor.conflict?.theirs == "# SOUL.md\n\nOther admin was here.\n" && editor.text == mine,
              "stale hash → conflict, draft kept")
        let overwrote = await editor.resolveConflictOverwrite()
        let afterOverwrite = try await other.agentManagement.getFile(agentId: agentId, name: "SOUL.md")
        check(overwrote && afterOverwrite.content == mine && !editor.isDirty, "overwrite wins")
        _ = try await other.agentManagement.setFile(agentId: agentId, name: "SOUL.md", content: "theirs again",
                                                    expectedHash: afterOverwrite.hash, expectedMissing: false)
        editor.text += "- again"
        _ = await editor.save()
        await editor.resolveConflictKeepTheirs()
        check(editor.text == "theirs again" && !editor.isDirty && editor.conflict == nil, "keep theirs reloads")
        management.closeEditor(editor)

        // Create a missing file; a second create conflicts.
        let memory = AgentFileEditorModel(agentId: agentId, name: "MEMORY.md", management: management)
        let memoryRace = AgentFileEditorModel(agentId: agentId, name: "MEMORY.md", management: other.agentManagement)
        await memory.load()
        await memoryRace.load()
        check(memory.isNew && memory.canSave && memory.text.isEmpty, "missing MEMORY.md opens as new (saving creates it)")
        memory.text = "- first"
        memoryRace.text = "- second"
        let first = await memory.save()
        let second = await memoryRace.save()
        check(first && !second && memoryRace.conflict?.theirs == "- first" && memoryRace.conflict?.theirsMissing == false,
              "expectedMissing: the second creator conflicts")
        other.stop()

        // Size cap: nothing is sent past 2 MiB; exactly 2 MiB is fine.
        let big = AgentFileEditorModel(agentId: agentId, name: "USER.md", management: management)
        await big.load()
        let userHash = big.entry?.hash
        big.text = String(repeating: "é", count: AgentManagement.maxFileBytes / 2) + "!"
        check(big.exceedsLimit && !big.canSave, "over the cap → save off")
        let refused = await big.save()
        let userAfter = try await management.getFile(agentId: agentId, name: "USER.md")
        check(!refused && big.error == .tooLarge(bytes: AgentManagement.maxFileBytes + 1) && userAfter.hash == userHash,
              "over-cap save not sent")
        big.text = String(repeating: "é", count: AgentManagement.maxFileBytes / 2)
        let atCap = await big.save()
        check(atCap && big.entry?.size == AgentManagement.maxFileBytes, "exactly 2 MiB saves")

        do {
            _ = try await management.getFile(agentId: agentId, name: "TOOLS.md")
            check(false, "TOOLS.md isn't editable")
        } catch {
            check(AgentManagementError.classify(error) == .validation("unsupported file \"TOOLS.md\""), "unsupported file name")
        }

        // Duplicate with files.
        let current = admin.agents.first { $0.id == agentId }!
        let copy = try await management.duplicate(sourceId: agentId, draft: AgentDraft.duplicate(of: current, existing: admin.agents),
                                                  copyFiles: true)
        let copiedSoul = try await management.getFile(agentId: copy.agentId, name: "SOUL.md")
        let copiedMemory = try await management.getFile(agentId: copy.agentId, name: "MEMORY.md")
        check(copy.agentId == "check-heron-\(suffix)-copy" && copy.failedFiles.isEmpty
              && copiedSoul.content == "theirs again" && copiedMemory.content == "- first",
              "duplicate copies existing files into a new workspace (\(copy.agentId), \(copy.copiedFiles), \(copy.failedFiles))")
        check(admin.agents.first { $0.id == copy.agentId }?.workspace != current.workspace, "the copy has its own workspace")

        // Delete both.
        let deleted = try await management.delete(agentId: copy.agentId, deleteFiles: false)
        check(deleted.trashedPaths.isEmpty, "deleteFiles:false keeps the files")
        let deleted2 = try await management.delete(agentId: agentId, deleteFiles: true)
        check(deleted2.trashedPaths.contains { $0.hasSuffix("workspace-\(agentId)") } && deleted2.failed.isEmpty, "delete trashes the workspace")
        check(!admin.agents.contains { $0.id == agentId || $0.id == copy.agentId } && admin.agents.contains { $0.id == "main" },
              "deleted agents leave the roster")
        do {
            _ = try await management.delete(agentId: agentId, deleteFiles: true)
            check(false, "second delete fails")
        } catch {
            check(AgentManagementError.classify(error) == .notFound("agent \"\(agentId)\" not found"), "second delete → not found")
        }
    } catch {
        check(false, "live agent management (\(AgentManagementError.classify(error).message))")
    }
}
