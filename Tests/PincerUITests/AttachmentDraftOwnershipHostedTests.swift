#if os(iOS)
import Foundation
import ImageIO
import CoreGraphics
import SwiftUI
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import PincerKit
@testable import PincerUI

/// Calls the real field's installed media callback, then its actual hardware Return selector.
/// Native pasteboard extraction is outside this fixture; no shared clipboard is changed.
@MainActor
private struct AttachmentDraftOwnershipFixture {
    private final class HeldProvider: @unchecked Sendable {
        private let lock = NSLock()
        private var callback: ((Data?, (any Error)?) -> Void)?
        var entered: Bool {
            self.lock.lock(); defer { self.lock.unlock() }
            return self.callback != nil
        }
        func hold(_ callback: @escaping (Data?, (any Error)?) -> Void) {
            self.lock.lock(); self.callback = callback; self.lock.unlock()
        }
        func release(_ data: Data?) {
            self.lock.lock(); let callback = self.callback; self.callback = nil; self.lock.unlock()
            callback?(data, nil)
        }
    }

    @MainActor
    private final class Host {
        let scratch = ScratchDefaults()
        let app: AppModel
        let gateway: GatewayStore
        let chat: ChatStore
        let controller: UIHostingController<AnyView>
        let window: UIWindow

        init(connectedDemo: Bool = false) {
            self.app = AppModel(defaults: self.scratch.defaults)
            self.gateway = GatewayStore(profile: connectedDemo ? .demo() : GatewayProfile(id: UUID(), name: "Attachment ownership", url: "ws://127.0.0.1:1", authMode: .none),
                                        defaults: self.scratch.defaults, identity: UIFixtures.identity())
            self.gateway.cacheRoot = nil
            self.gateway.outboxRoot = nil
            self.gateway.notifier = nil
            self.chat = ChatStore(sessionKey: connectedDemo ? "agent:main:main" : "agent:main:attachment-ownership", agentId: "main", gateway: self.gateway, headless: true)
            self.chat.draft.text = "Original attachment draft"
            self.controller = UIHostingController(rootView: AnyView(EmptyView()))
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                self.window = UIWindow(windowScene: scene)
                self.window.frame = CGRect(x: 0, y: 0, width: 430, height: 800)
            } else { self.window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 800)) }
            self.show(self.chat)
            self.window.rootViewController = self.controller
            self.window.makeKeyAndVisible()
            self.controller.loadViewIfNeeded()
            self.controller.view.frame = self.window.bounds
            self.controller.view.layoutIfNeeded()
        }

        func show(_ chat: ChatStore) {
            self.controller.rootView = AnyView(VStack {
                Spacer()
                Composer(chat: chat, placeholder: "Message").id(chat.sessionKey)
            }.environment(self.app).environment(self.gateway).defaultAppStorage(self.scratch.defaults))
        }

        func wait(_ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !predicate() {
                try Task.checkCancellation()
                try #require(ContinuousClock.now < deadline, "Actual composer/provider pipeline did not settle")
                self.controller.view.setNeedsLayout()
                self.controller.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        func field() async throws -> ComposerUITextView {
            var field: ComposerUITextView?
            func find(_ view: UIView) -> ComposerUITextView? {
                if let field = view as? ComposerUITextView { return field }
                return view.subviews.lazy.compactMap(find).first
            }
            try await self.wait {
                field = find(self.controller.view)
                return field?.text == self.chat.draft.text && field?.canSubmit == true
            }
            let result = try #require(field)
            try #require(result.becomeFirstResponder())
            try #require(result.isFirstResponder)
            return result
        }

        func stop() {
            self.window.endEditing(true)
            self.window.isHidden = true
            self.window.rootViewController = nil
            self.gateway.stop()
            self.scratch.remove()
        }
    }

    private func image() async throws -> Data {
        try await Task.detached {
            let pixels = Data([UInt8](repeating: 180, count: 16 * 16 * 4))
            let provider = try #require(CGDataProvider(data: pixels as CFData))
            let image = try #require(CGImage(width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let output = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            try #require(CGImageDestinationFinalize(destination))
            return output as Data
        }.value
    }

    func run(send: Bool, switchChat: Bool = false, discardWithFailure: Bool = false, failThenRetry: Bool = false) async throws {
        let source = try await self.image()
        let host = Host(connectedDemo: send)
        let held = HeldProvider()
        defer { held.release(nil); host.stop() }
        if send {
            host.gateway.start()
            try await host.wait {
                host.gateway.state.isConnected && host.gateway.bootstrapped && host.gateway.sessions[host.chat.sessionKey] != nil
            }
        }
        let field = try await host.field()
        let provider = NSItemProvider()
        provider.suggestedName = "held-ownership.png"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { callback in
            held.hold(callback)
            return Progress(totalUnitCount: 1)
        }
        let media = try #require(field.onMedia)
        media([.provider(provider)])
        try await host.wait { held.entered }
        #expect(host.chat.draft.text == "Original attachment draft" && host.chat.draft.attachments.isEmpty)
        #expect(!host.gateway.outbox.entries.contains { $0.sessionKey == host.chat.sessionKey })

        var other: ChatStore?
        if send {
            try await host.wait { !field.canSubmit }
            let command = try #require(field.keyCommands?.first { $0.input == "\r" && $0.modifierFlags.isEmpty })
            let action = try #require(command.action)
            try #require(field.responds(to: action))
            _ = field.perform(action, with: command)
            #expect(!host.gateway.outbox.entries.contains { $0.sessionKey == host.chat.sessionKey } && host.chat.items.isEmpty,
                    "Actual Return cannot submit an incomplete attachment draft")
            #expect(host.chat.draft.text == "Original attachment draft")
        } else if discardWithFailure {
            host.chat.draft = ComposerDraft(text: "Replacement draft")
        } else if switchChat {
            let replacement = ChatStore(sessionKey: "agent:main:other-attachment", agentId: "main", gateway: host.gateway, headless: true)
            replacement.draft.text = "Other chat draft"
            other = replacement
            host.show(replacement)
            func hasReplacementField(_ view: UIView) -> Bool {
                if let field = view as? ComposerUITextView { return field.text == "Other chat draft" }
                return view.subviews.contains(where: hasReplacementField)
            }
            try await host.wait { hasReplacementField(host.controller.view) }
        }

        // A sentinel on the same actual shared FIFO proves the held preparation and publication finished.
        let observer = AttachmentIngest(limits: host.gateway.uploadLimits, add: { _ in }, report: { _ in })
        var drained = false
        observer.imageQueue.submit(operation: { .failure("fixture drain") }, completion: { _ in drained = true })
        held.release(discardWithFailure || failThenRetry ? nil : source)
        try await host.wait { drained }
        if discardWithFailure {
            #expect(host.chat.draft.text == "Replacement draft" && host.chat.draft.attachments.isEmpty)
            #expect(host.chat.draftAttachmentPreparationError == nil && host.chat.draftAttachmentPreparationCount == 0,
                    "The old provider's real failure cannot publish into a new draft")
            return
        }
        if failThenRetry {
            #expect(host.chat.draftAttachmentPreparationCount == 0 && host.chat.draft.attachments.isEmpty)
            #expect(host.chat.draftAttachmentPreparationError?.isEmpty == false)
            let retry = NSItemProvider()
            retry.suggestedName = "held-ownership.png"
            retry.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { callback in
                callback(source, nil)
                return Progress(totalUnitCount: 1)
            }
            // Refresh the real field callback after SwiftUI applied the failure state.
            let retryField = try await host.field()
            let retryMedia = try #require(retryField.onMedia)
            retryMedia([.provider(retry)])
            try await host.wait { host.chat.draft.attachments.count == 1 && host.chat.draftAttachmentPreparationCount == 0 }
            #expect(host.chat.draftAttachmentPreparationError == nil)
        }
        if send {
            try await host.wait { field.canSubmit && host.chat.draft.attachments.count == 1 }
            let prepared = try #require(host.chat.draft.attachments.first)
            #expect(prepared.isImage && !prepared.data.isEmpty)
            var reservations: [OutboxEntry] = []
            var reservedImageID: UUID?
            host.chat.replyPreparationDidReserve = { id in
                if let entry = host.gateway.outbox.entry(id: id) {
                    reservations.append(entry)
                    reservedImageID = host.gateway.outboxAttachments[id]?.first?.id
                }
            }
            defer { host.chat.replyPreparationDidReserve = nil }
            let command = try #require(field.keyCommands?.first { $0.input == "\r" && $0.modifierFlags.isEmpty })
            let action = try #require(command.action)
            try #require(field.canPerformAction(action, withSender: command) && field.responds(to: action))
            _ = field.perform(action, with: command)
            try await host.wait { reservations.count == 1 && host.chat.draft.isEmpty }
            let entry = try #require(reservations.first)
            #expect(entry.text == "Original attachment draft" && entry.sessionKey == host.chat.sessionKey)
            #expect(entry.hasAttachments && reservedImageID == prepared.id,
                    "The actual outbox reservation owns the exact prepared image")
            #expect(host.chat.items.contains { $0.plainText == entry.text && $0.blocks.count == 2 },
                    "The actual send reserves the original text and prepared image together")
            try await host.wait {
                host.gateway.outbox.entry(id: entry.id) == nil && host.chat.items.contains {
                    $0.idempotencyKey == entry.id && $0.outboxState == nil
                }
            }
            #expect(host.chat.errorMessage == nil, "The real Demo accepted the actual text-and-image send")
            #expect(reservations.count == 1 && host.chat.draft.attachments.isEmpty)
        } else if let other {
            #expect(other.draft.text == "Other chat draft" && other.draft.attachments.isEmpty)
            #expect(host.chat.draft.attachments.count == 1, "The accepted image remains owned by its original chat draft")
        } else {
            let attachment = try #require(host.chat.draft.attachments.first)
            #expect(host.chat.draft.attachments.count == 1 && attachment.fileName == "held-ownership.png")
            #expect(attachment.isImage && !attachment.data.isEmpty)
            #expect(host.chat.draft.text == "Original attachment draft" && host.gateway.outbox.entries.isEmpty)
        }
    }
}

extension TranscriptUIKitHostedTests {
    @Test(.timeLimit(.minutes(2))) func pendingAttachmentCannotLeakIntoDraftAfterActualReturnSend() async throws {
        try await AttachmentDraftOwnershipFixture().run(send: true)
    }
    @Test(.timeLimit(.minutes(2))) func pendingAttachmentPublishesToUnchangedActualComposerDraft() async throws {
        try await AttachmentDraftOwnershipFixture().run(send: false)
    }
    @Test(.timeLimit(.minutes(2))) func discardedDraftDoesNotReceiveOldProviderFailure() async throws {
        try await AttachmentDraftOwnershipFixture().run(send: false, discardWithFailure: true)
    }
    @Test(.timeLimit(.minutes(2))) func actualProviderFailureReleasesDraftForRetry() async throws {
        try await AttachmentDraftOwnershipFixture().run(send: false, failThenRetry: true)
    }
    @Test(.timeLimit(.minutes(2))) func pendingAttachmentKeepsOriginalChatOwnershipAfterComposerSwitch() async throws {
        try await AttachmentDraftOwnershipFixture().run(send: false, switchChat: true)
    }
}
#endif
