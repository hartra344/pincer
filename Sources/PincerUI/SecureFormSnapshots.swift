#if os(macOS)
import AppKit
import PincerKit
import SwiftUI

/// Renders the secure sign-in card (`SecureFormCardView`) to PNGs for review, light and dark, via a
/// real (offscreen, titled) window and `screencapture`, so materials and dynamic colors composite
/// the way they do on screen: `swift run PincerMacDev --secure-form-snapshots ~/Desktop/secure-form`.
/// Needs a running app (call from inside `PincerMacApp`'s run loop, not before it starts).
@MainActor
public enum SecureFormSnapshots {
    static let width: CGFloat = 420

    /// Writes one PNG per appearance. Returns how many files it wrote.
    public static func write(to directory: URL) async throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var count = 0
        for dark in [false, true] {
            if await self.render(dark: dark, to: directory.appending(path: "secure-form-\(dark ? "dark" : "light").png")) {
                count += 1
            }
        }
        return count
    }

    static let fixture: JSONValue = [
        "id": "ask_demo_secure_form",
        "kind": "secure_form",
        "requestId": "secure_demo",
        "origin": "mail.google.com",
        "fields": [["fieldId": "identifier", "role": "username"],
                    ["fieldId": "password", "role": "password"],
                    ["fieldId": "otp", "role": "otp"]],
        "agentId": "main",
        "sessionKey": "agent:main:demo",
        "runId": "run_demo",
        "createdAtMs": .number(0),
        "expiresAtMs": .number(9_999_999_999_999),
        "status": "pending",
    ]

    static func render(dark: Bool, to url: URL) async -> Bool {
        guard let prompt = QuestionPrompt(self.fixture) else { return false }
        let gateway = GatewayStore(profile: .demo())
        let card = SecureFormCardView(prompt: prompt, queued: 0)
            .environment(gateway)
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: self.width)
            .fixedSize(horizontal: false, vertical: true)
            .padding(24)
            .background(dark ? Color.black : Color.white)

        let hosting = NSHostingView(rootView: card)
        let fitting = hosting.fittingSize
        let size = CGSize(width: max(fitting.width, self.width), height: max(fitting.height, 200))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        window.contentView = hosting
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(400))

        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        var ok = false
        if (try? process.run()) != nil {
            process.waitUntilExit()
            ok = process.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path)
        }
        if !ok, let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            ok = (try? rep.representation(using: .png, properties: [:])?.write(to: url)) != nil
        }
        window.close()
        if ok { print("Wrote \(url.lastPathComponent)") }
        return ok
    }
}
#endif
