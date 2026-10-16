import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Session detail deletion ownership")
struct SessionDetailOwnershipTests {
    private static let key = "agent:main:dashboard:alpha"
    private static let other = "agent:main:dashboard:beta"
    private static let row: JSONValue = ["key": .string(key), "agentId": "main", "sessionId": "s-alpha", "title": "Alpha"]
    private static let otherRow: JSONValue = ["key": .string(other), "agentId": "main", "sessionId": "s-beta", "title": "Beta"]

    @MainActor private final class Server {
        var entered = false
        var released = false
        var waiter: CheckedContinuation<Void, Never>?
        var describeCalls = 0
        var deleteCalls = 0
        var deleted: Set<String> = []
        let oldFails: Bool
        let deleteFails: Bool
        init(oldFails: Bool = false, deleteFails: Bool = false) { self.oldFails = oldFails; self.deleteFails = deleteFails }
        func release() { released = true; let old = waiter; waiter = nil; old?.resume() }
        func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
            switch method {
            case SessionManager.listMethod:
                return ["sessions": [SessionDetailOwnershipTests.row, SessionDetailOwnershipTests.otherRow]]
            case SessionManager.describeMethod:
                describeCalls += 1
                #expect(params == ["key": .string(SessionDetailOwnershipTests.key), "agentId": "main",
                                   "includeDerivedTitles": true, "includeLastMessage": true])
                let captured: JSONValue = ["session": SessionDetailOwnershipTests.row]
                entered = true
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        if released || Task.isCancelled { continuation.resume() } else { waiter = continuation }
                    }
                } onCancel: { Task { @MainActor in self.release() } }
                try Task.checkCancellation()
                if oldFails { throw GatewayError.closed("old describe fixture failure") }
                return captured
            case SessionManager.deleteMethod:
                deleteCalls += 1
                let key = try #require(params["key"]?.text)
                #expect(params["deleteTranscript"] == true && params["agentId"] == "main")
                #expect(params["expectedSessionId"] == .string(key == SessionDetailOwnershipTests.key ? "s-alpha" : "s-beta"))
                if deleteFails { return ["deleted": false] }
                deleted.insert(key)
                return ["deleted": true]
            default: Issue.record("Unexpected session detail fixture method: \(method)"); return [:]
            }
        }
    }
    private func model(_ server: Server) -> SessionManagerModel {
        SessionManagerModel(methods: { [SessionManager.listMethod, SessionManager.describeMethod, SessionManager.deleteMethod] },
            scopes: { [GatewayConnection.adminScope] }, request: { try await server.request($0, $1) })
    }

    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func successfulDeleteRejectsOlderDescribeSuccessOrFailure(_ oldFails: Bool) async throws {
        let server = Server(oldFails: oldFails)
        let model = model(server)
        await model.load(filter: .all)
        try #require(model.row(Self.key) != nil)
        let old = Task { await model.loadDetails(key: Self.key) }
        defer { server.release(); old.cancel() }
        try #require(await eventually { server.entered })
        let deleted = await model.delete([Self.key])
        #expect(deleted.succeeded == [Self.key] && server.deleted == [Self.key])
        #expect(model.row(Self.key) == nil && model.details[Self.key] == nil && model.detailErrors[Self.key] == nil)
        server.release(); await old.value
        #expect(model.details[Self.key] == nil, "Old describe must not resurrect details of an actually deleted session")
        #expect(model.detailErrors[Self.key] == nil, "Old describe failure must not attach an error after deletion")
        #expect(model.row(Self.key) == nil && server.describeCalls == 1 && server.deleteCalls == 1)
    }

    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func unrelatedOrFailedDeletePreservesValidDescribe(_ failed: Bool) async throws {
        let server = Server(deleteFails: failed)
        let model = model(server)
        await model.load(filter: .all)
        let old = Task { await model.loadDetails(key: Self.key) }
        defer { server.release(); old.cancel() }
        try #require(await eventually { server.entered })
        let result = await model.delete([failed ? Self.key : Self.other])
        #expect(result.succeeded == (failed ? [] : [Self.other]))
        #expect(result.failed.count == (failed ? 1 : 0))
        server.release(); await old.value
        #expect(model.details[Self.key]?.raw == Self.row && model.detailErrors[Self.key] == nil)
        #expect(model.row(Self.key) != nil && server.deleteCalls == 1)
    }

    @Test(.timeLimit(.minutes(2))) func ordinaryCurrentDescribePublishes() async {
        let server = Server()
        server.release()
        let model = model(server)
        await model.load(filter: .all)
        await model.loadDetails(key: Self.key)
        #expect(model.details[Self.key]?.raw == Self.row && model.detailErrors[Self.key] == nil)
        #expect(server.describeCalls == 1 && server.deleteCalls == 0)
    }
    @MainActor private final class Reads {
        var entered = 0
        var released: Set<Int> = []
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
        var failures: Set<Int> = []
        func release(_ index: Int) { released.insert(index); waiters.removeValue(forKey: index)?.resume() }
        func releaseAll() { release(1); release(2) }
        func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
            if method == SessionManager.previewMethod { return ["previews": []] }
            #expect(method == SessionManager.describeMethod)
            entered += 1
            let index = entered
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if released.contains(index) || Task.isCancelled { continuation.resume() }
                    else { waiters[index] = continuation }
                }
            } onCancel: { Task { @MainActor in self.release(index) } }
            try Task.checkCancellation()
            if failures.contains(index) { throw GatewayError.closed("describe round \(index) failed") }
            return ["session": index == 1 ? SessionDetailOwnershipTests.row
                : ["key": .string(SessionDetailOwnershipTests.key), "title": "Fresh detail"]]
        }
    }
    private func readModel(_ reads: Reads) -> SessionManagerModel {
        SessionManagerModel(request: { try await reads.request($0, $1) })
    }

    @Test(.timeLimit(.minutes(2)), arguments: [false, true], [false, true])
    func latestReadOwnsItsSuccessOrFailure(_ latestFails: Bool, _ oldFails: Bool) async throws {
        let reads = Reads()
        if latestFails { reads.failures.insert(2) }
        if oldFails { reads.failures.insert(1) }
        let model = readModel(reads)
        let old = Task { await model.loadDetails(key: Self.key) }
        defer { reads.releaseAll(); old.cancel() }
        try #require(await eventually { reads.entered == 1 })
        let latest = Task { await model.loadDetails(key: Self.key) }
        defer { latest.cancel() }
        try #require(await eventually { reads.entered == 2 })
        reads.release(2); await latest.value
        let detail = model.details[Self.key]
        let error = model.detailErrors[Self.key]
        if latestFails { #expect(error != nil && detail == nil) }
        else { #expect(detail?.raw["title"] == "Fresh detail" && error == nil) }
        reads.release(1); await old.value
        #expect(model.details[Self.key] == detail && model.detailErrors[Self.key] == error)
    }

    @Test(.timeLimit(.minutes(2))) func previewRefreshDoesNotInvalidateDetails() async throws {
        let reads = Reads()
        let model = readModel(reads)
        let task = Task { await model.loadDetails(key: Self.key) }
        defer { reads.releaseAll(); task.cancel() }
        try #require(await eventually { reads.entered == 1 })
        await model.reloadPreview(key: Self.key)
        reads.release(1); await task.value
        #expect(model.details[Self.key]?.raw == Self.row && model.detailErrors[Self.key] == nil)
    }

    @Test(.timeLimit(.minutes(2))) func reconnectInvalidatesOldDetailRead() async throws {
        let reads = Reads()
        let model = readModel(reads)
        let task = Task { await model.loadDetails(key: Self.key) }
        defer { reads.releaseAll(); task.cancel() }
        try #require(await eventually { reads.entered == 1 })
        model.handleReconnect()
        reads.release(1); await task.value
        #expect(model.details[Self.key] == nil && model.detailErrors[Self.key] == nil)
    }

    @Test(.timeLimit(.minutes(2))) func canceledCallerCannotDisplaceCurrentDetailRead() async throws {
        let reads = Reads()
        let model = readModel(reads)
        let current = Task { await model.loadDetails(key: Self.key) }
        defer { reads.releaseAll(); current.cancel() }
        try #require(await eventually { reads.entered == 1 })
        let canceled = Task { await model.loadDetails(key: Self.key) }
        canceled.cancel(); await canceled.value
        #expect(reads.entered == 1)
        reads.release(1); await current.value
        #expect(model.details[Self.key]?.raw == Self.row && model.detailErrors[Self.key] == nil)
    }

    @Test(.timeLimit(.minutes(2))) func canceledOlderCompletionCannotClearNewOwner() async throws {
        let reads = Reads()
        let model = readModel(reads)
        let old = Task { await model.loadDetails(key: Self.key) }
        defer { reads.releaseAll(); old.cancel() }
        try #require(await eventually { reads.entered == 1 })
        let latest = Task { await model.loadDetails(key: Self.key) }
        defer { latest.cancel() }
        try #require(await eventually { reads.entered == 2 })
        old.cancel(); await old.value
        reads.release(2); await latest.value
        #expect(model.details[Self.key]?.raw["title"] == "Fresh detail" && model.detailErrors[Self.key] == nil)
    }

}
