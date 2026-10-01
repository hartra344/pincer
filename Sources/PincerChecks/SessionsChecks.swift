import Foundation
import PincerKit

// Session manager (#38): pure helpers and the model against a fake request, then the demo and a
// (mock) Gateway end to end.

@MainActor
func checkSessionManager() async {
    print("Session manager")
    func row(_ key: String, _ extra: [String: JSONValue] = [:]) -> SessionRow {
        var object: [String: JSONValue] = ["key": .string(key)]
        for (field, value) in extra { object[field] = value }
        return SessionRow(.object(object))!
    }
    let live = row("agent:main:dashboard:a", ["label": "Alpha", "agentId": "main", "sessionId": "s-a", "lastActivityAt": 3000])
    let old = row("agent:research:dashboard:b", ["label": "Beta", "archived": true, "archivedAt": 2000, "lastActivityAt": 2000])
    let bare = row("agent:main:dashboard:c", ["label": "Gamma", "archivedAt": 1000, "lastActivityAt": 5000])
    let rows = [old, live, bare]
    check(SessionManager.filtered(rows, filter: .active).map(\.key) == [live.key], "active filter hides archived")
    check(SessionManager.filtered(rows, filter: .archived).map(\.key) == [bare.key, old.key], "archived filter, newest first")
    check(SessionManager.filtered(rows, filter: .all).count == 3 && SessionManager.filtered(rows, filter: .all, search: "research").map(\.key) == [old.key],
          "all filter and search")
    check(SessionManagerFilter.archived.listParam == true && SessionManagerFilter.all.listParam == "all", "upstream archived params")

    let plan = SessionManager.deletePlan([live, old], hasAdmin: false)
    check(plan.deletable == [old.key] && plan.blocked == [live.key] && plan.needsAdmin, "delete without admin: archived only")
    check(SessionManager.deletePlan([live, old], hasAdmin: true).canDelete, "delete with admin: everything")
    check(SessionManager.deleteParams(old)["archivedOnly"] == true && SessionManager.deleteParams(live)["archivedOnly"] == nil,
          "archivedOnly iff archived")
    check(SessionManager.patchManyBatches((0..<201).map { row("k\($0)") }).map(\.count) == [100, 100, 1], "patchMany batches of 100")

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let running = row("r", ["status": "running", "hasActiveRun": true, "startedAt": .number(now.timeIntervalSince1970 * 1000 - 125_000)])
    let failed = row("f", ["status": "failed", "runtimeMs": 94_000, "startedAt": 1, "endedAt": 2])
    check(SessionRunState(row: running) == .running && SessionManager.runDuration(running, now: now) == 125, "running duration ticks")
    check(SessionRunState(row: failed).isError && SessionManager.runDuration(failed, now: now) == 94, "failed run: runtimeMs")
    check(SessionRunState(row: row("s", ["status": "running"])) == .idle, "running status without an active run → idle")
    check(SessionManager.formatDuration(125) == "2m 5s" && SessionManager.formatDuration(3780) == "1h 3m" && SessionManager.formatDuration(4) == "4s",
          "duration text")
    check(SessionManager.bulkSummary(verb: "Archived", SessionBulkOutcome(succeeded: ["a", "b"], failed: [.init(key: "c", message: "x")]))
          == "Archived 2 sessions; 1 failed", "bulk summary")
    check(SessionBranch(["leafEntryId": "abcdef1234", "headline": "", "active": true])?.title == "Branch abcdef12", "untitled branch")
    check(SessionPreview(["key": "k", "status": "cold", "items": []])?.emptyReason == "The transcript isn't loaded on the Gateway yet",
          "cold preview reason")

    // Gating and scopes against a fake.
    let fake = FakeAgentGateway()
    let writer = SessionManagerModel(scopes: { ["operator.read", "operator.write"] }, request: { try await fake.request($0, $1) })
    check(!writer.canRewind && !writer.canSwitchBranch && writer.supportsArchive && writer.canRecover(row("t", ["restartRecoveryStatus": "tombstoned"])),
          "writer: no branch tools, archive and recover allowed")
    let older = SessionManagerModel(methods: { ["sessions.list", "sessions.patch"] }, request: { try await fake.request($0, $1) })
    check(!older.supportsPreview && !older.supportsBranches && !older.supportsRecover && older.supportsArchive, "older gateway gating")
    fake.handler = { method, _ in
        switch method {
        case "sessions.list": return ["sessions": [live.raw, old.raw]]
        case "sessions.patchMany": throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: sessions.patchMany", details: nil)
        case "sessions.delete": return ["ok": true, "key": "x", "deleted": true, "archived": []]
        default: return ["ok": true]
        }
    }
    await writer.load(filter: .all)
    let archived = await writer.setArchived([live.key], archived: true)
    check(archived.succeeded == [live.key] && fake.calls.map(\.method).suffix(2) == ["sessions.patchMany", "sessions.patch"],
          "patchMany unknown → per-key sessions.patch")
    fake.calls = []
    await writer.load(filter: .all)
    fake.calls = []
    let deleted = await writer.delete([old.key])
    check(deleted.succeeded == [old.key] && fake.calls.first?.params["archivedOnly"] == true, "writer deletes archived with archivedOnly")
    fake.handler = { _, _ in throw GatewayError.rpc(code: "INVALID_REQUEST", message: "missing scope: operator.admin", details: nil) }
    let admin = SessionManagerModel(request: { try await fake.request($0, $1) })
    let switched = await admin.switchBranch(key: "k", leafEntryId: "l")
    check(!switched && admin.deniedAdmin && admin.actionError == SessionManager.needsAdminMessage, "scope error → needs Full Management")
}

/// The demo's Sessions page: every flow against seeded sessions (see DemoGateway+Sessions.swift).
/// Caches a one-message transcript for `key` holding `word`, and waits until search indexes it.
@MainActor
private func seedRemovalCache(_ gateway: GatewayStore, _ key: String, word: String) async -> Bool {
    await TranscriptCache.save(TranscriptCache.Snapshot(items: [messageItem("seed-\(word)", .user, "\(word) removal probe", at: 1)], complete: true),
                               gatewayId: gateway.id, sessionKey: key)
    var indexed = false
    for _ in 0..<50 where !indexed {
        indexed = await !((try? gateway.messageIndex.search(word)) ?? []).isEmpty
        if !indexed { try? await Task.sleep(for: .milliseconds(100)) }
    }
    return indexed && fileExists(TranscriptCache.file(gatewayId: gateway.id, sessionKey: key))
}

/// #225: the probe is gone from the cache and from search (`fileGone`: the file itself, for deletes;
/// a rewound open chat may refetch and save the post-rewind history, which lacks the probe).
@MainActor
private func checkRemovalProbe(_ gateway: GatewayStore, _ key: String, word: String, fileGone: Bool, _ label: String) async {
    var gone = false
    for _ in 0..<50 where !gone {
        let cached = await TranscriptCache.load(gatewayId: gateway.id, sessionKey: key)
        let hits = (try? await gateway.messageIndex.search(word)) ?? []
        let cacheClean = fileGone ? !fileExists(TranscriptCache.file(gatewayId: gateway.id, sessionKey: key))
            : cached?.items.contains { $0.plainText.contains(word) } != true
        gone = cacheClean && hits.isEmpty
        if !gone { try? await Task.sleep(for: .milliseconds(100)) }
    }
    check(gone, label)
}

@MainActor
func runDemoSessions(_ gateway: GatewayStore) async {
    print("Session manager (demo)")
    let garden = "agent:main:dashboard:garden", taxes = "agent:main:dashboard:tax-2025"
    let bench = "agent:research:dashboard:gpu-bench", refactor = "agent:coder:dashboard:refactor"
    let ciFix = "agent:coder:dashboard:ci-fix", photo = "agent:main:dashboard:photo-import"
    let manager = gateway.sessionManager
    check(gateway.supportsSessionManager && manager.hasAdmin && manager.canRewind && manager.canSwitchBranch && manager.supportsRecover,
          "demo manages sessions without admin")

    await manager.load(filter: .active)
    let active = Set(manager.visibleRows().map(\.key))
    check(active.isSuperset(of: [garden, refactor, ciFix, photo]) && active.isDisjoint(with: [taxes, bench]),
          "demo active list (\(active.count))")
    await manager.load(filter: .archived)
    let archivedKeys = Set(manager.visibleRows().map(\.key))
    check(archivedKeys.isSuperset(of: [taxes, bench]) && archivedKeys.isDisjoint(with: active)
          && manager.visibleRows().allSatisfy(\.isArchived), "demo archived list (\(archivedKeys.count))")
    await manager.load(filter: .all)
    check(manager.visibleRows().count >= active.count + 2, "demo all list")
    check(manager.visibleRows(search: "garden").map(\.key) == [garden], "demo search")

    if let running = manager.row(refactor), let failed = manager.row(ciFix) {
        let elapsed = SessionManager.runDuration(running, now: Date()) ?? -1
        // The seeded run finishes on its own 90 s after connecting, so a slow run may see it done.
        let state = SessionRunState(row: running)
        check((state == .running || state == .done) && elapsed >= 300, "demo running session with duration (\(state), \(elapsed))")
        check(SessionRunState(row: failed) == .failed && SessionManager.runDuration(failed, now: Date()) == 94, "demo failed run 1m 34s")
    } else {
        check(false, "demo seeds running and failed sessions")
    }

    await manager.loadPreview(key: garden)
    check(manager.previews[garden]?.items.last?.text.hasPrefix("Swap the tomatoes") == true, "demo preview")
    await manager.loadDetails(key: garden)
    check(manager.details[garden]?.title == "Garden planner", "demo details")

    await manager.loadBranches(key: garden)
    let branches = manager.branches[garden] ?? []
    check(branches.count == 3 && branches.first?.active == true, "demo lists three branches, active first (\(branches.count))")
    if let drip = branches.first(where: { $0.headline.hasPrefix("Run a") }) {
        let previousUpdatedAt = gateway.sessions[garden]?.raw["updatedAt"]?.double
        let ok = await manager.switchBranch(key: garden, leafEntryId: drip.leafEntryId)
        check(ok && manager.branches[garden]?.first?.leafEntryId == drip.leafEntryId, "demo switch branch (\(manager.actionError ?? ""))")
        if ok {
            let refreshed = await waitFor("demo branch switch session row") {
                guard let row = gateway.sessions[garden],
                      row.raw["activeLeafEntryId"]?.text == drip.leafEntryId,
                      let updatedAt = row.raw["updatedAt"]?.double
                else { return false }
                return updatedAt != previousUpdatedAt
            }
            check(refreshed, "demo branch switch refreshes the garden row")
            if refreshed {
                if let row = gateway.sessions[garden], let updatedAt = row.raw["updatedAt"]?.double {
                    let receivedAt = Date.now.timeIntervalSince1970 * 1000
                    check(updatedAt <= receivedAt,
                          "demo branch switch updatedAt does not exceed response receipt time (\(updatedAt) ≤ \(receivedAt))")
                    if let activityDate = row.activityDate {
                        let expected = String(localized: "now", bundle: PincerStrings.bundle ?? .main)
                        check(SidebarActivityDate.relativeDate(activityDate, now: activityDate) == expected,
                              "demo branch switch activity formats as now using its seeded session timestamp")
                    } else {
                        check(false, "demo branch switch row has an activity timestamp")
                    }
                } else {
                    check(false, "demo branch switch row has an updatedAt timestamp")
                }
            }
        }
    } else {
        check(false, "demo drip branch (\(branches.map(\.headline)))")
    }
    await manager.loadRewindPoints(key: garden)
    let demoSeeded = await seedRemovalCache(gateway, garden, word: "gardenprobexq")
    check(demoSeeded, "demo rewind: probe cached and searchable")
    if let point = manager.rewindPoints[garden]?.first {
        let chat = gateway.chat(for: garden)
        let emptyBefore = chat.draft.text.isEmpty
        let ok = await manager.rewind(key: garden, entryId: point.entryId)
        check(ok && manager.lastEditorText == "Add a drip irrigation plan.", "demo rewind returns the cut message (\(manager.lastEditorText ?? "nil"))")
        let composer = await waitFor("rewind draft", timeout: 5) { chat.draft.text == "Add a drip irrigation plan." }
        check(!emptyBefore || composer, "rewound text goes back into an open, empty composer (\(chat.draft.text))")
        let reloaded = await waitFor("rewound chat reloads", timeout: 5) {
            !chat.items.contains { $0.plainText == "Add a drip irrigation plan." }
        }
        check(reloaded, "the open chat reloads without the cut messages")
        await checkRemovalProbe(gateway, garden, word: "gardenprobexq", fileGone: false, "demo rewind drops the cached transcript and its search hits")
    } else {
        check(false, "demo rewind points")
    }

    let archive = await manager.setArchived([ciFix], archived: true)
    check(archive.succeeded == [ciFix] && manager.row(ciFix)?.isArchived == true, "demo archive (\(manager.actionError ?? ""))")
    let restore = await manager.setArchived([ciFix], archived: false)
    check(restore.succeeded == [ciFix] && manager.row(ciFix)?.isArchived == false, "demo unarchive")
    let main = await manager.setArchived(["agent:main:main"], archived: true)
    check(main.failed.first?.message == "Cannot archive an agent's main session.", "demo protects main sessions")

    let benchSeeded = await seedRemovalCache(gateway, bench, word: "benchprobexq")
    let deleted = await manager.delete([bench])
    check(deleted.succeeded == [bench] && manager.row(bench) == nil, "demo delete archived (\(manager.actionError ?? ""))")
    check(benchSeeded, "demo delete: probe cached and searchable")
    await checkRemovalProbe(gateway, bench, word: "benchprobexq", fileGone: true, "demo delete removes the cache file and its search hits")

    if let tombstoned = manager.row(photo), manager.canRecover(tombstoned) {
        let result = await manager.recover(key: photo)
        check(result?.continuationStarted == true && result?.key != photo, "demo recover into a new chat")
        check(manager.row(photo)?.raw["archiveReason"] == "restart-recovery", "recovered source archived")
        if let key = result?.key {
            let listed = await waitFor("recovered chat listed", timeout: 5) { gateway.sessions[key] != nil }
            check(listed, "recovered chat appears in the sidebar")
            _ = await manager.delete([key])
        }
    } else {
        check(false, "demo tombstoned session is recoverable")
    }
}

/// Against the mock: a fresh store reads and writes without admin; `admin` has Full Management.
/// Uses the mock's session-manager seeds (mock-gateway/sessions.mjs); fresh mock per run. Stops the
/// seeded run at the end, so the restart check after it isn't deferred.
@MainActor
func runLiveSessions(profile: GatewayProfile, admin: GatewayStore) async {
    print("Session manager (live)")
    let garden = "agent:main:dashboard:garden", taxes = "agent:main:dashboard:tax-2025"
    let bench = "agent:research:dashboard:gpu-bench", refactor = "agent:coder:dashboard:refactor"
    let ciFix = "agent:coder:dashboard:ci-fix", photo = "agent:main:dashboard:photo-import"
    let writerProfile = GatewayProfile(name: "Sessions writer", url: profile.url, authMode: .token)
    writerProfile.secret = profile.secret
    let gateway = GatewayStore(profile: writerProfile)
    gateway.start()
    defer { gateway.stop() }
    let writerReady = await agentsReady(gateway, "sessions writer")
    let adminReady = await agentsReady(admin, "sessions admin")
    check(writerReady && adminReady, "both stores connected before session checks")
    guard gateway.advertises(SessionManager.previewMethod) else {
        // MOCK_NO_SESSION_MANAGER=1
        let manager = gateway.sessionManager
        check(gateway.supportsSessionManager && !manager.supportsPreview && !manager.supportsBranches && manager.supportsArchive,
              "older gateway: list and archive only")
        return
    }
    let writer = gateway.sessionManager
    let manager = admin.sessionManager
    check(!writer.hasAdmin && !writer.canRewind && !writer.canSwitchBranch, "writer has no branch tools")
    check(manager.hasAdmin && manager.canRewind && manager.canSwitchBranch, "admin has branch tools")

    await writer.load(filter: .active)
    let active = Set(writer.visibleRows().map(\.key))
    check(writer.loadError == nil && active.isSuperset(of: [garden, refactor, ciFix, photo]) && active.isDisjoint(with: [taxes, bench]),
          "live active list (\(active.count), \(writer.loadError ?? ""))")
    await writer.load(filter: .archived)
    check(Set(writer.visibleRows().map(\.key)) == [taxes, bench], "live archived: true lists archived only (\(writer.visibleRows().map(\.key)))")
    await writer.load(filter: .all)
    check(writer.visibleRows().count == active.count + 2, "live all list")
    if let running = writer.row(refactor), let failed = writer.row(ciFix) {
        let elapsed = SessionManager.runDuration(running, now: Date()) ?? -1
        check(SessionRunState(row: running) == .running && elapsed >= 300, "live running session with duration (\(elapsed))")
        check(SessionRunState(row: failed) == .failed && SessionManager.runDuration(failed, now: Date()) == 94
              && failed.raw["lastRunError"]?.string?.contains("timed out") == true, "live failed run and its error")
    } else {
        check(false, "live seeds running and failed sessions")
    }

    await writer.loadPreview(key: garden)
    let preview = writer.previews[garden]
    check(preview?.status == .ok && preview?.items.count == 4 && preview?.items.last?.text.hasPrefix("Swap the tomatoes") == true,
          "live preview (\(writer.previewErrors[garden] ?? ""))")
    await writer.loadDetails(key: garden)
    check(writer.details[garden]?.title == "Garden planner", "live details (\(writer.detailErrors[garden] ?? ""))")
    await writer.loadBranches(key: garden)
    let branches = writer.branches[garden] ?? []
    check(branches.count == 3 && branches.first?.active == true && branches.first?.headline.hasPrefix("Swap") == true,
          "live branches, active first (\(branches.map(\.headline)), \(writer.branchErrors[garden] ?? ""))")
    check(branches.dropFirst().first?.headline.hasPrefix("Basil") == true, "other tips newest first")

    // Writers can't switch or rewind: operator.admin.
    if let tip = branches.last {
        let refused = await writer.switchBranch(key: garden, leafEntryId: tip.leafEntryId)
        check(!refused && writer.actionError == SessionManager.needsAdminMessage, "writer switch → needs admin (\(writer.actionError ?? ""))")
    }
    let blocked = await writer.delete([ciFix])
    check(blocked.failed.first?.message == SessionManager.mixedDeleteMessage, "writer can't delete a live session")

    // Admin: switch, then rewind.
    await manager.load(filter: .all)
    if let herbs = branches.first(where: { $0.headline.hasPrefix("Basil") }) {
        let ok = await manager.switchBranch(key: garden, leafEntryId: herbs.leafEntryId)
        check(ok && manager.branches[garden]?.first?.leafEntryId == herbs.leafEntryId, "live switch branch (\(manager.actionError ?? ""))")
        let again = await manager.switchBranch(key: garden, leafEntryId: herbs.leafEntryId)
        check(!again && manager.actionError?.hasPrefix("branch is already active") == true, "switching to the active branch is refused")
    } else {
        check(false, "live herbs branch")
    }
    await manager.loadRewindPoints(key: garden)
    let liveSeeded = await seedRemovalCache(admin, garden, word: "gardenprobexq")
    check(liveSeeded, "live rewind: probe cached and searchable")
    if let point = manager.rewindPoints[garden]?.first {
        check(point.text == "What about an herbs-only bed instead?", "rewind point is the latest user message (\(point.text))")
        let ok = await manager.rewind(key: garden, entryId: point.entryId)
        check(ok && manager.lastEditorText == point.text, "live rewind returns the cut message (\(manager.actionError ?? ""))")
        check(manager.branches[garden]?.first?.headline.hasPrefix("Tomatoes") == true, "active path cut before it")
        await checkRemovalProbe(admin, garden, word: "gardenprobexq", fileGone: false, "live rewind drops the cached transcript and its search hits")
    } else {
        check(false, "live rewind points (\(manager.rewindErrors[garden] ?? ""))")
    }
    let busy = await manager.rewind(key: refactor, entryId: "x")
    check(!busy && manager.actionError == "Rewind is unavailable while the agent is working.", "no rewind during a run (\(manager.actionError ?? ""))")

    // Bulk archive through patchMany at operator.write; the admin page hears sessions.changed.
    let archive = await writer.setArchived([ciFix, "agent:main:main"], archived: true)
    check(archive.succeeded == [ciFix] && archive.failed.first?.message == "Cannot archive an agent's main session.",
          "live bulk archive, main protected (\(archive.failed.map(\.message)))")
    let heard = await waitFor("admin hears archive", timeout: 5) { manager.row(ciFix)?.isArchived == true }
    check(heard, "other page updates from sessions.changed")
    let deleted = await writer.delete([ciFix])
    check(deleted.succeeded == [ciFix] && writer.row(ciFix) == nil, "writer deletes an archived session (\(writer.actionError ?? ""))")
    await writer.load(filter: .all)
    check(writer.row(ciFix) == nil, "deleted session gone after reload")

    // Recover the restart-tombstoned chat at operator.write.
    if let tombstoned = writer.row(photo), writer.canRecover(tombstoned) {
        let result = await writer.recover(key: photo)
        check(result != nil && result?.key != photo && result?.key.hasPrefix("agent:main:dashboard:") == true,
              "live recover (\(writer.actionError ?? ""))")
        check(writer.row(photo)?.raw["archiveReason"] == "restart-recovery", "recovered source archived as restart-recovery")
        if let key = result?.key {
            let listed = await waitFor("recovered session listed", timeout: 5) { gateway.sessions[key] != nil }
            check(listed, "recovered session appears in the sidebar")
            let successorSeeded = await seedRemovalCache(admin, key, word: "successorprobexq")
            let deletedSuccessor = await manager.delete([key])
            check(successorSeeded, "live delete: probe cached and searchable")
            await checkRemovalProbe(admin, key, word: "successorprobexq", fileGone: true, "live delete removes the cache file and its search hits")
            check(deletedSuccessor.succeeded == [key], "admin deletes a live session (\(manager.actionError ?? ""))")
        }
    } else {
        check(false, "live tombstoned session is recoverable")
    }
    check(writer.row(refactor).map { !writer.canRecover($0) } == true, "a live session isn't recoverable")

    // Unarchive restores what the checks archived except the deleted ones.
    let unarchive = await manager.setArchived([taxes], archived: false)
    check(unarchive.succeeded == [taxes], "admin unarchive (\(manager.actionError ?? ""))")
    _ = await manager.setArchived([taxes], archived: true)

    await admin.chat(for: refactor).abort()
    let stopped = await waitFor("seeded run stopped", timeout: 5) { admin.sessions[refactor]?.hasActiveRun == false }
    check(stopped, "chat.abort stops the seeded run")
}
