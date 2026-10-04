import Foundation
@testable import PincerKit

private final class RawValidationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false
    private var main = false
    var hasStarted: Bool {
        self.condition.lock()
        defer { self.condition.unlock() }
        return self.started
    }
    var ranOnMain: Bool {
        self.condition.lock()
        defer { self.condition.unlock() }
        return self.main
    }
    func hold() {
        self.condition.lock()
        defer { self.condition.unlock() }
        self.started = true
        self.main = Thread.isMainThread
        guard !self.main else { return }
        let deadline = Date().addingTimeInterval(15)
        while !self.released {
            if !self.condition.wait(until: deadline) { break }
        }
    }
    func release() {
        self.condition.lock()
        self.released = true
        self.condition.broadcast()
        self.condition.unlock()
    }
}

private final class RawValidationObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var main = 0
    private var offMain = 0
    func record() {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.main + self.offMain < 16 else { return }
        if Thread.isMainThread { self.main += 1 } else { self.offMain += 1 }
    }
    func snapshot() -> (main: Int, offMain: Int) {
        self.lock.lock()
        defer { self.lock.unlock() }
        return (self.main, self.offMain)
    }
}

@MainActor
func runRawConfigEditorChecks() async {
    let draft = RawConfigEditorDraft()
    let observation = RawValidationObservation()
    draft.validationObserver = { observation.record() }
    draft.updateSnapshot("{value: 1}")
    await draft.waitForValidation()
    check(!draft.isEdited && !draft.validationPending && draft.validationError == nil,
          "the production raw editor loads its trusted baseline without unsaved intent")
    draft.edit("{value: 2}")
    check(draft.isEdited && draft.validationPending,
          "actual raw typing marks unsaved intent and pending validation")
    await draft.waitForValidation()
    check(!draft.validationPending && draft.validationError == nil,
          "actual JSON5 validation accepts the current edited revision")
    draft.edit("{")
    await draft.waitForValidation()
    check(!draft.validationPending && draft.validationError != nil,
          "actual raw validation reports invalid current JSON5")
    draft.edit("{value: 3}")
    draft.edit("{value: 4}")
    await draft.waitForValidation()
    check(draft.text == "{value: 4}" && !draft.validationPending && draft.validationError == nil,
          "the actual validator settles the latest raw edit")
    guard let admission = draft.beginSave() else {
        check(false, "validated edited raw text admits Save"); return
    }
    draft.edit("{value: 5}")
    draft.edit("{value: 4}")
    draft.updateSnapshot("{value:4}")
    draft.finishSave(admission: admission, acknowledgedRaw: "{value:4}")
    await draft.waitForValidation()
    check(draft.text == "{value: 4}" && draft.baseline == "{value:4}" && draft.isEdited,
          "raw A-to-B-to-A user intent survives acknowledgment while its baseline advances")
    let cleanDraft = RawConfigEditorDraft()
    cleanDraft.updateSnapshot("{value: 1}")
    cleanDraft.edit("{value: 2}")
    cleanDraft.edit("{value: 1}")
    await cleanDraft.waitForValidation()
    check(!cleanDraft.isEdited && !cleanDraft.validationPending && cleanDraft.beginSave() == nil,
          "typing back to the baseline becomes clean and does not admit unnecessary Save")
    cleanDraft.edit("{value: 3}")
    cleanDraft.revert()
    cleanDraft.updateSnapshot("{value: 4}")
    await cleanDraft.waitForValidation()
    check(cleanDraft.text == "{value: 4}" && cleanDraft.baseline == "{value: 4}" && !cleanDraft.isEdited,
          "Revert outside Save permits a subsequently loaded raw snapshot to replace the clean editor")

    let gate = RawValidationGate()
    defer { gate.release() }
    let changingBaseline = RawConfigEditorDraft()
    changingBaseline.updateSnapshot("{value: 1}")
    changingBaseline.validationObserver = { gate.hold() }
    changingBaseline.edit("{value: 2}")
    guard await waitFor("actual pending raw baseline comparison", { gate.hasStarted }) else {
        check(false, "the actual validator reaches its held worker boundary"); return
    }
    check(changingBaseline.validationPending && !gate.ranOnMain,
          "the current raw revision remains pending while its actual off-main worker is held")
    changingBaseline.updateSnapshot("{value: 2}")
    gate.release()
    await changingBaseline.waitForValidation()
    check(changingBaseline.text == "{value: 2}" && changingBaseline.baseline == "{value: 2}"
          && !changingBaseline.isEdited && !changingBaseline.validationPending,
          "a baseline change during validation compares against the latest actual baseline")
    let measured = observation.snapshot()
    check(measured.main == 0 && measured.offMain > 0,
          "actual raw JSON5 validation executes off-main rather than during editor body rendering")
}

@MainActor
private final class RawApplyResponseGate {
    var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func hold() async {
        self.entered = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if self.released || Task.isCancelled { continuation.resume() }
                else { self.continuation = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.release() }
        }
    }

    func release() {
        self.released = true
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume()
    }
}

@MainActor
func runDemoRawConfigEditorChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    guard await waitFor("raw editor Demo connection", timeout: 25, { gateway.state.isConnected && gateway.bootstrapped }) else {
        check(false, "raw editor checks connect to the actual Demo Gateway"); return
    }
    await gateway.settings.reloadConfig()
    guard let original = gateway.settings.snapshot?.raw else {
        check(false, "actual Demo config.get supplies the authored raw file"); return
    }
    var unauthorizedApplies = 0
    let unauthorized = GatewaySettingsModel(request: { method, params, timeout in
        if method == "config.apply" { unauthorizedApplies += 1 }
        return try await gateway.connection.request(method, params, timeout: timeout)
    }, scopes: { gateway.hello?.scopes ?? [] })
    await unauthorized.reloadConfig()
    let unauthorizedSaved = await unauthorized.saveRaw(original)
    check(gateway.hello?.scopes.contains(GatewayConnection.adminScope) == false,
          "the actual Demo hello remains non-admin")
    check(!unauthorizedSaved && unauthorizedApplies == 0
          && unauthorized.saveState == .failed(ConfigWriteError.adminRequired.message),
          "genuine Demo scopes reject raw Save before any config.apply request")
    // The remaining cases simulate an admin-authorized client through the existing model
    // dependency seam. The Demo hello is unchanged; all requests still reach the real Demo.
    for later in ["unchanged", "typing", "revert", "ABA"] {
        let gate = RawApplyResponseGate()
        let settings = GatewaySettingsModel(request: { method, params, timeout in
            let response = try await gateway.connection.request(method, params, timeout: timeout)
            // The real server has already accepted the exact request. Only client publication waits.
            if method == "config.apply" { await gate.hold() }
            return response
        }, scopes: { [GatewayConnection.adminScope] })
        await settings.reloadConfig()
        guard let loaded = settings.snapshot?.raw else {
            check(false, "actual Demo raw snapshot loads for \(later)"); return
        }
        let draft = RawConfigEditorDraft()
        draft.updateSnapshot(loaded)
        let path = ["mcp", "servers", "sentry", "enabled"]
        guard let configured = settings.savedValue(at: path)?.bool,
              let config = settings.snapshot?.config else {
            check(false, "actual seeded Sentry config is available for raw persistence"); return
        }
        let nextEnabled = !configured
        let admittedText = await Task.detached {
            config.setting(.bool(nextEnabled), at: path).prettyPrinted() + "\n"
        }.value
        draft.edit(admittedText)
        await draft.waitForValidation()
        guard !draft.validationPending && draft.validationError == nil else {
            check(false, "actual admitted Demo raw text validates before Save"); return
        }
        guard let admission = draft.beginSave() else {
            check(false, "validated actual Demo raw text admits Save"); return
        }
        var saveCompleted = false
        let pendingSave = Task {
            let saved = await settings.saveRaw(admittedText)
            saveCompleted = true
            return saved
        }
        defer { pendingSave.cancel(); gate.release() }
        guard await waitFor("held accepted Demo raw response", { gate.entered || saveCompleted }), gate.entered else {
            check(false, "actual config.apply reaches held response publication (save state: \(settings.saveState))"); return
        }
        switch later {
        case "typing": draft.edit(loaded + "\n// later local edit\n")
        case "revert": draft.revert()
        case "ABA": draft.edit(loaded + "\n// intermediate edit\n"); draft.edit(admittedText)
        default: break
        }
        let expected = draft.text
        gate.release()
        let saved = await pendingSave.value
        guard saved, let acknowledged = settings.snapshot?.raw else {
            check(false, "actual Demo config.apply and acknowledgment succeed for \(later)"); return
        }
        check(settings.savedValue(at: path)?.bool == nextEnabled,
              "actual config.apply persists the submitted raw Sentry value for \(later)")
        draft.updateSnapshot(acknowledged)
        draft.finishSave(admission: admission, acknowledgedRaw: acknowledged)
        await draft.waitForValidation()
        check(draft.baseline == acknowledged,
              "actual \(later) raw save advances baseline to the real acknowledged file")
        check(draft.text == (later == "unchanged" ? acknowledged : expected),
              "actual \(later) raw save preserves precisely post-admission editor intent")
        check(!draft.validationPending && draft.validationError == nil,
              "actual \(later) editor settles validation after acknowledgment")
    }
    let restoring = GatewaySettingsModel(request: { method, params, timeout in
        try await gateway.connection.request(method, params, timeout: timeout)
    }, scopes: { [GatewayConnection.adminScope] })
    await restoring.reloadConfig()
    let restored = await restoring.saveRaw(original)
    check(restored && restoring.snapshot?.raw == original,
          "the actual Demo raw file is restored through the explicit admin fixture's config.apply")
    if !restored { print("Raw editor Demo restoration failed: \(restoring.saveState)") }
}
