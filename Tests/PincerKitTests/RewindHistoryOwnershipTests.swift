import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Rewind history ownership")
struct RewindHistoryOwnershipTests {
    private static let key = "agent:main:dashboard:garden"
    private static let other = "agent:main:dashboard:other"
    private static let oldHistory = Fixtures.json(#"{"messages":[{"role":"user","content":"First question","__openclaw":{"id":"u1"}},{"role":"user","content":"Later question","__openclaw":{"id":"u2"}}]}"#)
    private static let freshHistory = Fixtures.json(#"{"messages":[{"role":"user","content":"First question","__openclaw":{"id":"u1"}}]}"#)

    @MainActor private final class Server {
        var firstEntered = false
        var historyCalls = 0
        var rewindCalls = 0
        var changed = false
        var released = false
        var waiter: CheckedContinuation<Void, Never>?
        let oldFails: Bool
        let rewindFails: Bool
        init(oldFails: Bool = false, rewindFails: Bool = false) {
            self.oldFails = oldFails; self.rewindFails = rewindFails
        }
        func release() { released = true; let old = waiter; waiter = nil; old?.resume() }
        func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
            switch method {
            case SessionManager.historyMethod:
                #expect(params["limit"] == .number(Double(SessionManager.rewindHistoryLimit)))
                historyCalls += 1
                if params["sessionKey"] == .string(RewindHistoryOwnershipTests.key) && !firstEntered {
                    firstEntered = true
                    let captured = RewindHistoryOwnershipTests.oldHistory
                    await withTaskCancellationHandler {
                        await withCheckedContinuation { continuation in
                            if released || Task.isCancelled { continuation.resume() } else { waiter = continuation }
                        }
                    } onCancel: { Task { @MainActor in self.release() } }
                    try Task.checkCancellation()
                    if oldFails { throw GatewayError.closed("old history fixture failure") }
                    return captured
                }
                return changed ? RewindHistoryOwnershipTests.freshHistory : RewindHistoryOwnershipTests.oldHistory
            case SessionManager.rewindMethod:
                rewindCalls += 1
                #expect(params["entryId"] == "u2")
                if rewindFails { throw GatewayError.rpc(code: "UNAVAILABLE", message: "Rewind is unavailable while the agent is working.", details: nil) }
                changed = true
                return ["editorText": "Later question"]
            case SessionManager.branchesListMethod: return ["branches": []]
            case SessionManager.describeMethod:
                return ["session": ["key": params["key"] ?? .null]]
            default: Issue.record("Unexpected rewind fixture method: \(method)"); return [:]
            }
        }
    }
    private func model(_ server: Server) -> SessionManagerModel {
        SessionManagerModel(methods: { [SessionManager.historyMethod, SessionManager.rewindMethod,
            SessionManager.branchesListMethod, SessionManager.describeMethod] },
            scopes: { [GatewayConnection.adminScope] }, request: { try await server.request($0, $1) })
    }

    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func successfulRewindRejectsOldHistoryPublication(_ oldFails: Bool) async throws {
        let server = Server(oldFails: oldFails)
        let model = model(server)
        let old = Task { await model.loadRewindPoints(key: Self.key) }
        defer { server.release(); old.cancel() }
        try #require(await eventually { server.firstEntered })
        let rewound = await model.rewind(key: Self.key, entryId: "u2")
        try #require(rewound, "The actual rewind and all mutation-triggered reloads must complete")
        #expect(server.rewindCalls == 1 && server.historyCalls == 2)
        #expect(model.rewindPoints[Self.key]?.map(\.entryId) == ["u1"])
        #expect(model.rewindErrors[Self.key] == nil)
        server.release()
        await old.value
        #expect(model.rewindPoints[Self.key]?.map(\.entryId) == ["u1"],
                "Old history must not restore an entry removed by a completed rewind")
        #expect(model.rewindErrors[Self.key] == nil,
                "Old history failure must not attach an error to the fresh rewind points")
        #expect(model.lastEditorText == "Later question")
    }

    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func unrelatedOrRejectedMutationKeepsStillValidHistory(_ rejected: Bool) async throws {
        let server = Server(rewindFails: rejected)
        let model = model(server)
        let old = Task { await model.loadRewindPoints(key: Self.key) }
        defer { server.release(); old.cancel() }
        try #require(await eventually { server.firstEntered })
        let result = await model.rewind(key: rejected ? Self.key : Self.other, entryId: "u2")
        #expect(result == !rejected)
        server.release()
        await old.value
        #expect(model.rewindPoints[Self.key]?.map(\.entryId) == ["u2", "u1"])
        #expect(model.rewindErrors[Self.key] == nil)
        #expect(server.rewindCalls == 1)
    }

    @Test(.timeLimit(.minutes(2))) func currentHistoryReadPublishesNormally() async {
        let server = Server()
        server.release()
        let model = model(server)
        await model.loadRewindPoints(key: Self.key)
        #expect(model.rewindPoints[Self.key]?.map(\.entryId) == ["u2", "u1"])
        #expect(model.rewindErrors[Self.key] == nil && server.historyCalls == 1)
    }
}
