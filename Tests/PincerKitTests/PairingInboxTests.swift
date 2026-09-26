import Foundation
import Testing
@testable import PincerKit

/// Builds `channels.pairing.list` fixtures relative to a fixed clock.
enum PairingFixtures {
    static let now = Date()

    static func stamp(_ offset: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(offset))
    }

    static func request(_ id: String, channel: String = "telegram", account: String = "home", sender: String = "4411",
                        metadata: [String: JSONValue]? = nil, created: TimeInterval = -300, expires: TimeInterval = 3300,
                        notify: Bool = true) -> JSONValue
    {
        var row: [String: JSONValue] = [
            "requestId": .string(id), "channel": .string(channel), "channelLabel": .string(channel.capitalized),
            "accountId": .string(account), "senderId": .string(sender), "senderLabel": .string("\(channel.capitalized) user id"),
            "createdAt": .string(stamp(created)), "lastSeenAt": .string(stamp(created)), "expiresAt": .string(stamp(expires)),
            "notifySupported": .bool(notify),
        ]
        if let metadata { row["metadata"] = .object(metadata) }
        return .object(row)
    }

    static let accounts: JSONValue = [
        ["channel": "telegram", "channelLabel": "Telegram", "accountId": "home", "accountLabel": "Home bot", "notifySupported": true],
        ["channel": "discord", "channelLabel": "Discord", "accountId": "family", "notifySupported": false],
    ]

    static func list(_ requests: [JSONValue], owner: Bool = true, accounts: JSONValue = accounts) -> JSONValue {
        ["accounts": accounts, "requests": .array(requests), "commandOwnerConfigured": .bool(owner),
         "limits": ["pendingPerAccount": 3, "ttlMs": 3_600_000]]
    }
}

/// A fake Gateway for `PairingInboxModel`: records calls, answers list with `listResult`, and
/// throws `failure` (when set) for approve and dismiss.
@MainActor
final class ScriptedPairing {
    var calls: [(method: String, params: JSONValue)] = []
    var listResult = PairingFixtures.list([])
    var listError: GatewayError?
    var failure: GatewayError?
    var approveResult: JSONValue = ["requestId": "r", "senderId": "4411", "notification": "sent", "commandOwnerBootstrap": "not-requested"]

    func request(_ method: String, _ params: JSONValue) throws -> JSONValue {
        self.calls.append((method, params))
        if method == PairingInboxModel.listMethod {
            if let listError { throw listError }
            return self.listResult
        }
        if let failure { throw failure }
        return method == PairingInboxModel.approveMethod ? self.approveResult : ["requestId": "r", "senderId": "4411"]
    }

    var methods: [String] { self.calls.map(\.method) }
}

@Suite("Pairing requests")
struct PairingRequestTests {
    @Test func minimalRequest() throws {
        let bare = try #require(PairingRequest(["requestId": "r1", "channel": "signal", "accountId": "main", "senderId": "+15550100"]))
        #expect(bare.title == "+15550100")
        #expect(bare.senderLine == "Sender ID: +15550100" && bare.accountLine == "Signal · main")
        #expect(bare.metadata.isEmpty && bare.details.isEmpty && bare.accountLabel == nil)
        #expect(bare.expiresAt == nil && !bare.isExpired() && !bare.notifySupported)
    }

    @Test func requiredFields() {
        #expect(PairingRequest(["requestId": "r1", "channel": "signal", "accountId": "main"]) == nil)
        #expect(PairingRequest(["channel": "signal", "accountId": "main", "senderId": "x"]) == nil)
        #expect(PairingRequest(["requestId": "r1", "accountId": "main", "senderId": "x"]) == nil)
        #expect(PairingRequest("not an object") == nil)
    }

    @Test(arguments: [
        (["name": "Maya Chen", "username": "mayac"], "Maya Chen"),
        (["Name": "Maya Chen"], "Maya Chen"),
        (["name": "  ", "username": "mayac"], "@mayac"),
        (["USERNAME": "@mayac"], "@mayac"),
        (["username": ""], "4411"),
        ([:], "4411"),
    ] as [([String: String], String)])
    func titleFallback(metadata: [String: String], title: String) throws {
        let json = PairingFixtures.request("r", metadata: metadata.mapValues { .string($0) })
        #expect(try #require(PairingRequest(json)).title == title)
    }

    @Test func detailsLeaveOutNameAndUsername() throws {
        let request = try #require(PairingRequest(PairingFixtures.request("r", metadata: [
            "Name": "Maya", "username": "mayac", "languageCode": "en", "first_name": "Maya",
        ])))
        #expect(request.details.map(\.label) == ["First name", "Language code"])
        #expect(request.details.map(\.value) == ["Maya", "en"])
    }

    @Test func expiry() throws {
        let live = try #require(PairingRequest(PairingFixtures.request("r", expires: 100)))
        #expect(!live.isExpired(at: PairingFixtures.now) && live.isExpired(at: PairingFixtures.now.addingTimeInterval(101)))
        let expired = try #require(PairingRequest(PairingFixtures.request("e", created: -3700, expires: -1)))
        #expect(expired.isExpired(at: PairingFixtures.now) && expired.timing(at: PairingFixtures.now).hasSuffix("Expired"))
    }

    @Test func fractionalAndEpochDates() throws {
        let fractional = try #require(PairingRequest(Fixtures.json(
            #"{"requestId":"f","channel":"c","accountId":"a","senderId":"s","createdAt":"2026-07-01T10:00:00.123Z","expiresAt":1700000000000}"#)))
        #expect(fractional.createdAt != nil)
        #expect(fractional.expiresAt == Date(timeIntervalSince1970: 1_700_000_000))
    }
}

@Suite("Pairing approve params")
struct PairingParamsTests {
    let notifying = PairingRequest(PairingFixtures.request("n1", notify: true))!
    let silent = PairingRequest(PairingFixtures.request("s1", notify: false))!

    @Test func notifyOnlyWhenSupported() {
        #expect(PairingInboxModel.approveParams(self.notifying, notify: false, makeCommandOwner: false, canBootstrapCommandOwner: false)
            == ["channel": "telegram", "accountId": "home", "requestId": "n1", "notify": false])
        #expect(PairingInboxModel.approveParams(self.notifying, notify: true, makeCommandOwner: false, canBootstrapCommandOwner: false)["notify"] == true)
        #expect(PairingInboxModel.approveParams(self.silent, notify: true, makeCommandOwner: false, canBootstrapCommandOwner: true)
            == ["channel": "telegram", "accountId": "home", "requestId": "s1"])
    }

    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func bootstrapCommandOwnerOnlyWhenChosenAndAllowed(chosen: Bool, allowed: Bool) {
        let params = PairingInboxModel.approveParams(self.silent, notify: true, makeCommandOwner: chosen, canBootstrapCommandOwner: allowed)
        #expect(params["bootstrapCommandOwner"] == (chosen && allowed ? true : nil))
        let keys = Set(params.object?.keys.map(\.self) ?? [])
        #expect(keys.isSubset(of: ["channel", "accountId", "requestId", "notify", "bootstrapCommandOwner"]))
    }

    @Test func dismissParams() {
        #expect(PairingInboxModel.dismissParams(self.notifying) == ["channel": "telegram", "accountId": "home", "requestId": "n1"])
    }
}

@MainActor
@Suite("Pairing inbox model")
struct PairingInboxModelTests {
    func model(_ script: ScriptedPairing, methods: Set<String>? = nil,
               scopes: [String] = [PairingInboxModel.pairingScope]) -> PairingInboxModel
    {
        PairingInboxModel(methods: { methods }, scopes: { scopes }) { try script.request($0, $1) }
    }

    @Test func loadSortsAndCountsPending() async {
        let script = ScriptedPairing()
        script.listResult = PairingFixtures.list([
            PairingFixtures.request("old", created: -1200), PairingFixtures.request("new", created: -60),
            PairingFixtures.request("gone", created: -3700, expires: -100),
        ])
        let model = self.model(script)
        await model.load()
        #expect(script.calls.first?.params == [:])
        #expect(model.hasLoaded && model.loadState == .idle)
        #expect(model.requests.map(\.requestId) == ["new", "old", "gone"])
        #expect(model.pendingCount(at: PairingFixtures.now) == 2)
        #expect(model.limits?.ttl == 3600 && model.limits?.pendingPerAccount == 3)
    }

    @Test func channelFilterNarrowsRequestsAndAccounts() async {
        let script = ScriptedPairing()
        script.listResult = PairingFixtures.list([
            PairingFixtures.request("t", created: -60), PairingFixtures.request("d", channel: "discord", account: "family", created: -120),
        ])
        let model = self.model(script)
        await model.load()
        #expect(model.showsChannelFilter && model.channelFilterLabel == nil && model.visibleAccounts.count == 2)
        model.channelFilter = "discord"
        #expect(model.visibleRequests.map(\.requestId) == ["d"])
        #expect(model.visibleAccounts.map(\.id) == ["discord:family"] && model.channelFilterLabel == "Discord")
        #expect(script.calls.count == 1)

        script.listResult = PairingFixtures.list([PairingFixtures.request("t", created: -60)],
                                                 accounts: [["channel": "telegram", "accountId": "home"]])
        await model.refresh()
        #expect(model.channelFilter == nil && !model.showsChannelFilter && model.visibleAccounts.count == 1)
    }

    @Test func approveRemovesRowAndSendsParams() async throws {
        let script = ScriptedPairing()
        script.listResult = PairingFixtures.list([PairingFixtures.request("a", notify: false)])
        let model = self.model(script)
        await model.load()
        let a = try #require(model.requests.first)
        #expect(await model.approve(a, notify: true, makeCommandOwner: true))
        #expect(script.calls.last?.method == PairingInboxModel.approveMethod)
        #expect(script.calls.last?.params == PairingInboxModel.approveParams(a, notify: true, makeCommandOwner: false, canBootstrapCommandOwner: false))
        #expect(model.requests.isEmpty && model.pendingCount() == 0 && model.notice == nil)
    }

    @Test func approveNotices() async throws {
        let script = ScriptedPairing()
        script.listResult = PairingFixtures.list([PairingFixtures.request("a")], owner: false)
        script.approveResult = ["requestId": "a", "senderId": "4411", "notification": "failed", "commandOwnerBootstrap": "configured"]
        let model = self.model(script, scopes: [GatewayConnection.adminScope])
        await model.load()
        #expect(model.canBootstrapCommandOwner)
        await model.approve(try #require(model.requests.first), makeCommandOwner: true)
        #expect(script.calls.last?.params["bootstrapCommandOwner"] == true)
        #expect(model.notice?.text == "Approved, but the sender couldn't be notified." && !model.canBootstrapCommandOwner)
    }

    @Test func expiredApproveShowsNoticeWithoutSending() async throws {
        let script = ScriptedPairing()
        script.listResult = PairingFixtures.list([PairingFixtures.request("late", created: -3700, expires: -5)])
        let model = self.model(script)
        await model.load()
        let late = try #require(model.requests.first)
        #expect(await model.approve(late) == false)
        #expect(model.notice?.text == PairingInboxModel.expiredMessage)
        #expect(!script.methods.contains(PairingInboxModel.approveMethod) && model.operation(for: late) == .idle)
        #expect(await model.dismiss(late) && model.requests.isEmpty)
    }

    @Test(arguments: [PairingInboxModel.approveMethod, PairingInboxModel.dismissMethod])
    func staleRequestIsRemovedAndRefreshed(method: String) async throws {
        let script = ScriptedPairing()
        script.listResult = PairingFixtures.list([PairingFixtures.request("stale", created: -60), PairingFixtures.request("keep", created: -120)])
        let model = self.model(script)
        await model.load()
        let stale = try #require(model.requests.first { $0.requestId == "stale" })
        script.listResult = PairingFixtures.list([PairingFixtures.request("keep", created: -120)])
        script.failure = .rpc(code: "INVALID_REQUEST", message: "pending DM access request no longer exists", details: nil)
        let gone = method == PairingInboxModel.approveMethod ? await model.approve(stale) : await model.dismiss(stale)
        #expect(gone && model.requests.map(\.requestId) == ["keep"])
        #expect(model.notice?.text == PairingInboxModel.staleMessage)
        #expect(script.methods == [PairingInboxModel.listMethod, method, PairingInboxModel.listMethod])
    }

    @Test func notPairingAccountRefreshesWithGatewayMessage() async throws {
        let script = ScriptedPairing()
        script.listResult = PairingFixtures.list([PairingFixtures.request("r")])
        let model = self.model(script)
        await model.load()
        script.failure = .rpc(code: "INVALID_REQUEST", message: "channel account does not use DM pairing: telegram:home", details: nil)
        #expect(await model.dismiss(try #require(model.requests.first)) == false)
        #expect(model.notice?.text == "channel account does not use DM pairing: telegram:home")
        #expect(script.methods.last == PairingInboxModel.listMethod)
    }

    @Test func otherErrorsStayOnTheRow() async throws {
        let script = ScriptedPairing()
        script.listResult = PairingFixtures.list([PairingFixtures.request("r")])
        let model = self.model(script)
        await model.load()
        let row = try #require(model.requests.first)
        script.failure = .rpc(code: "UNAVAILABLE", message: "pairing store unavailable", details: nil)
        #expect(await model.approve(row) == false)
        #expect(model.requests.count == 1 && model.operation(for: row).error == "pairing store unavailable")
        script.failure = nil
        #expect(await model.approve(row) && model.requests.isEmpty)
    }

    @Test(arguments: [
        ([GatewayConnection.adminScope], true),
        ([PairingInboxModel.pairingScope], true),
        (["operator.read", "operator.write", "operator.approvals", "operator.questions"], false),
        ([], false),
    ] as [([String], Bool)])
    func scopeCheck(scopes: [String], canManage: Bool) async {
        let script = ScriptedPairing()
        let model = self.model(script, scopes: scopes)
        await model.load()
        #expect(model.canManage == canManage && model.needsAccess == !canManage)
        #expect(script.calls.isEmpty == !canManage)
    }

    @Test func missingScopeReply() async {
        let script = ScriptedPairing()
        script.listError = .rpc(code: "FORBIDDEN", message: "missing scope: operator.pairing",
                                details: ["code": "MISSING_SCOPE", "missingScope": "operator.pairing"])
        let model = self.model(script)
        await model.load()
        #expect(model.needsAccess && model.pendingCount() == 0)
        #expect(model.loadState.error == PairingInboxModel.missingScopeMessage)
    }

    @Test func unsupportedWhenNotAdvertised() async {
        let script = ScriptedPairing()
        let model = self.model(script, methods: ["chat.send", "approval.history"])
        await model.load()
        await model.seed()
        #expect(!model.supported && script.calls.isEmpty && model.pendingCount() == 0)
        #expect(self.model(ScriptedPairing(), methods: [PairingInboxModel.listMethod]).supported)
        #expect(self.model(ScriptedPairing(), methods: []).supported)
    }

    @Test(arguments: ["UNKNOWN_METHOD", "INVALID_REQUEST"])
    func unsupportedAfterUnknownMethodError(code: String) async {
        let script = ScriptedPairing()
        script.listError = .rpc(code: code, message: "unknown method: channels.pairing.list", details: nil)
        let model = self.model(script)
        await model.load()
        #expect(!model.supported && model.hasLoaded && model.loadState == .idle && model.requests.isEmpty)
    }
}
