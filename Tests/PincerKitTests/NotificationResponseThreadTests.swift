import Foundation
import Testing
@preconcurrency import UserNotifications
@testable import PincerKit

/// #330: tapping a notification crashed the iOS app. UIKit's completion handler for
/// `didReceive` asserts it runs on the main thread (`-[UIApplication
/// _performBlockAfterCATransactionCommitSynchronizes:]`), but the `async` delegate method's
/// compiler-generated `@objc` thunk called it from the cooperative pool.
@MainActor
@Suite("Notification response thread (#330)")
struct NotificationResponseThreadTests {
    /// A tap on a reply notification, delivered by the system through the Objective-C entry point.
    private static func tapResponse(gateway: UUID, session: String) throws -> UNNotificationResponse {
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = Notifier.replyCategory
        content.userInfo = ["gateway": gateway.uuidString, "session": session]
        let request = UNNotificationRequest(identifier: "reply:\(session)", content: content, trigger: nil)
        let notification = try #require(
            (UNNotification.self as AnyObject)
                .perform(NSSelectorFromString("notificationWithRequest:date:"), with: request, with: Date())?
                .takeUnretainedValue() as? UNNotification)
        return try #require(
            (UNNotificationResponse.self as AnyObject)
                .perform(
                    NSSelectorFromString("responseWithNotification:actionIdentifier:"), with: notification,
                    with: UNNotificationDefaultActionIdentifier)?
                .takeUnretainedValue() as? UNNotificationResponse)
    }

    /// Calls the delegate the way UserNotifications does: via the Objective-C selector, from a
    /// background queue, before the app has installed its open handler (a cold launch, gateway
    /// not connected yet).
    private static func deliver(_ response: UNNotificationResponse, to notifier: Notifier) async -> Bool {
        let selector = NSSelectorFromString("userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:")
        typealias DidReceive = @convention(c) (
            AnyObject, Selector, AnyObject?, UNNotificationResponse, @escaping @convention(block) () -> Void
        ) -> Void
        let implementation = unsafeBitCast(notifier.method(for: selector), to: DidReceive.self)
        nonisolated(unsafe) let target = notifier
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                implementation(target, selector, nil, response) {
                    continuation.resume(returning: Thread.isMainThread)
                }
            }
        }
    }

    @Test func coldLaunchTapCompletesOnMainThreadAndOpensTheChatOnceRoutingIsReady() async throws {
        let notifier = Notifier()
        let gateway = UUID()
        let response = try Self.tapResponse(gateway: gateway, session: "agent:main:main")

        let completedOnMain = await Self.deliver(response, to: notifier)
        #expect(completedOnMain, "UIKit aborts when the didReceive completion handler runs off the main thread")

        var opened: [Notifier.Target] = []
        notifier.onOpen = { opened.append($0) }
        #expect(opened == [Notifier.Target(gatewayId: gateway, sessionKey: "agent:main:main")])
    }

    @Test func warmTapCompletesOnMainThreadAndOpensTheChat() async throws {
        let notifier = Notifier()
        var opened: [Notifier.Target] = []
        notifier.onOpen = { opened.append($0) }
        let gateway = UUID()
        let response = try Self.tapResponse(gateway: gateway, session: "agent:main:telegram")

        #expect(await Self.deliver(response, to: notifier))
        #expect(opened == [Notifier.Target(gatewayId: gateway, sessionKey: "agent:main:telegram")])
    }

    @Test func foregroundPresentationCompletesOnMainThread() async throws {
        let notifier = Notifier()
        let response = try Self.tapResponse(gateway: UUID(), session: "agent:main:main")
        let selector = NSSelectorFromString("userNotificationCenter:willPresentNotification:withCompletionHandler:")
        typealias WillPresent = @convention(c) (
            AnyObject, Selector, AnyObject?, UNNotification,
            @escaping @convention(block) (UNNotificationPresentationOptions) -> Void
        ) -> Void
        let implementation = unsafeBitCast(notifier.method(for: selector), to: WillPresent.self)
        nonisolated(unsafe) let target = notifier
        nonisolated(unsafe) let notification = response.notification
        let (onMain, options) = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                implementation(target, selector, nil, notification) {
                    continuation.resume(returning: (Thread.isMainThread, $0))
                }
            }
        }
        #expect(onMain)
        #expect(options == [.banner, .list, .sound])
    }

    @Test func unroutableTapStillCompletesOnMainThread() async throws {
        let notifier = Notifier()
        let content = UNMutableNotificationContent()
        let request = UNNotificationRequest(identifier: "x", content: content, trigger: nil)
        let notification = try #require(
            (UNNotification.self as AnyObject)
                .perform(NSSelectorFromString("notificationWithRequest:date:"), with: request, with: Date())?
                .takeUnretainedValue() as? UNNotification)
        let response = try #require(
            (UNNotificationResponse.self as AnyObject)
                .perform(
                    NSSelectorFromString("responseWithNotification:actionIdentifier:"), with: notification,
                    with: UNNotificationDefaultActionIdentifier)?
                .takeUnretainedValue() as? UNNotificationResponse)
        #expect(await Self.deliver(response, to: notifier))
    }
}
