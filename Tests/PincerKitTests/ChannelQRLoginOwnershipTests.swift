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
        switch replacement {
        case .cancel: controller.cancel(channel: "whatsapp", accountId: "default")
        case .reset: controller.reset()
        case .restart:
            controller.start(channel: "whatsapp", accountId: "default", force: true)
            try await self.waitFor { newDelivery.entered }
            try #require(controller.state(channel: "whatsapp", accountId: "default") == .showing(qr: Data([2]), message: "Scan this QR in WhatsApp → Linked Devices."))
        }
        oldDelivery.release()
        // This marker is set immediately before request returns; controller publication
        // has no further suspension, so observing it observes the actual stale delivery.
        try await self.waitFor { oldReturned }
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
}
