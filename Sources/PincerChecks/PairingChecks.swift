import CoreGraphics
import Foundation
import CryptoKit
import ImageIO
import Network
import Observation
import PincerKit
import PincerPush
import SQLite3
import Synchronization
import UniformTypeIdentifiers
import UserNotifications

/// `PairingInboxModel` against a scripted Gateway: parsing, titles, scopes, unsupported
/// gateways, approve/dismiss params, stale requests, expiry and in-flight rows during polls.
@MainActor
func checkPairingInboxModel() async {
    let iso = ISO8601DateFormatter()
    let now = Date()
    func stamp(_ offset: TimeInterval) -> String { iso.string(from: now.addingTimeInterval(offset)) }
    func requestJSON(_ id: String, channel: String = "telegram", account: String = "home", sender: String = "4411",
                     metadata: String? = nil, created: TimeInterval = -300, expires: TimeInterval = 3300,
                     lastSeen: TimeInterval? = nil, notify: Bool = true, extra: String = "") -> JSONValue
    {
        let meta = metadata.map { #","metadata":\#($0)"# } ?? ""
        return json(#"{"requestId":"\#(id)","channel":"\#(channel)","channelLabel":"\#(channel.capitalized)","accountId":"\#(account)","senderId":"\#(sender)","senderLabel":"\#(channel.capitalized) user id","createdAt":"\#(stamp(created))","lastSeenAt":"\#(stamp(lastSeen ?? created))","expiresAt":"\#(stamp(expires))","notifySupported":\#(notify)\#(meta)\#(extra)}"#)
    }
    let accounts: JSONValue = [
        json(#"{"channel":"telegram","channelLabel":"Telegram","accountId":"home","accountLabel":"Home bot","notifySupported":true}"#),
        json(#"{"channel":"discord","channelLabel":"Discord","accountId":"family","notifySupported":false}"#),
    ]
    func listResult(_ requests: [JSONValue], owner: Bool = true, accounts: JSONValue = accounts) -> JSONValue {
        ["accounts": accounts, "requests": .array(requests), "commandOwnerConfigured": .bool(owner),
         "limits": ["pendingPerAccount": 3, "ttlMs": 3_600_000]]
    }

    // Parsing and presentation.
    let bare = PairingRequest(json(#"{"requestId":"r1","channel":"signal","accountId":"main","senderId":"+15550100"}"#))
    check(bare?.title == "+15550100" && bare?.accountLine == "Signal · main" && bare?.senderLine == "Sender ID: +15550100"
          && bare?.details.isEmpty == true && bare?.metadata.isEmpty == true && bare?.expiresAt == nil && bare?.isExpired() == false,
          "request without accountLabel, labels or metadata")
    check(PairingRequest(json(#"{"requestId":"r1","channel":"signal","accountId":"main"}"#)) == nil
          && PairingRequest(json(#"{"channel":"signal","accountId":"main","senderId":"x"}"#)) == nil, "senderId and requestId required")
    let named = PairingRequest(requestJSON("r2", metadata: #"{"Name":"Maya Chen","username":"mayac","languageCode":"en","first_name":"Maya"}"#))
    check(named?.title == "Maya Chen", "title uses metadata name (case-insensitive key)")
    check(named?.details.map(\.label) == ["First name", "Language code"] && named?.details.last?.value == "en",
          "other metadata humanized, name and username left out")
    check(PairingRequest(requestJSON("r3", metadata: #"{"name":"  ","username":"mayac"}"#))?.title == "@mayac", "blank name → @username")
    check(PairingRequest(requestJSON("r4", metadata: #"{"USERNAME":"@mayac"}"#))?.title == "@mayac", "username keeps a single @")
    check(PairingRequest(requestJSON("r5", metadata: #"{"username":""}"#))?.title == "4411", "empty metadata → senderId")
    let timed = PairingRequest(requestJSON("r6", created: -300, expires: 3300))
    check(timed?.accountLine == "Telegram · home" && timed?.senderLine == "Telegram user id: 4411", "sender and account lines")
    let timing = timed?.timing(at: now) ?? ""
    check(timing.hasPrefix("Requested ") && timing.contains(" ago · Expires in ") && !timing.contains("Last seen"),
          "timing line (\(timing))")
    let seenAgain = PairingRequest(requestJSON("r7", created: -600, lastSeen: -60))
    check(seenAgain?.showsLastSeen == true && seenAgain?.timing(at: now).contains("Last seen") == true
          && PairingRequest(requestJSON("r8", created: -600, lastSeen: -570))?.showsLastSeen == false, "last seen only when > 1 min later")
    let expired = PairingRequest(requestJSON("r9", created: -3700, expires: -100))
    check(expired?.isExpired(at: now) == true && expired?.timing(at: now).hasSuffix("Expired") == true, "expired request")
    let fractional = PairingRequest(json(#"{"requestId":"f","channel":"c","accountId":"a","senderId":"s","createdAt":"2026-07-01T10:00:00.123Z"}"#))
    check(fractional?.createdAt != nil, "ISO dates with fractional seconds")

    // Loading, sorting, filtering and the badge count.
    var calls: [(String, JSONValue)] = []
    let result = Scripted(listResult([
        requestJSON("old", created: -1200), requestJSON("new", created: -60),
        requestJSON("disc", channel: "discord", account: "family", created: -600, notify: false),
        requestJSON("gone", created: -3700, expires: -100),
    ]))
    let model = PairingInboxModel { method, params in
        calls.append((method, params))
        return result.value
    }
    await model.load()
    check(calls.first?.0 == "channels.pairing.list" && calls.first?.1 == [:], "list is called with {}")
    check(model.hasLoaded && model.supported && !model.needsAccess && model.loadState == .idle, "loaded")
    check(model.requests.map(\.requestId) == ["new", "disc", "old", "gone"], "newest first")
    check(model.pendingCount(at: now) == 3, "expired requests left out of the count")
    check(model.accounts.map(\.displayName) == ["Home bot", "family"] && model.limits?.pendingPerAccount == 3
          && model.limits?.ttl == 3600 && model.commandOwnerConfigured, "accounts and limits")
    check(model.showsChannelFilter && model.channels.map(\.label) == ["Telegram", "Discord"], "channel filter with two channels")
    model.channelFilter = "discord"
    check(model.visibleRequests.map(\.requestId) == ["disc"], "channel filter is local")
    result.value = listResult([requestJSON("new", created: -60)],
                        accounts: [json(#"{"channel":"telegram","channelLabel":"Telegram","accountId":"home","notifySupported":true}"#)])
    await model.refresh()
    check(calls.count == 2 && calls.last?.1 == [:] && model.channelFilter == nil && !model.showsChannelFilter
          && model.visibleRequests.count == 1, "filter cleared when its channel is gone")

    // Approve params.
    let notifying = PairingRequest(requestJSON("n1", notify: true))!
    let silent = PairingRequest(requestJSON("s1", notify: false))!
    let withNotify = PairingInboxModel.approveParams(notifying, notify: false, makeCommandOwner: false, canBootstrapCommandOwner: false)
    check(withNotify == ["channel": "telegram", "accountId": "home", "requestId": "n1", "notify": false], "notify sent when supported")
    check(PairingInboxModel.approveParams(silent, notify: true, makeCommandOwner: false, canBootstrapCommandOwner: true)
          == ["channel": "telegram", "accountId": "home", "requestId": "s1"], "notify omitted when unsupported")
    check(PairingInboxModel.approveParams(silent, notify: true, makeCommandOwner: true, canBootstrapCommandOwner: false)["bootstrapCommandOwner"] == nil
          && PairingInboxModel.approveParams(silent, notify: true, makeCommandOwner: false, canBootstrapCommandOwner: true)["bootstrapCommandOwner"] == nil
          && PairingInboxModel.approveParams(silent, notify: true, makeCommandOwner: true, canBootstrapCommandOwner: true)["bootstrapCommandOwner"] == true,
          "bootstrapCommandOwner only when chosen and allowed")
    check(PairingInboxModel.dismissParams(notifying) == ["channel": "telegram", "accountId": "home", "requestId": "n1"], "dismiss params")

    // Approve and dismiss against the scripted Gateway.
    calls = []
    let approveReply = Scripted<JSONValue>(["requestId": "a", "senderId": "4411", "notification": "sent", "commandOwnerBootstrap": "not-requested"])
    let failure = Scripted<GatewayError?>(nil)
    result.value = listResult([requestJSON("a", created: -60), requestJSON("b", created: -120), requestJSON("c", created: -180)], owner: false)
    let actions = PairingInboxModel(scopes: { ["operator.read", "operator.admin"] }) { method, params in
        calls.append((method, params))
        if method != "channels.pairing.list", let error = failure.value { throw error }
        return method == "channels.pairing.approve" ? approveReply.value : method == "channels.pairing.list" ? result.value : ["requestId": "b", "senderId": "4411"]
    }
    await actions.load()
    check(actions.canManage && actions.canBootstrapCommandOwner, "admin can manage and bootstrap the command owner")
    let a = actions.requests.first { $0.requestId == "a" }!
    let approved = await actions.approve(a, notify: true, makeCommandOwner: false)
    check(approved && calls.last?.0 == "channels.pairing.approve" && calls.last?.1["notify"] == true
          && calls.last?.1["bootstrapCommandOwner"] == nil && !actions.requests.contains { $0.requestId == "a" }
          && actions.notice == nil, "approve removes the row, silent when notified")
    approveReply.value = ["requestId": "c", "senderId": "4411", "notification": "failed", "commandOwnerBootstrap": "configured"]
    let c = actions.requests.first { $0.requestId == "c" }!
    await actions.approve(c, notify: true, makeCommandOwner: true)
    check(calls.last?.1["bootstrapCommandOwner"] == true && actions.notice?.text == "Approved, but the sender couldn't be notified."
          && !actions.canBootstrapCommandOwner, "notification failure notice; command owner now configured")
    approveReply.value = ["requestId": "x", "senderId": "4411", "notification": "unsupported", "commandOwnerBootstrap": "unavailable"]
    actions.clearNotice()
    result.value = listResult([requestJSON("x", created: -60), requestJSON("b", created: -120)])
    await actions.load()
    await actions.approve(actions.requests.first { $0.requestId == "x" }!)
    check(actions.notice?.text == "Approved, but they couldn't be made the command owner.", "command owner unavailable notice")
    let b = actions.requests.first { $0.requestId == "b" }!
    let dismissed = await actions.dismiss(b)
    check(dismissed && calls.last?.0 == "channels.pairing.dismiss" && calls.last?.1 == PairingInboxModel.dismissParams(b)
          && actions.requests.isEmpty && actions.pendingCount() == 0, "dismiss removes the row")

    // Stale, not-pairing and other errors.
    actions.clearNotice()
    result.value = listResult([requestJSON("stale", created: -60), requestJSON("keep", created: -120)])
    await actions.load()
    result.value = listResult([requestJSON("keep", created: -120)])
    failure.value = .rpc(code: "INVALID_REQUEST", message: "pending DM access request no longer exists", details: nil)
    let listsBefore = calls.filter { $0.0 == "channels.pairing.list" }.count
    let staleGone = await actions.approve(actions.requests.first { $0.requestId == "stale" }!)
    check(staleGone && !actions.requests.contains { $0.requestId == "stale" } && actions.notice?.text == PairingInboxModel.staleMessage
          && calls.filter { $0.0 == "channels.pairing.list" }.count == listsBefore + 1, "stale request removed with a notice, then refreshed")
    failure.value = .rpc(code: "INVALID_REQUEST", message: "channel account does not use DM pairing: telegram:home", details: nil)
    await actions.dismiss(actions.requests.first!)
    check(actions.notice?.text == "channel account does not use DM pairing: telegram:home"
          && calls.last?.0 == "channels.pairing.list", "not-pairing error refreshes and shows the gateway's message")
    failure.value = .rpc(code: "UNAVAILABLE", message: "pairing store unavailable", details: nil)
    let keep = actions.requests.first { $0.requestId == "keep" }!
    let failed = await actions.approve(keep)
    check(!failed && actions.requests.contains { $0.id == keep.id } && actions.operation(for: keep).error == "pairing store unavailable",
          "other errors keep the row with the error")
    failure.value = .rpc(code: "FORBIDDEN", message: "missing scope: operator.admin",
                   details: ["code": "MISSING_SCOPE", "missingScope": "operator.admin", "requiredScopes": ["operator.admin"]])
    await actions.approve(keep, makeCommandOwner: true)
    check(actions.operation(for: keep).error == PairingInboxModel.commandOwnerScopeMessage && !actions.needsAccess,
          "admin scope refusal on approve stays on the row")
    failure.value = nil
    let retried = await actions.approve(keep)
    check(retried && actions.requests.isEmpty && actions.operation(for: keep) == .idle, "retry after an error")

    // A poll never replaces a row whose action is in flight.
    var releaseApprove: CheckedContinuation<Void, Never>?
    result.value = listResult([requestJSON("busy", sender: "1", created: -60), requestJSON("idle", created: -120)])
    let slow = PairingInboxModel { method, _ in
        if method == "channels.pairing.approve" {
            await withCheckedContinuation { releaseApprove = $0 }
            return ["requestId": "busy", "senderId": "1", "notification": "not-requested", "commandOwnerBootstrap": "not-requested"]
        }
        return result.value
    }
    await slow.load()
    let busy = slow.requests.first { $0.requestId == "busy" }!
    let approving = Task { await slow.approve(busy) }
    _ = await waitFor("approve in flight", timeout: 2) { releaseApprove != nil }
    let duplicate = await slow.approve(busy)
    check(!duplicate && slow.operation(for: busy).isRunning, "no duplicate send while in flight")
    result.value = listResult([requestJSON("idle", created: -120, extra: #","accountLabel":"Renamed""#)])
    await slow.poll()
    check(slow.requests.contains { $0.id == busy.id } && slow.requests.first { $0.requestId == "idle" }?.accountLabel == "Renamed",
          "poll keeps the in-flight row, updates the rest")
    releaseApprove?.resume()
    _ = await approving.value
    check(!slow.requests.contains { $0.id == busy.id } && slow.requests.count == 1, "approved row leaves once the action finishes")

    // A list that was already on its way when an approve finished doesn't bring the row back.
    var releaseList: CheckedContinuation<Void, Never>?
    let holdList = Scripted(false)
    result.value = listResult([requestJSON("race", created: -60), requestJSON("other", created: -120)])
    let racing = PairingInboxModel { method, _ in
        if method == "channels.pairing.list", holdList.value {
            let snapshot = result.value
            await withCheckedContinuation { releaseList = $0 }
            return snapshot
        }
        if method == "channels.pairing.list" { return result.value }
        return ["requestId": "race", "senderId": "4411", "notification": "not-requested", "commandOwnerBootstrap": "not-requested"]
    }
    await racing.load()
    let race = racing.requests.first { $0.requestId == "race" }!
    holdList.value = true
    let polling = Task { await racing.poll() }
    _ = await waitFor("poll in flight", timeout: 2) { releaseList != nil }
    let raced = await racing.approve(race)
    check(raced && !racing.requests.contains { $0.id == race.id }, "approve during a poll removes the row")
    releaseList?.resume()
    await polling.value
    check(!racing.requests.contains { $0.id == race.id } && racing.requests.map(\.requestId) == ["other"] && racing.pendingCount() == 1,
          "a poll started before the approve finished doesn't resurrect the row (\(racing.requests.map(\.requestId)))")
    holdList.value = false
    await racing.refresh()
    check(racing.requests.map(\.requestId) == ["race", "other"], "a later list shows the row again if the Gateway still has it")

    // Expired rows: approve sends nothing, dismiss still works, the badge leaves them out.
    calls = []
    result.value = listResult([requestJSON("late", created: -3700, expires: -5), requestJSON("fresh", created: -60)])
    let expiring = PairingInboxModel { method, params in
        calls.append((method, params))
        return method == "channels.pairing.list" ? result.value : ["requestId": "late", "senderId": "4411"]
    }
    await expiring.load()
    let late = expiring.requests.first { $0.requestId == "late" }!
    check(expiring.pendingCount(at: now) == 1 && expiring.requests.count == 2, "expired row listed but not counted")
    let lateApproved = await expiring.approve(late)
    check(!lateApproved && !calls.contains { $0.0 == "channels.pairing.approve" } && expiring.operation(for: late) == .idle
          && expiring.notice?.text == PairingInboxModel.expiredMessage,
          "approving an expired request sends nothing and says it expired")
    let lateDismissed = await expiring.dismiss(late)
    check(lateDismissed && calls.last?.0 == "channels.pairing.dismiss" && expiring.requests.map(\.requestId) == ["fresh"],
          "an expired request can still be dismissed")
    let soon = PairingRequest(requestJSON("soon", created: -3500, expires: 100))!
    check(!soon.isExpired(at: now) && soon.isExpired(at: now.addingTimeInterval(101)), "rows expire as time passes")

    // Stale on dismiss too, and the gateway's own not-pairing message kept verbatim.
    calls = []
    result.value = listResult([requestJSON("s2", created: -60)])
    let staleDismiss = PairingInboxModel { method, params in
        calls.append((method, params))
        if method == "channels.pairing.dismiss" {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "Pending DM access request no longer exists", details: nil)
        }
        return method == "channels.pairing.list" ? result.value : [:]
    }
    await staleDismiss.load()
    result.value = listResult([])
    let staleDismissed = await staleDismiss.dismiss(staleDismiss.requests[0])
    check(staleDismissed && staleDismiss.requests.isEmpty && staleDismiss.notice?.text == PairingInboxModel.staleMessage
          && calls.map(\.0) == ["channels.pairing.list", "channels.pairing.dismiss", "channels.pairing.list"],
          "stale dismiss (any case) removes the row, shows a notice and refreshes")
    let otherInvalid = PairingInboxModel { method, _ in
        if method == "channels.pairing.approve" { throw GatewayError.rpc(code: "INVALID_REQUEST", message: "invalid channels.pairing.approve params", details: nil) }
        return listResult([requestJSON("v", created: -60)])
    }
    await otherInvalid.load()
    let v = otherInvalid.requests[0]
    await otherInvalid.approve(v)
    check(otherInvalid.requests.count == 1 && otherInvalid.operation(for: v).error == "invalid channels.pairing.approve params"
          && otherInvalid.notice == nil, "other INVALID_REQUEST errors stay on the row")

    // Scopes, access and unsupported gateways.
    var requested = false
    let noScope = PairingInboxModel(scopes: { ["operator.read", "operator.write", "operator.approvals", "operator.questions"] }) { _, _ in
        requested = true
        return listResult([])
    }
    await noScope.load()
    await noScope.seed()
    check(!noScope.canManage && noScope.needsAccess && !requested && noScope.pendingCount() == 0, "no pairing scope → access needed, no request")
    check(PairingInboxModel(scopes: { ["operator.pairing"] }) { _, _ in [:] }.canManage
          && PairingInboxModel(scopes: { ["operator.admin"] }) { _, _ in [:] }.canManage, "operator.pairing or operator.admin can manage")
    check(!PairingInboxModel(scopes: { ["operator.pairing"] }) { _, _ in [:] }.canBootstrapCommandOwner, "command owner needs admin")
    let denied = PairingInboxModel { _, _ in
        throw GatewayError.rpc(code: "FORBIDDEN", message: "missing scope: operator.pairing",
                               details: ["code": "MISSING_SCOPE", "missingScope": "operator.pairing", "requiredScopes": ["operator.pairing"]])
    }
    await denied.load()
    check(denied.needsAccess && denied.loadState.error == PairingInboxModel.missingScopeMessage
          && PairingInboxModel.missingScopeMessage.contains("Full Management") && !PairingInboxModel.missingScopeMessage.contains("operator.approvals"),
          "MISSING_SCOPE reply → Full Management message")
    requested = false
    let legacyHello = PairingInboxModel(methods: { ["chat.send", "approval.history"] }) { _, _ in
        requested = true
        return listResult([])
    }
    await legacyHello.load()
    check(!legacyHello.supported && !requested && legacyHello.pendingCount() == 0, "hello without channels.pairing.list → unsupported, no request")
    let unknown = PairingInboxModel(methods: { [] }) { method, _ in
        throw GatewayError.rpc(code: "INVALID_REQUEST", message: "unknown method: \(method)", details: nil)
    }
    await unknown.load()
    check(!unknown.supported && unknown.hasLoaded && unknown.loadState == .idle, "unknown-method error → unsupported, no error")
    check(PairingInboxModel(methods: { ["channels.pairing.list"] }) { _, _ in [:] }.supported, "advertised list is supported")
    var seeds = 0
    let seeded = PairingInboxModel(methods: { ["channels.pairing.list"] }) { _, _ in
        seeds += 1
        return listResult([requestJSON("s", created: -60)])
    }
    await seeded.seed()
    await seeded.seed()
    check(seeds == 1 && seeded.pendingCount() == 1, "seed lists once for the badge")
    let broken = PairingInboxModel { _, _ in throw GatewayError.rpc(code: "UNAVAILABLE", message: "pairing store unavailable", details: nil) }
    await broken.load()
    check(broken.loadState.error == "pairing store unavailable" && broken.supported && !broken.needsAccess, "load failure shows the message")
    let flaky = Scripted(false)
    let keeps = PairingInboxModel { _, _ in
        if flaky.value { throw GatewayError.rpc(code: "UNAVAILABLE", message: "down", details: nil) }
        return listResult([requestJSON("k", created: -60)])
    }
    await keeps.load()
    flaky.value = true
    await keeps.refresh()
    check(keeps.requests.count == 1 && keeps.loadState.error == "down", "failed refresh keeps the last list")

    // More scope and unsupported shapes.
    let bareForbidden = PairingInboxModel { _, _ in throw GatewayError.rpc(code: "FORBIDDEN", message: "forbidden: requires operator.pairing", details: nil) }
    await bareForbidden.load()
    check(bareForbidden.needsAccess && bareForbidden.loadState.error == PairingInboxModel.missingScopeMessage, "FORBIDDEN naming a scope → access needed")
    let revoked = Scripted(false)
    let revokedModel = PairingInboxModel { _, _ in
        if revoked.value {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "missing scope: operator.pairing",
                                   details: ["code": "MISSING_SCOPE", "missingScope": "operator.pairing"])
        }
        return listResult([requestJSON("r", created: -60)])
    }
    await revokedModel.load()
    check(revokedModel.pendingCount() == 1, "badge before the scope went away")
    revoked.value = true
    await revokedModel.refresh()
    check(revokedModel.needsAccess && revokedModel.pendingCount() == 0, "details.code MISSING_SCOPE → access needed, badge hidden")
    revoked.value = false
    await revokedModel.refresh()
    check(!revokedModel.needsAccess && revokedModel.pendingCount() == 1, "access comes back after a successful list")
    let vanished = Scripted(false)
    let vanishedModel = PairingInboxModel(methods: { [] }) { method, _ in
        if vanished.value { throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: \(method)", details: nil) }
        return listResult([requestJSON("u", created: -60)])
    }
    await vanishedModel.load()
    vanished.value = true
    await vanishedModel.refresh()
    check(!vanishedModel.supported && vanishedModel.requests.isEmpty && vanishedModel.accounts.isEmpty && vanishedModel.pendingCount() == 0
          && vanishedModel.loadState == .idle, "UNKNOWN_METHOD (mock shape) → unsupported, list and badge cleared")
    var sentWhenUnsupported = 0
    let unsupportedSeed = PairingInboxModel(methods: { ["chat.send"] }, scopes: { ["operator.admin"] }) { _, _ in
        sentWhenUnsupported += 1
        return listResult([])
    }
    await unsupportedSeed.seed()
    await unsupportedSeed.poll()
    check(sentWhenUnsupported == 0 && unsupportedSeed.pendingCount() == 0, "seed and poll send nothing when unsupported")
    let pairingOnly = PairingInboxModel(scopes: { ["operator.pairing"] }) { _, _ in listResult([], owner: false) }
    await pairingOnly.load()
    check(!pairingOnly.commandOwnerConfigured && !pairingOnly.canBootstrapCommandOwner, "no command owner, but operator.pairing can't bootstrap")
    let adminOwner = PairingInboxModel(scopes: { ["operator.admin"] }) { _, _ in listResult([], owner: true) }
    await adminOwner.load()
    check(!adminOwner.canBootstrapCommandOwner, "admin isn't offered bootstrap when a command owner exists")
    let accountsOnly = PairingInboxModel { _, _ in listResult([]) }
    await accountsOnly.load()
    check(accountsOnly.accounts.count == 2 && accountsOnly.requests.isEmpty && accountsOnly.pendingCount() == 0
          && PairingInboxModel(scopes: { ["operator.pairing"] }) { _, _ in [:] }.pendingCount() == 0, "accounts without requests")
    let empty = PairingInboxModel { _, _ in ["accounts": [], "requests": [], "commandOwnerConfigured": true] }
    await empty.load()
    check(empty.hasLoaded && empty.accounts.isEmpty && empty.limits == nil && empty.loadState == .idle, "no pairing accounts, no limits")
    let lenient = PairingInboxModel { _, _ in
        ["accounts": [["channel": "x"], ["channel": "telegram", "accountId": "home"]],
         "requests": [["requestId": "only"], requestJSON("ok", created: -60), requestJSON("ok", created: -60)]]
    }
    await lenient.load()
    check(lenient.accounts.map(\.id) == ["telegram:home"] && lenient.requests.map(\.requestId) == ["ok"]
          && lenient.accounts.first?.notifySupported == false && lenient.limits == nil, "lenient parsing skips bad rows and duplicates")
}
