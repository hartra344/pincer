import Foundation
import Testing
@testable import PincerKit

/// Session manager (#38): upstream wire shapes (`sessions.preview/describe/branches.*/rewind/recover/
/// delete/patchMany`), filtering, delete scope planning, run durations, capability and scope gating,
/// and the demo Gateway end to end.
@Suite("Session manager")
struct SessionManagerTests {
    /// A finite Gateway duration can exceed the integer formatter's range. Exercise the wire
    /// row and real duration calculation before formatting, not an isolated replacement guard.
    @Test func hugeFiniteGatewayRunDurationFormatsWithoutTrapping() throws {
        let finished = Self.row("huge-duration", ["status": "done", "runtimeMs": .number(1e30)])
        let seconds = try #require(SessionManager.runDuration(finished, now: Date(timeIntervalSince1970: 0)))
        #expect(seconds > Double(Int.max) && seconds.isFinite)
        let expected = "\(Int.max / 3600) hr \((Int.max % 3600) / 60) min"
        let formatted = SessionManager.formatDuration(seconds)
        #expect(formatted == expected, "Oversized finite durations saturate at Int.max seconds using the existing hour/minute display")
    }

    @Test func durationFormatterHandlesIntegerBoundaryAndNonfiniteInputs() {
        let saturated = "\(Int.max / 3600) hr \((Int.max % 3600) / 60) min"
        #expect(SessionManager.formatDuration(Double(Int.max)) == saturated,
                "Double rounds Int.max above the convertible range on 64-bit platforms")
        let below = Double(Int.max).nextDown
        let whole = Int(below)
        #expect(SessionManager.formatDuration(below) == "\(whole / 3600) hr \((whole % 3600) / 60) min")
        #expect(SessionManager.formatDuration(.nan) == "0 sec")
        #expect(SessionManager.formatDuration(.infinity) == "0 sec")
        #expect(SessionManager.formatDuration(-.infinity) == "0 sec")
        #expect(SessionManager.formatDuration(Double(Int.min)) == "0 sec")
        #expect(SessionManager.formatDuration(59.99) == "59 sec")
        #expect(SessionManager.formatDuration(60) == "1 min")
        #expect(SessionManager.formatDuration(3601) == "1 hr")
    }

    @Test(arguments: [
        (SessionRunState.idle, "Idle"), (.queued, "Queued"), (.running, "Running"),
        (.done, "Done"), (.failed, "Error"), (.killed, "Stopped"), (.timeout, "Timed Out"),
    ])
    func runStateTitlesKeepEnglishFallback(state: SessionRunState, expected: String) {
        #expect(state.title == expected)
    }

    // MARK: Fixtures

    static func row(_ key: String, _ extra: [String: JSONValue] = [:]) -> SessionRow {
        var object: [String: JSONValue] = ["key": .string(key)]
        for (field, value) in extra { object[field] = value }
        return SessionRow(.object(object))!
    }

    static let alpha = row("agent:main:dashboard:alpha", ["label": "Alpha", "agentId": "main", "sessionId": "s-alpha",
                                                          "lastActivityAt": 3000])
    static let beta = row("agent:research:dashboard:beta", ["label": "Beta", "agentId": "research", "archived": true,
                                                             "archivedAt": 2000, "lastActivityAt": 2000])
    /// Archived by `archivedAt` alone (older gateways omit `archived`).
    static let gamma = row("agent:main:dashboard:gamma", ["label": "Gamma", "archivedAt": 1000, "lastActivityAt": 5000])

    @MainActor
    final class Recorder {
        var calls: [(method: String, params: JSONValue)] = []
        var handler: (String, JSONValue) throws -> JSONValue = { _, _ in [:] }
        func request(_ method: String, _ params: JSONValue) throws -> JSONValue {
            self.calls.append((method, params))
            return try self.handler(method, params)
        }
    }

    static let missingAdmin = GatewayError.rpc(code: "INVALID_REQUEST", message: "missing scope: operator.admin", details: nil)

    // MARK: Pure logic

    @Test func filterAndSearch() {
        let rows = [Self.beta, Self.alpha, Self.gamma]
        #expect(SessionManager.filtered(rows, filter: .active).map(\.key) == [Self.alpha.key])
        #expect(SessionManager.filtered(rows, filter: .archived).map(\.key) == [Self.gamma.key, Self.beta.key],
                "archivedAt alone counts as archived; newest activity first")
        #expect(SessionManager.filtered(rows, filter: .all).map(\.key) == [Self.gamma.key, Self.alpha.key, Self.beta.key])
        #expect(SessionManager.filtered(rows, filter: .all, search: "  beta ").map(\.key) == [Self.beta.key], "title, trimmed, any case")
        #expect(SessionManager.filtered(rows, filter: .all, search: "RESEARCH").map(\.key) == [Self.beta.key], "agent id / key")
        #expect(SessionManager.filtered(rows, filter: .active, search: "beta").isEmpty, "search stays inside the filter")
        #expect(SessionManagerFilter.active.listParam == false && SessionManagerFilter.archived.listParam == true
                && SessionManagerFilter.all.listParam == "all", "upstream archived param: false / true (archived only) / \"all\"")
    }

    @Test func deletePlanAndParams() {
        let reader = SessionManager.deletePlan([Self.alpha, Self.beta], hasAdmin: false)
        #expect(reader.deletable == [Self.beta.key] && reader.blocked == [Self.alpha.key])
        #expect(reader.needsAdmin && !reader.canDelete, "live sessions need operator.admin")
        let admin = SessionManager.deletePlan([Self.alpha, Self.beta], hasAdmin: true)
        #expect(admin.deletable == [Self.alpha.key, Self.beta.key] && admin.canDelete && !admin.needsAdmin)
        #expect(!SessionManager.deletePlan([], hasAdmin: true).canDelete)

        #expect(SessionManager.deleteParams(Self.alpha)
            == ["key": "agent:main:dashboard:alpha", "agentId": "main", "deleteTranscript": true, "expectedSessionId": "s-alpha"],
            "live rows omit archivedOnly (admin)")
        #expect(SessionManager.deleteParams(Self.beta)
            == ["key": "agent:research:dashboard:beta", "agentId": "research", "deleteTranscript": true, "archivedOnly": true],
            "archived rows send only fields sessions.delete accepts at operator.write")
        let allowed: Set<String> = ["key", "agentId", "deleteTranscript", "expectedSessionId", "archivedOnly"]
        #expect(Set(SessionManager.deleteParams(Self.beta).object.map { Array($0.keys) } ?? []).isSubset(of: allowed))
    }

    @Test func patchManyBatchesAndParams() {
        let rows = (0..<250).map { Self.row("agent:main:dashboard:\($0)") }
        #expect(SessionManager.patchManyBatches(rows).map(\.count) == [100, 100, 50])
        #expect(SessionManager.patchManyBatches([]).isEmpty)
        #expect(SessionManager.patchManyParams([Self.alpha], archived: true)
            == ["targets": [["key": "agent:main:dashboard:alpha", "agentId": "main", "expectedSessionId": "s-alpha"]],
                "patch": ["archived": true]])
        #expect(SessionManager.patchParams(Self.alpha, archived: false)
            == ["key": "agent:main:dashboard:alpha", "archived": false, "expectedSessionId": "s-alpha"])
    }

    @Test func runStateAndDuration() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let nowMs = now.timeIntervalSince1970 * 1000
        let running = Self.row("r", ["status": "running", "hasActiveRun": true, "startedAt": .number(nowMs - 360_000)])
        let queued = Self.row("q", ["status": "queued", "hasActiveRun": true])
        let stale = Self.row("s", ["status": "running", "startedAt": .number(nowMs - 1000)])
        let failed = Self.row("f", ["status": "failed", "startedAt": .number(nowMs - 200_000), "endedAt": .number(nowMs - 106_000),
                                    "runtimeMs": 94_000])
        let ended = Self.row("e", ["status": "done", "startedAt": 1000, "endedAt": 6000])
        #expect(SessionRunState(row: running) == .running && SessionRunState(row: running).isActive)
        #expect(SessionRunState(row: queued) == .queued)
        #expect(SessionRunState(row: stale) == .idle, "status running without an active run isn't running")
        #expect(SessionRunState(row: failed) == .failed && SessionRunState(row: failed).isError)
        #expect(SessionRunState(row: Self.row("k", ["status": "killed"])).title == "Stopped")
        #expect(SessionRunState(row: Self.row("x", ["status": "future-status"])) == .idle)

        #expect(SessionManager.runDuration(running, now: now) == 360, "running: now − startedAt")
        #expect(SessionManager.runDuration(failed, now: now) == 94, "finished: runtimeMs wins")
        #expect(SessionManager.runDuration(ended, now: now) == 5, "no runtimeMs: endedAt − startedAt")
        #expect(SessionManager.runDuration(Self.alpha, now: now) == nil)
        #expect(SessionManager.runDuration(stale, now: now) == nil, "a stale running status doesn't tick")

        #expect(SessionManager.formatDuration(4.9) == "4 sec")
        #expect(SessionManager.formatDuration(125) == "2 min 5 sec")
        #expect(SessionManager.formatDuration(120) == "2 min")
        #expect(SessionManager.formatDuration(3780) == "1 hr 3 min")
        #expect(SessionManager.formatDuration(3600) == "1 hr")
        #expect(SessionManager.formatDuration(-5) == "0 sec")
    }

    @Test func summariesAndRecoverability() {
        #expect(SessionManager.bulkSummary(verb: "Archived", SessionBulkOutcome(succeeded: ["a", "b", "c"])) == "Archived 3 sessions")
        #expect(SessionManager.bulkSummary(verb: "Deleted", SessionBulkOutcome(succeeded: ["a"], failed: [.init(key: "b", message: "x")]))
            == "Deleted 1 session; 1 failed")
        #expect(SessionManager.isRecoverable(Self.row("t", ["restartRecoveryStatus": "tombstoned"])))
        #expect(!SessionManager.isRecoverable(Self.row("t", ["restartRecoveryStatus": "recovered"])) && !SessionManager.isRecoverable(Self.alpha))
    }

    @Test func wireShapes() throws {
        let preview = try #require(SessionPreview(["key": "k", "status": "ok",
                                                   "items": [["role": "user", "text": "hi"], ["role": "assistant", "text": "hello"]]]))
        #expect(preview.items.map(\.role) == ["user", "assistant"] && preview.items.map(\.text) == ["hi", "hello"] && preview.emptyReason == nil)
        #expect(SessionPreview(["key": "k", "status": "cold", "items": []])?.emptyReason == "The transcript isn't loaded on the Gateway yet")
        #expect(SessionPreview(["key": "k", "status": "missing", "items": []])?.emptyReason == "This session is gone")
        #expect(SessionPreview(["key": "k", "status": "later"])?.status == .unknown)
        #expect(SessionPreview(["status": "ok"]) == nil)

        let branch = try #require(SessionBranch(["leafEntryId": "abcdef123456", "headline": "", "messageCount": 4,
                                                 "updatedAt": "2026-01-02T03:04:05.000Z", "active": true]))
        #expect(branch.title == "Branch abcdef12" && branch.active && branch.messageCount == 4)
        #expect(branch.updatedAt == ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z"))
        #expect(SessionBranch(["leafEntryId": "x", "headline": "Line one\nLine two"])?.title == "Line one")
        #expect(SessionBranch(["leafEntryId": "x"])?.active == false && SessionBranch(["headline": "no id"]) == nil)

        let started = try #require(SessionRecoverResult(["ok": true, "key": "agent:main:dashboard:new", "sessionId": "s2",
                                                         "continuation": ["status": "started", "runId": "r1"]]))
        #expect(started.continuationStarted && started.continuationError == nil && started.key == "agent:main:dashboard:new")
        let rejected = try #require(SessionRecoverResult(["ok": true, "key": "n", "sessionId": "s",
                                                          "continuation": ["status": "rejected", "error": ["message": "boom"]]]))
        #expect(!rejected.continuationStarted && rejected.continuationError == "boom")
        #expect(SessionRecoverResult(["ok": true]) == nil)
    }

    // MARK: Model against a fake Gateway

    @MainActor @Test func capabilityGating() async {
        let recorder = Recorder()
        let all = Set([SessionManager.listMethod] + DemoGateway.sessionManagerMethods + [SessionManager.patchMethod])
        let admin = SessionManagerModel(methods: { all }, request: { try recorder.request($0, $1) })
        #expect(admin.supportsPreview && admin.supportsDescribe && admin.supportsBranches && admin.supportsRecover)
        #expect(admin.hasAdmin && admin.canSwitchBranch && admin.canRewind && admin.supportsArchive && admin.supportsDelete)

        let writer = SessionManagerModel(methods: { all }, scopes: { ["operator.read", "operator.write"] },
                                         request: { try recorder.request($0, $1) })
        #expect(!writer.hasAdmin && !writer.canSwitchBranch && !writer.canRewind, "branch tools need operator.admin")
        #expect(writer.canRecover(Self.row("t", ["restartRecoveryStatus": "tombstoned"])) && !writer.canRecover(Self.alpha),
                "recover is write-scoped, for tombstoned sessions only")

        let old = SessionManagerModel(methods: { [SessionManager.listMethod, SessionManager.patchMethod] },
                                      request: { try recorder.request($0, $1) })
        #expect(!old.supportsPreview && !old.supportsBranches && !old.canRewind && !old.supportsRecover && !old.supportsPatchMany)
        #expect(old.supportsArchive, "sessions.patch still archives")
        await old.loadPreview(key: "k")
        await old.loadBranches(key: "k")
        await old.loadDetails(key: "k")
        #expect(recorder.calls.isEmpty, "unadvertised methods are never called")

        let demo = SessionManagerModel(scopes: { [] }, allowsWritesWithoutAdmin: true, request: { try recorder.request($0, $1) })
        #expect(demo.hasAdmin && demo.canRewind && demo.supportsPreview, "the demo manages without admin; unknown method list")
    }

    @MainActor @Test func loadSendsTheArchivedFilter() async {
        let recorder = Recorder()
        recorder.handler = { _, _ in ["sessions": [Self.alpha.raw, Self.beta.raw, Self.gamma.raw]] }
        let model = SessionManagerModel(request: { try recorder.request($0, $1) })
        await model.load(filter: .archived)
        #expect(recorder.calls.last?.method == "sessions.list")
        #expect(recorder.calls.last?.params == ["limit": 500, "includeLastMessage": true, "archived": true])
        #expect(model.hasLoaded && model.filter == .archived && model.visibleRows().map(\.key) == [Self.gamma.key, Self.beta.key])
        await model.load(filter: .all)
        #expect(recorder.calls.last?.params["archived"] == "all")
        await model.loadIfNeeded(filter: .all)
        #expect(recorder.calls.count == 2, "loadIfNeeded skips a loaded filter")
        await model.load(filter: .active)
        #expect(recorder.calls.last?.params["archived"] == false && model.visibleRows().map(\.key) == [Self.alpha.key])

        recorder.handler = { _, _ in throw GatewayError.rpc(code: "UNAVAILABLE", message: "gateway busy", details: nil) }
        await model.reload()
        #expect(model.loadError == "gateway busy" && !model.isLoading)
    }

    @MainActor @Test func previewDetailsBranchesRequests() async {
        let recorder = Recorder()
        recorder.handler = { method, params in
            switch method {
            case "sessions.list": return ["sessions": [Self.alpha.raw]]
            case "sessions.preview": return ["ts": 1, "previews": [["key": params["keys"]?.array?.first ?? "", "status": "ok",
                                                                   "items": [["role": "user", "text": "hi"]]]]]
            case "sessions.describe": return ["session": Self.alpha.raw]
            case "sessions.branches.list": return ["branches": [["leafEntryId": "l1", "headline": "Tip", "messageCount": 2, "active": true]]]
            case "chat.history":
                return ["messages": [
                    ["role": "user", "content": [["type": "text", "text": "first"]], "__openclaw": ["id": "u1"], "timestamp": 1000],
                    ["role": "assistant", "content": [["type": "text", "text": "ok"]], "__openclaw": ["id": "a1"], "timestamp": 2000],
                    ["role": "user", "content": [["type": "text", "text": "second"]], "__openclaw": ["id": "u2"], "timestamp": 3000],
                ]]
            default: return [:]
            }
        }
        let model = SessionManagerModel(request: { try recorder.request($0, $1) })
        await model.load(filter: .active)
        await model.loadPreview(key: Self.alpha.key)
        #expect(recorder.calls.last?.params == ["keys": [.string(Self.alpha.key)], "limit": 8, "maxChars": 240])
        #expect(model.previews[Self.alpha.key]?.items.map(\.text) == ["hi"])
        await model.loadPreview(key: Self.alpha.key)
        #expect(recorder.calls.filter { $0.method == "sessions.preview" }.count == 1, "previews are cached")

        await model.loadDetails(key: Self.alpha.key)
        #expect(recorder.calls.last?.params == ["key": .string(Self.alpha.key), "agentId": "main", "includeDerivedTitles": true,
                                                "includeLastMessage": true])
        #expect(model.details[Self.alpha.key]?.key == Self.alpha.key)
        await model.loadBranches(key: Self.alpha.key)
        #expect(recorder.calls.last?.params == ["sessionKey": .string(Self.alpha.key), "agentId": "main"],
                "branches.list takes sessionKey, not key")
        #expect(model.branches[Self.alpha.key]?.map(\.leafEntryId) == ["l1"])
        await model.loadRewindPoints(key: Self.alpha.key)
        #expect(model.rewindPoints[Self.alpha.key]?.map(\.entryId) == ["u2", "u1"], "user messages only, newest first")
        #expect(model.rewindPoints[Self.alpha.key]?.first?.text == "second")

        recorder.handler = { _, _ in ["session": .null] }
        await model.loadDetails(key: "gone")
        #expect(model.details["gone"] == nil && model.detailErrors["gone"] == "This session is gone.")
    }

    @MainActor @Test func archiveWithPatchManyAndFallback() async {
        let recorder = Recorder()
        recorder.handler = { method, _ in
            switch method {
            case "sessions.list": return ["sessions": [Self.alpha.raw, Self.beta.raw, Self.gamma.raw]]
            case "sessions.patchMany":
                return ["outcomes": [["ok": true, "key": .string(Self.alpha.key), "agentId": "main"],
                                     ["ok": false, "key": .string(Self.gamma.key), "error": ["code": "INVALID_REQUEST", "message": "nope"]]]]
            default: return ["ok": true]
            }
        }
        var refreshed = 0
        let model = SessionManagerModel(request: { try recorder.request($0, $1) }, onSessionsChanged: { refreshed += 1 })
        await model.load(filter: .all)
        let outcome = await model.setArchived([Self.alpha.key, Self.gamma.key, "agent:main:dashboard:unlisted"], archived: true)
        #expect(outcome.succeeded == [Self.alpha.key])
        #expect(outcome.failed.map(\.key) == [Self.gamma.key] && outcome.failed.first?.message == "nope")
        let patchMany = recorder.calls.filter { $0.method == "sessions.patchMany" }
        #expect(patchMany.count == 1 && patchMany[0].params["targets"]?.array?.count == 2, "unknown keys aren't sent")
        #expect(patchMany[0].params["patch"] == ["archived": true])
        #expect(model.lastMessage == "Archived 1 session; 1 failed" && model.actionError == "1 session failed: nope")
        #expect(model.row(Self.alpha.key)?.isArchived == true && refreshed == 1)
        #expect(model.busy.isEmpty && !model.isWorking)

        // An older gateway without patchMany: one sessions.patch each.
        recorder.calls = []
        recorder.handler = { method, _ in
            if method == "sessions.patchMany" { throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: sessions.patchMany", details: nil) }
            return ["ok": true]
        }
        let fallback = await model.setArchived([Self.alpha.key, Self.beta.key], archived: false)
        #expect(Set(fallback.succeeded) == [Self.alpha.key, Self.beta.key] && fallback.failed.isEmpty)
        #expect(recorder.calls.map(\.method) == ["sessions.patchMany", "sessions.patch", "sessions.patch"])
        #expect(recorder.calls[1].params["archived"] == false && !model.supportsPatchMany)
        #expect(model.lastMessage == "Unarchived 2 sessions" && model.actionError == nil)
    }

    @MainActor @Test func bulkFailurePresentationUsesKnownSessionTitle() async throws {
        let recorder = Recorder()
        recorder.handler = { method, _ in
            switch method {
            case "sessions.list": return ["sessions": [Self.alpha.raw]]
            case "sessions.patchMany":
                return ["outcomes": [["key": .string(Self.alpha.key), "ok": false,
                                       "error": ["message": "Gateway refused the update."]]]]
            default: return [:]
            }
        }
        let model = SessionManagerModel(request: { try recorder.request($0, $1) })
        await model.load(filter: .all)
        let outcome = await model.setArchived([Self.alpha.key], archived: true)
        let failure = try #require(model.lastFailures.first)
        #expect(outcome.failed == [failure] && failure.key == Self.alpha.key)
        #expect(model.lastFailureTitles[failure.key] == "Alpha")
        #expect(SessionManager.bulkFailureSummary(failure, sessionTitle: model.lastFailureTitles[failure.key])
                == "Alpha: Gateway refused the update.",
                "the UI's O(1) bulk title snapshot supplies the listed session title")

        let unknown = SessionBulkOutcome.Failure(key: "agent:main:dashboard:removed", message: "gone")
        #expect(SessionManager.bulkFailureSummary(unknown, sessionTitle: nil) == "\(unknown.key): gone",
                "unknown and deleted sessions fall back to the key")
        #expect(SessionManager.bulkFailureSummary(unknown, sessionTitle: " \n ") == "\(unknown.key): gone",
                "an empty title falls back to the key")
    }

    @MainActor @Test func failedDeleteTitleSurvivesRowRefreshAndClearMessages() async throws {
        let recorder = Recorder()
        var omitRowFromNextList = false
        recorder.handler = { method, _ in
            switch method {
            case "sessions.list": return ["sessions": omitRowFromNextList ? [] : [Self.alpha.raw]]
            case "sessions.delete": return ["deleted": false]
            default: return [:]
            }
        }
        let model = SessionManagerModel(request: { try recorder.request($0, $1) })
        await model.load(filter: .all)
        let outcome = await model.delete([Self.alpha.key])
        let failure = try #require(model.lastFailures.first)
        #expect(outcome.failed == [failure] && model.lastFailureTitles[failure.key] == "Alpha")
        #expect(SessionManager.bulkFailureSummary(failure, sessionTitle: model.lastFailureTitles[failure.key])
                == "Alpha: The Gateway didn't delete this session.")

        omitRowFromNextList = true
        await model.reload()
        #expect(model.row(Self.alpha.key) == nil, "the next session-list snapshot removes the failed row")
        #expect(model.lastFailureTitles[failure.key] == "Alpha"
                && SessionManager.bulkFailureSummary(failure, sessionTitle: model.lastFailureTitles[failure.key])
                    == "Alpha: The Gateway didn't delete this session.",
                "the failure still has its captured title after its row disappears")

        model.clearMessages()
        #expect(model.lastFailures.isEmpty && model.lastFailureTitles.isEmpty,
                "clearing the result removes both failures and captured titles")
    }

    @MainActor @Test func deleteScopes() async {
        let recorder = Recorder()
        recorder.handler = { method, params in
            method == "sessions.list" ? ["sessions": [Self.alpha.raw, Self.beta.raw]]
                : ["ok": true, "key": params["key"] ?? "", "deleted": true, "archived": []]
        }
        var changes: [(String, SessionTranscriptChange)] = []
        let writer = SessionManagerModel(scopes: { ["operator.read", "operator.write"] }, request: { try recorder.request($0, $1) },
                                         onTranscriptChanged: { changes.append(($0, $1)) })
        await writer.load(filter: .all)
        #expect(writer.deletePlan([Self.alpha.key, Self.beta.key]).blocked == [Self.alpha.key])
        let outcome = await writer.delete([Self.alpha.key, Self.beta.key])
        #expect(outcome.succeeded == [Self.beta.key] && outcome.failed == [.init(key: Self.alpha.key, message: SessionManager.mixedDeleteMessage)])
        let deletes = recorder.calls.filter { $0.method == "sessions.delete" }
        #expect(deletes.count == 1 && deletes[0].params["archivedOnly"] == true, "live rows aren't sent without admin")
        #expect(changes.count == 1 && changes[0].0 == Self.beta.key && changes[0].1 == .deleted)
        #expect(writer.row(Self.beta.key) == nil && writer.row(Self.alpha.key) != nil)

        recorder.handler = { method, _ in
            method == "sessions.list" ? ["sessions": [Self.alpha.raw]] : ["ok": true, "key": "x", "deleted": false, "archived": []]
        }
        let admin = SessionManagerModel(request: { try recorder.request($0, $1) })
        await admin.load(filter: .active)
        let missing = await admin.delete([Self.alpha.key])
        #expect(missing.failed.first?.message == "The Gateway didn't delete this session.", "deleted: false isn't a success")
        #expect(recorder.calls.last?.params["archivedOnly"] == nil, "admin deletes live rows without archivedOnly")
    }

    @MainActor @Test func branchSwitchRewindAndScopeErrors() async {
        let recorder = Recorder()
        recorder.handler = { method, _ in
            switch method {
            case "sessions.rewind": return ["editorText": "What about an herbs-only bed instead?"]
            case "sessions.branches.list": return ["branches": []]
            case "chat.history": return ["messages": []]
            case "sessions.describe": return ["session": .null]
            default: return [:]
            }
        }
        var changes: [(String, SessionTranscriptChange)] = []
        let model = SessionManagerModel(request: { try recorder.request($0, $1) }, onTranscriptChanged: { changes.append(($0, $1)) })
        #expect(await model.rewind(key: "agent:main:dashboard:garden", entryId: "u2"))
        #expect(recorder.calls.first?.method == "sessions.rewind"
                && recorder.calls.first?.params == ["sessionKey": "agent:main:dashboard:garden", "entryId": "u2"])
        #expect(model.lastEditorText == "What about an herbs-only bed instead?" && model.lastMessage == "Rewound the session")
        #expect(changes.first?.1 == .changed(editorText: "What about an herbs-only bed instead?"))
        #expect(Set(recorder.calls.dropFirst().map(\.method)) == ["sessions.branches.list", "chat.history", "sessions.describe"],
                "branches, rewind points and details reload")

        recorder.calls = []
        #expect(await model.switchBranch(key: "agent:main:dashboard:garden", leafEntryId: "tip"))
        #expect(recorder.calls.first?.params == ["sessionKey": "agent:main:dashboard:garden", "leafEntryId": "tip"])
        #expect(model.lastEditorText == nil && changes.last?.1 == .changed(editorText: nil))

        recorder.handler = { _, _ in throw Self.missingAdmin }
        #expect(!(await model.switchBranch(key: "k", leafEntryId: "tip")))
        #expect(model.deniedAdmin && !model.hasAdmin && !model.canRewind && model.actionError == SessionManager.needsAdminMessage)
        model.handleReconnect()
        #expect(!model.deniedAdmin && model.hasAdmin, "a reconnect retries admin")

        recorder.handler = { method, _ in
            throw GatewayError.rpc(code: "UNAVAILABLE", message: "Rewind is unavailable while the agent is working.", details: nil)
        }
        #expect(!(await model.rewind(key: "k", entryId: "u")))
        #expect(model.actionError == "Rewind is unavailable while the agent is working.")
    }

    @MainActor @Test func recoverAndUnknownMethod() async {
        let recorder = Recorder()
        recorder.handler = { method, _ in
            switch method {
            case "sessions.recover":
                return ["ok": true, "key": "agent:main:dashboard:new", "sessionId": "s2",
                        "continuation": ["status": "rejected", "error": ["code": "UNAVAILABLE", "message": "boom"]]]
            case "sessions.list": return ["sessions": []]
            default: return [:]
            }
        }
        var changes: [String] = []
        let model = SessionManagerModel(request: { try recorder.request($0, $1) }, onTranscriptChanged: { key, _ in changes.append(key) })
        let result = await model.recover(key: "agent:main:dashboard:photo-import")
        #expect(result?.key == "agent:main:dashboard:new" && result?.continuationStarted == false)
        #expect(recorder.calls.first?.params == ["key": "agent:main:dashboard:photo-import"], "recover takes key, not sessionKey")
        #expect(model.lastMessage == "Recovered the session" && model.actionError == "boom" && changes == ["agent:main:dashboard:photo-import"])
        #expect(recorder.calls.last?.method == "sessions.list", "the list reloads after a recovery")

        recorder.handler = { method, _ in throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: \(method)", details: nil) }
        #expect(await model.recover(key: "x") == nil)
        #expect(!model.supportsRecover && model.actionError == SessionManager.unsupportedMessage)
    }

    // MARK: Demo Gateway end to end

    @MainActor
    static func demoModel() -> (SessionManagerModel, DemoGateway) {
        let demo = DemoGateway()
        let model = SessionManagerModel(scopes: { [] }, allowsWritesWithoutAdmin: true,
                                        request: { method, params in try await demo.handle(method, params) })
        return (model, demo)
    }

    typealias Seed = DemoGateway.SessionManagerSeed

    @MainActor @Test func demoListsAndPreviews() async throws {
        let (model, _) = Self.demoModel()
        await model.load(filter: .active)
        let active = Set(model.visibleRows().map(\.key))
        #expect(active.isSuperset(of: [Seed.garden, Seed.refactor, Seed.ciFix, Seed.photoImport]))
        #expect(active.isDisjoint(with: [Seed.taxes, Seed.benchmarks]), "archived chats are hidden by default")
        await model.load(filter: .archived)
        #expect(Set(model.visibleRows().map(\.key)) == [Seed.taxes, Seed.benchmarks], "archived: true lists archived only")
        #expect(model.row(Seed.benchmarks)?.raw["archiveReason"] == "stale-dashboard")
        await model.load(filter: .all)
        #expect(Set(model.visibleRows().map(\.key)).isSuperset(of: active.union([Seed.taxes, Seed.benchmarks])))

        let refactor = try #require(model.row(Seed.refactor))
        #expect(SessionRunState(row: refactor) == .running)
        let elapsed = try #require(SessionManager.runDuration(refactor, now: Date()))
        #expect(elapsed >= 5 * 60 && elapsed < 60 * 60, "seeded run started minutes ago (\(elapsed))")
        let ci = try #require(model.row(Seed.ciFix))
        #expect(SessionRunState(row: ci) == .failed && SessionManager.runDuration(ci, now: Date()) == 94)
        #expect(model.canRecover(try #require(model.row(Seed.photoImport))) && !model.canRecover(refactor))

        await model.loadPreview(key: Seed.garden)
        let preview = try #require(model.previews[Seed.garden])
        #expect(preview.status == .ok && preview.items.count == 4 && preview.items.last?.role == "assistant")
        #expect(preview.items.last?.text.hasPrefix("Swap the tomatoes") == true)
        await model.loadDetails(key: Seed.garden)
        #expect(model.details[Seed.garden]?.title == "Garden planner")
        await model.loadDetails(key: "agent:main:dashboard:nope")
        #expect(model.detailErrors["agent:main:dashboard:nope"] == "This session is gone.")
    }

    @MainActor @Test func demoPreviewShape() async throws {
        let demo = DemoGateway()
        let result = try await demo.handle("sessions.preview", ["keys": [.string(Seed.garden), "agent:main:dashboard:nope"],
                                                                 "limit": 2, "maxChars": 20])
        let previews = try #require(result["previews"]?.array)
        #expect(previews.count == 2 && previews[1]["status"] == "missing" && previews[1]["items"] == [])
        let items = try #require(previews[0]["items"]?.array)
        #expect(items.count == 2 && items.allSatisfy { ($0["text"]?.string?.count ?? 99) <= 20 })
        #expect(items.last?["text"]?.string?.hasSuffix("...") == true, "cut like upstream: slice(0, max-3) + \"...\"")
        await #expect(throws: GatewayError.self) { _ = try await demo.handle("sessions.preview", ["keys": []]) }
    }

    @MainActor @Test func demoBranchesSwitchAndRewind() async throws {
        let (model, _) = Self.demoModel()
        await model.load(filter: .active)
        await model.loadBranches(key: Seed.garden)
        let branches = try #require(model.branches[Seed.garden])
        #expect(branches.count == 3 && branches.first?.active == true && branches.dropFirst().allSatisfy { !$0.active })
        #expect(branches.first?.headline.hasPrefix("Swap the tomatoes") == true && branches.allSatisfy { $0.messageCount == 4 })
        #expect(branches.allSatisfy { $0.updatedAt != nil })

        let herbs = try #require(branches.first { $0.headline.hasPrefix("Basil") })
        #expect(await model.switchBranch(key: Seed.garden, leafEntryId: herbs.leafEntryId))
        #expect(model.branches[Seed.garden]?.first?.leafEntryId == herbs.leafEntryId && model.branches[Seed.garden]?.count == 3)
        #expect(!(await model.switchBranch(key: Seed.garden, leafEntryId: herbs.leafEntryId)))
        #expect(model.actionError == "branch is already active: \(herbs.leafEntryId)")

        await model.loadRewindPoints(key: Seed.garden)
        let point = try #require(model.rewindPoints[Seed.garden]?.first)
        #expect(point.text == "What about an herbs-only bed instead?")
        #expect(await model.rewind(key: Seed.garden, entryId: point.entryId))
        #expect(model.lastEditorText == "What about an herbs-only bed instead?")
        #expect(model.branches[Seed.garden]?.first?.headline.hasPrefix("Tomatoes along") == true, "active path cut before the message")
        #expect(model.rewindPoints[Seed.garden]?.map(\.text) == ["Plan a spring vegetable bed for a 4×8 ft raised bed."])

        let assistant = "demo-garden-a1"
        #expect(!(await model.rewind(key: Seed.garden, entryId: assistant)))
        #expect(model.actionError == "entry is not a user message: \(assistant)")
        #expect(!(await model.rewind(key: Seed.refactor, entryId: "x")))
        #expect(model.actionError == "Rewind is unavailable while the agent is working.")
        #expect(!(await model.switchBranch(key: Seed.refactor, leafEntryId: "x")))
        #expect(model.actionError == "Branch switch is unavailable while the agent is working.")
    }

    @MainActor @Test func demoSeededRunFinishesOnItsOwn() async throws {
        let demo = DemoGateway()
        let before = try #require(try await Self.demoRow(demo, Seed.refactor))
        #expect(before["hasActiveRun"] == true)
        await demo.finishSeededRun()
        let after = try #require(try await Self.demoRow(demo, Seed.refactor))
        #expect(after["hasActiveRun"] == false && after["status"] == "done")
        #expect(after["endedAt"]?.double != nil && after["runtimeMs"]?.double != nil)
        await demo.finishSeededRun()
        #expect(try await Self.demoRow(demo, Seed.refactor)?["status"] == "done", "finishing twice is a no-op")
    }

    /// The demo's row for `key` (`sessions.describe`), nil once deleted.
    static func demoRow(_ demo: DemoGateway, _ key: String) async throws -> JSONValue? {
        let session = try await demo.handle("sessions.describe", ["key": .string(key)])["session"]
        return session == .null ? nil : session
    }

    static func demoMessages(_ demo: DemoGateway, _ key: String) async throws -> Int {
        try await demo.handle("chat.history", ["sessionKey": .string(key), "limit": 50])["messages"]?.array?.count ?? 0
    }

    @MainActor @Test func demoArchiveDeleteRecover() async throws {
        let (model, demo) = Self.demoModel()
        await model.load(filter: .all)
        let archived = await model.setArchived([Seed.ciFix, "agent:main:main"], archived: true)
        #expect(archived.succeeded == [Seed.ciFix])
        #expect(archived.failed.first?.message == "Cannot archive an agent's main session.")
        let ci = try await Self.demoRow(demo, Seed.ciFix)
        #expect(ci?["archivedAt"]?.double != nil && ci?["archiveReason"] == "manual")
        let unarchived = await model.setArchived([Seed.ciFix], archived: false)
        let restored = try await Self.demoRow(demo, Seed.ciFix)
        #expect(unarchived.succeeded == [Seed.ciFix] && restored?["archivedAt"] == nil && restored?["archived"] == false)

        let stopped = await model.setArchived([Seed.refactor], archived: true)
        let refactor = try await Self.demoRow(demo, Seed.refactor)
        #expect(stopped.succeeded == [Seed.refactor] && refactor?["hasActiveRun"] == false, "archiving stops the run")

        await model.load(filter: .all)
        let deleted = await model.delete([Seed.taxes])
        #expect(deleted.succeeded == [Seed.taxes])
        #expect(try await Self.demoRow(demo, Seed.taxes) == nil)
        await #expect(throws: GatewayError.self) {
            _ = try await demo.handle("sessions.delete", ["key": .string(Seed.ciFix), "archivedOnly": true])
        }
        await #expect(throws: GatewayError.self) { _ = try await demo.handle("sessions.delete", ["key": "agent:main:main"]) }
        let gone = try await demo.handle("sessions.delete", ["key": "agent:main:dashboard:nope"])
        #expect(gone["deleted"] == false && gone["ok"] == true)

        let result = try #require(await model.recover(key: Seed.photoImport))
        #expect(result.key.hasPrefix("agent:main:dashboard:") && result.key != Seed.photoImport && result.continuationStarted)
        #expect(try await Self.demoRow(demo, Seed.photoImport)?["archiveReason"] == "restart-recovery")
        #expect(try await Self.demoRow(demo, result.key) != nil)
        #expect(try await Self.demoMessages(demo, result.key) > 0, "the successor carries the transcript")
        let again = try await demo.handle("sessions.recover", ["key": .string(Seed.photoImport)])
        #expect(again["key"]?.string == result.key, "recovering twice returns the same successor")
        await #expect(throws: GatewayError.self) { _ = try await demo.handle("sessions.recover", ["key": .string(Seed.garden)]) }
    }
}
