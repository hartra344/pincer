import Foundation
import Testing
@testable import PincerKit

/// #981: Stop aborts the whole session with `sessions.abort`.
@MainActor
@Suite("Session abort (sessions.abort)", .serialized)
struct SessionAbortTests {
    static let key = "agent:main:dashboard:abort"
    static let abortResult: JSONValue = ["ok": true, "abortedRunId": "run-1", "status": "aborted"]

    @MainActor struct Harness {
        let fake: FakeAbortGateway
        let scratch = ScratchDefaults()
        let store: GatewayStore

        @MainActor init(methods: [String] = ["sessions.abort", "chat.abort"], scope: String = "per-sender", connect: Bool = true) async throws {
            self.fake = try FakeAbortGateway(methods: methods)
            self.fake.agentScope = scope
            self.fake.reply(to: "sessions.abort", .result(SessionAbortTests.abortResult))
            let profile = GatewayProfile(name: "Abort", url: self.fake.url, authMode: .none)
            self.store = GatewayStore(profile: profile, defaults: self.scratch.defaults, identity: Fixtures.identity())
            guard connect else { return }
            self.store.start()
            let ready = await eventually(timeout: .seconds(30)) { self.store.state.isConnected && self.store.hello != nil && self.store.agentScopeIsGlobal == (scope == "global") }
            try #require(ready, "the store connects (state: \(self.store.state))")
        }

        func finish() {
            self.store.stop()
            self.fake.stop()
            self.scratch.remove()
        }
    }

    // MARK: isGlobal

    @Test func isGlobalTruthTable() {
        let cases: [(String, Bool, Bool)] = [
            ("global", false, true), ("GLOBAL", false, true), ("Global", true, true),
            ("main", false, false), ("main", true, true), ("MAIN", true, true),
            ("agent:main:main", false, false), ("agent:main:main", true, true), ("agent:research:main", true, true),
            ("agent:main:dashboard:x", false, false), ("agent:main:dashboard:x", true, false),
            ("agent:main:subagent:abc", true, false), ("agent:main:telegram:main-street", true, false),
            ("", true, false),
        ]
        for (key, scopeIsGlobal, expected) in cases {
            #expect(SessionKey.isGlobal(key, scopeIsGlobal: scopeIsGlobal) == expected, "\(key) scopeIsGlobal=\(scopeIsGlobal)")
        }
    }

    // MARK: Stop button

    @Test func stopWithLiveRunIdSendsChatAbortWithRunId() async throws {
        let h = try await Harness()
        defer { h.finish() }
        let chat = h.store.chat(for: Self.key)
        chat.live = LiveRun(runId: "run-live")
        await chat.abort()
        let sent = h.fake.requests("chat.abort")
        #expect(sent.count == 1)
        #expect(sent.first?["sessionKey"]?.string == Self.key)
        #expect(sent.first?["runId"]?.string == "run-live")
        #expect(h.fake.requests("sessions.abort").isEmpty)
    }

    @Test func stopWithoutRunIdSendsSessionsAbortWithClearQueued() async throws {
        let h = try await Harness()
        defer { h.finish() }
        let chat = h.store.chat(for: Self.key)
        #expect(chat.live == nil)
        await chat.abort()
        let sent = h.fake.requests("sessions.abort")
        #expect(sent.count == 1)
        #expect(sent.first?["key"]?.string == Self.key)
        #expect(sent.first?["clearQueued"]?.bool == true)
        #expect(sent.first?["runId"] == nil)
        #expect(h.fake.requests("chat.abort").isEmpty)
    }

    @Test func abortSessionIgnoresALiveRunId() async throws {
        let h = try await Harness()
        defer { h.finish() }
        let chat = h.store.chat(for: Self.key)
        chat.live = LiveRun(runId: "run-live")
        #expect(await chat.abortSession())
        #expect(h.fake.requests("sessions.abort").count == 1)
        #expect(h.fake.requests("sessions.abort").first?["runId"] == nil)
        #expect(h.fake.requests("chat.abort").isEmpty)
    }

    @Test func globalSessionOmitsClearQueued() async throws {
        let h = try await Harness()
        defer { h.finish() }
        #expect(await h.store.chat(for: "global").abortSession())
        let sent = h.fake.requests("sessions.abort")
        #expect(sent.first?["key"]?.string == "global")
        #expect(sent.first?["clearQueued"] == nil)
    }

    @Test func mainAliasIsGlobalOnlyWithGlobalScope() async throws {
        let global = try await Harness(scope: "global")
        defer { global.finish() }
        #expect(await global.store.chat(for: "agent:main:main").abortSession())
        #expect(global.fake.requests("sessions.abort").first?["clearQueued"] == nil)

        let perSender = try await Harness()
        defer { perSender.finish() }
        #expect(await perSender.store.chat(for: "agent:main:main").abortSession())
        #expect(perSender.fake.requests("sessions.abort").first?["clearQueued"]?.bool == true)
    }

    // MARK: Fallback

    @Test func fallsBackToChatAbortWhenNotAdvertised() async throws {
        let h = try await Harness(methods: ["chat.abort", "chat.send"])
        defer { h.finish() }
        let chat = h.store.chat(for: Self.key)
        #expect(await chat.abortSession())
        #expect(h.fake.requests("sessions.abort").isEmpty)
        let sent = h.fake.requests("chat.abort")
        #expect(sent.count == 1)
        #expect(sent.first?["sessionKey"]?.string == Self.key)
        #expect(sent.first?["runId"] == nil)
    }

    @Test func fallsBackToChatAbortOnUnknownMethod() async throws {
        let h = try await Harness()
        defer { h.finish() }
        h.fake.reply(to: "sessions.abort", .error(code: "INVALID_REQUEST", message: "unknown method: sessions.abort"))
        let chat = h.store.chat(for: Self.key)
        #expect(await chat.abortSession())
        #expect(h.fake.requests("sessions.abort").count == 1)
        #expect(h.fake.requests("chat.abort").count == 1)
        #expect(chat.errorMessage == nil)
    }

    @Test func emptyMethodsListTriesSessionsAbort() async throws {
        let h = try await Harness(methods: [])
        defer { h.finish() }
        #expect(await h.store.chat(for: Self.key).abortSession())
        #expect(h.fake.requests("sessions.abort").count == 1)
        #expect(h.fake.requests("chat.abort").isEmpty)
    }

    @Test func emptyMethodsListFallsBackOnUnknownMethod() async throws {
        let h = try await Harness(methods: [])
        defer { h.finish() }
        h.fake.reply(to: "sessions.abort", .error(code: "INVALID_REQUEST", message: "unknown method: sessions.abort"))
        let chat = h.store.chat(for: Self.key)
        #expect(await chat.abortSession())
        #expect(h.fake.requests("chat.abort").count == 1)
        #expect(chat.errorMessage == nil)
    }

    @Test func warningSurfacesButStillSucceeds() async throws {
        let h = try await Harness()
        defer { h.finish() }
        h.fake.reply(to: "sessions.abort", .result(["ok": true, "abortedRunId": "run-1", "status": "aborted", "warning": "1 child could not be stopped"]))
        let chat = h.store.chat(for: Self.key)
        #expect(await chat.abortSession())
        #expect(chat.errorMessage?.hasPrefix("Couldn’t stop everything:") == true)
        #expect(chat.errorMessage?.contains("1 child could not be stopped") == true)
    }

    @Test func exactRunAbortFailureSetsCouldntStop() async throws {
        let h = try await Harness()
        defer { h.finish() }
        h.fake.reply(to: "chat.abort", .error(code: "INVALID_REQUEST", message: "boom"))
        let chat = h.store.chat(for: Self.key)
        chat.live = LiveRun(runId: "run-live")
        await chat.abort()
        #expect(chat.errorMessage?.hasPrefix("Couldn’t stop") == true)
    }

    // MARK: Failure

    @Test func errorSetsErrorMessageAndReturnsFalse() async throws {
        let h = try await Harness()
        defer { h.finish() }
        h.fake.reply(to: "sessions.abort", .error(code: "INVALID_REQUEST", message: "session target is unavailable"))
        let chat = h.store.chat(for: Self.key)
        #expect(await chat.abortSession() == false)
        #expect(chat.errorMessage?.hasPrefix("Couldn’t stop") == true)
        #expect(chat.errorMessage?.contains("session target is unavailable") == true)
        #expect(h.fake.requests("chat.abort").isEmpty, "a real error doesn't fall back")
    }

    @Test func offlineAbortFailsWithoutQueueing() async throws {
        let h = try await Harness(connect: false)
        defer { h.finish() }
        let chat = h.store.chat(for: Self.key)
        #expect(await chat.abortSession() == false)
        #expect(chat.errorMessage?.hasPrefix("Couldn’t stop") == true)
        #expect(h.store.outbox.entries(for: Self.key).isEmpty)
        #expect(h.fake.requests("sessions.abort").isEmpty)
        #expect(h.fake.requests("chat.abort").isEmpty)
    }

    @Test func noActiveRunStillSucceeds() async throws {
        let h = try await Harness()
        defer { h.finish() }
        h.fake.reply(to: "sessions.abort", .result(["ok": true, "abortedRunId": .null, "status": "no-active-run"]))
        let chat = h.store.chat(for: Self.key)
        #expect(await chat.abortSession())
        #expect(chat.errorMessage == nil)
    }
}
