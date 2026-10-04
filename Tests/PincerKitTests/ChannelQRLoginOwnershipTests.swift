#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Channel QR response ownership")
struct ChannelQRLoginOwnershipTests {
    enum Replacement: String, CaseIterable { case cancel, restart, reset }
    private static let oldQR = "data:image/png;base64,AQ=="
    private static let newQR = "data:image/png;base64,Ag=="
    private static let expired = "The login QR expired. Ask me to generate a new one."

    @MainActor
    private final class Delivery {
        var entered = false
        var cancellationObserved = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            self.entered = true
            // The transport result has already completed. Cancellation is observed,
            // but cannot revoke that value at this local response-delivery boundary.
            // The test always releases delivery in defer, including fence cancellation.
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if self.released { continuation.resume() }
                    else { self.continuation = continuation }
                }
            } onCancel: { Task { @MainActor in self.cancellationObserved = true } }
        }
        func release() {
            self.released = true
            let continuation = self.continuation
            self.continuation = nil
            continuation?.resume()
        }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        while !condition() { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test(.timeLimit(.minutes(2)), arguments: Replacement.allCases)
    func completedOldWaitCannotRestoreFailureAfterCancelOrReplacement(_ replacement: Replacement) async throws {
        let oldDelivery = Delivery()
        let newDelivery = Delivery()
        var starts = 0
        var waits = 0
        var oldReturned = false
        var callbacks = 0
        let controller = ChannelQRLoginController(request: { method, params in
            #expect(params["channel"] == "whatsapp" && params["accountId"] == "default")
            if method == "web.login.start" {
                starts += 1
                #expect(params["timeoutMs"] == JSONValue(ChannelQRLoginController.startTimeoutMs))
                #expect(params["force"] == .bool(starts > 1))
                return ["qrDataUrl": .string(starts == 1 ? Self.oldQR : Self.newQR), "message": "Scan this QR in WhatsApp → Linked Devices."]
            }
            try #require(method == "web.login.wait")
            waits += 1
            #expect(params["timeoutMs"] == JSONValue(ChannelQRLoginController.waitTimeoutMs))
            if waits == 1 {
                #expect(params["currentQrDataUrl"] == .string(Self.oldQR))
                let completed: JSONValue = ["connected": false, "message": .string(Self.expired)]
                await oldDelivery.wait()
                oldReturned = true
                return completed
            }
            #expect(params["currentQrDataUrl"] == .string(Self.newQR))
            await newDelivery.wait()
            return ["connected": false, "message": "Still waiting for the QR scan. Let me know when you’ve scanned it."]
        })
        controller.onLinked = { _ in callbacks += 1 }
        defer { controller.reset(); oldDelivery.release(); newDelivery.release() }
        controller.start(channel: "whatsapp", accountId: "default")
        try await self.waitFor { oldDelivery.entered }
        try #require(controller.state(channel: "whatsapp", accountId: "default") == .showing(qr: Data([1]), message: "Scan this QR in WhatsApp → Linked Devices."))
        let oldTask = try #require(controller.activeTaskForChecks(channel: "whatsapp", accountId: "default"))
        switch replacement {
        case .cancel: controller.cancel(channel: "whatsapp", accountId: "default")
        case .reset: controller.reset()
        case .restart:
            controller.start(channel: "whatsapp", accountId: "default", force: true)
            try await self.waitFor { newDelivery.entered }
            try #require(controller.state(channel: "whatsapp", accountId: "default") == .showing(qr: Data([2]), message: "Scan this QR in WhatsApp → Linked Devices."))
        }
        oldDelivery.release()
        await oldTask.value
        #expect(oldReturned, "The real controller task consumed the completed transport response")
        let expected: ChannelQRLoginState = replacement == .restart
            ? .showing(qr: Data([2]), message: "Scan this QR in WhatsApp → Linked Devices.") : .idle
        #expect(controller.state(channel: "whatsapp", accountId: "default") == expected,
                "A completed canceled wait cannot restore its obsolete expiration error")
        #expect(callbacks == 0)
        #expect(starts == (replacement == .restart ? 2 : 1) && waits == starts)
    }

    enum CurrentResult: String, CaseIterable { case expired, linked, stillWaiting }
    @Test(.timeLimit(.minutes(2)), arguments: CurrentResult.allCases)
    func currentResultsStillPublishAndRefresh(_ result: CurrentResult) async throws {
        var waits = 0
        var callbacks = 0
        let controller = ChannelQRLoginController(request: { method, _ in
            if method == "web.login.start" { return ["qrDataUrl": .string(Self.oldQR)] }
            try #require(method == "web.login.wait")
            waits += 1
            if result == .expired { return ["connected": false, "message": .string(Self.expired)] }
            if result == .stillWaiting && waits == 1 {
                return ["connected": false, "message": "Still waiting for the QR scan. Let me know when you’ve scanned it."]
            }
            return ["connected": true, "message": "WhatsApp is linked."]
        })
        controller.onLinked = { key in
            #expect(key == ChannelAccountKey(channel: "whatsapp", accountId: "default"))
            callbacks += 1
        }
        defer { controller.reset() }
        controller.start(channel: "whatsapp", accountId: "default")
        try await self.waitFor {
            !controller.state(channel: "whatsapp", accountId: "default").isRunning
                && (result == .expired || callbacks == 1)
        }
        #expect(controller.state(channel: "whatsapp", accountId: "default") == (result == .expired ? .failed(Self.expired) : .connected("WhatsApp is linked.")))
        #expect(callbacks == (result == .expired ? 0 : 1))
        #expect(waits == (result == .stillWaiting ? 2 : 1))
    }
    enum LateDelivery: String, CaseIterable { case startQR, startError, waitError, waitLinked }
    @Test(.timeLimit(.minutes(2)), arguments: LateDelivery.allCases)
    func cancellationAlsoGuardsStartErrorsAndLinkedCallbacks(_ deliveryKind: LateDelivery) async throws {
        let delivery = Delivery()
        var returned = false
        var callbacks = 0
        let controller = ChannelQRLoginController(request: { method, _ in
            if method == "web.login.start" && (deliveryKind == .waitError || deliveryKind == .waitLinked) {
                return ["qrDataUrl": .string(Self.oldQR)]
            }
            await delivery.wait()
            returned = true
            if deliveryKind == .startError || deliveryKind == .waitError {
                throw GatewayError.rpc(code: "UNAVAILABLE", message: "Login failed", details: nil)
            }
            return deliveryKind == .startQR ? ["qrDataUrl": .string(Self.oldQR)]
                : ["connected": true, "message": "WhatsApp is linked."]
        })
        controller.onLinked = { _ in callbacks += 1 }
        defer { controller.reset(); delivery.release() }
        controller.start(channel: "whatsapp", accountId: "default")
        try await self.waitFor { delivery.entered }
        let activeTask = try #require(controller.activeTaskForChecks(channel: "whatsapp", accountId: "default"))
        controller.cancel(channel: "whatsapp", accountId: "default")
        delivery.release()
        await activeTask.value
        #expect(returned)
        #expect(controller.state(channel: "whatsapp", accountId: "default") == .idle && callbacks == 0)
    }

    @Test(.timeLimit(.minutes(2)))
    func cancelAllRetainsFinishedAccountsAndSuppressesRunningResponses() async throws {
        let delivery = Delivery()
        var returned = false
        var callbacks = 0
        let controller = ChannelQRLoginController(request: { _, params in
            if params["accountId"] == "finished" { return ["connected": true, "message": "Linked"] }
            await delivery.wait()
            returned = true
            throw GatewayError.rpc(code: "UNAVAILABLE", message: "Old failure", details: nil)
        })
        controller.onLinked = { _ in callbacks += 1 }
        defer { controller.reset(); delivery.release() }
        controller.start(channel: "whatsapp", accountId: "finished")
        try await self.waitFor { callbacks == 1 }
        controller.start(channel: "whatsapp", accountId: "running")
        try await self.waitFor { delivery.entered }
        let activeTask = try #require(controller.activeTaskForChecks(channel: "whatsapp", accountId: "running"))
        controller.cancelAll()
        delivery.release()
        await activeTask.value
        #expect(returned)
        #expect(controller.state(channel: "whatsapp", accountId: "finished") == .connected("Linked"))
        #expect(controller.state(channel: "whatsapp", accountId: "running") == .idle && callbacks == 1)
    }

    @Test(.timeLimit(.minutes(2)))
    func oldLinkedCallbackCompletionCannotRemoveReplacementTask() async throws {
        let callback = Delivery()
        let replacementWait = Delivery()
        var starts = 0
        var callbackReturned = false
        let controller = ChannelQRLoginController(request: { method, _ in
            if method == "web.login.start" {
                starts += 1
                return starts == 1 ? ["connected": true, "message": "Linked"] : ["qrDataUrl": .string(Self.newQR)]
            }
            await replacementWait.wait()
            return ["connected": false, "message": .string(Self.expired)]
        })
        controller.onLinked = { _ in await callback.wait(); callbackReturned = true }
        defer { controller.reset(); callback.release(); replacementWait.release() }
        controller.start(channel: "whatsapp", accountId: "default")
        try await self.waitFor { callback.entered }
        let oldTask = try #require(controller.activeTaskForChecks(channel: "whatsapp", accountId: "default"))
        controller.start(channel: "whatsapp", accountId: "default", force: true)
        try await self.waitFor { replacementWait.entered }
        let newTask = try #require(controller.activeTaskForChecks(channel: "whatsapp", accountId: "default"))
        callback.release()
        await oldTask.value
        #expect(callbackReturned)
        controller.cancel(channel: "whatsapp", accountId: "default")
        try await self.waitFor { replacementWait.cancellationObserved }
        replacementWait.release()
        await newTask.value
        #expect(controller.state(channel: "whatsapp", accountId: "default") == .idle && starts == 2)
    }

}

#endif
