import XCTest

/// #1097: diagnostic screenshots of the fade behind the compact iPhone chat header (avatar + title pill) with dense
/// transcript content scrolled under it, in light and dark mode. Never compares pixels; skips unless run on an iPhone
/// with `PINCER_SHOT_DIR` set (pass `TEST_RUNNER_PINCER_SHOT_DIR=…` to xcodebuild, or use
/// `scripts/capture-compact-header.sh`).
@MainActor
final class CompactChatHeaderFadeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    override func tearDown() {
        XCUIDevice.shared.appearance = .light
    }

    func testCaptureCompactHeaderFade() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "compact iPhone header only (#1097)")
        let dirPath = ProcessInfo.processInfo.environment["PINCER_SHOT_DIR"] ?? ""
        try XCTSkipIf(dirPath.isEmpty, "set PINCER_SHOT_DIR to capture header screenshots")
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchEnvironment["PINCER_KEYCHAIN"] = "memory"
        app.launchEnvironment["PINCER_DEV_NAMESPACE"] = "uitest1097-\(UUID().uuidString.prefix(8))"
        app.launch()

        let tryDemo = app.buttons["Try the Demo"].firstMatch
        if tryDemo.waitForExistence(timeout: 10) { tryDemo.tap() }
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 20), "the demo chat list did not appear")

        // The long home-lab chat (DemoGateway+LongChat.swift): paragraphs, lists and a bash code block.
        self.open("agent:main:dashboard:lab-migration", in: app)
        let title = app.descendants(matching: .any)["compact-chat-header-title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 20), "the compact chat header title is missing")
        sleep(2)
        let pill = title.frame

        // Each target row is dragged so its body (below the sender line) or its code block starts at the title pill's
        // top edge, or at the top of the screen for the dense one: the content then runs through the pill and the fade
        // band below it.
        let positions: [(name: String, text: String, offset: CGFloat)] = [
            ("paragraph", "The Dell idles at about 95 W", -50),
            ("code", "Here's a first version", -110),
            // Two long paragraphs whose text starts at the top of the screen, behind the status bar and the avatar,
            // and runs down past the pill.
            ("dense-paragraph", "Keep bulk data on the NAS", -(pill.minY + 40)),
        ]
        var report = "#1097 window=\(app.windows.firstMatch.frame) pill=\(pill)\n"
        for position in positions {
            let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", position.text)).firstMatch
            guard self.reveal(row, in: app) else {
                XCTFail("couldn't find the \(position.name) row (\(position.text))")
                continue
            }
            self.bring(row, toY: pill.minY + position.offset, in: app)
            report += "\(position.name): row=\(row.frame)\n"
            for (appearance, name) in [(XCUIDevice.Appearance.light, "light"), (.dark, "dark")] {
                XCUIDevice.shared.appearance = appearance
                sleep(2)
                try self.capture("\(name)-\(position.name)", to: dir)
            }
            XCUIDevice.shared.appearance = .light
            sleep(1)
        }
        try report.write(to: dir.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
        let text = XCTAttachment(string: report)
        text.name = "compact-header-frames"
        text.lifetime = .keepAlways
        add(text)
        print(report)
    }

    /// Opens a demo chat through a `pincer://open` link.
    private func open(_ session: String, in app: XCUIApplication) {
        var link = URLComponents()
        link.scheme = "pincer"
        link.host = "open"
        link.queryItems = [URLQueryItem(name: "gateway", value: "demo"), URLQueryItem(name: "session", value: session)]
        app.open(link.url!)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "Pincer is in front after the link")
    }

    /// Scrolls back through the transcript until `row` is loaded on screen.
    private func reveal(_ row: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<30 {
            if row.exists, row.frame.height > 1 { return true }
            self.drag(by: 320, in: app)
        }
        return row.exists
    }

    /// Slow drags (no fling) until the row's top edge is at `y`.
    private func bring(_ row: XCUIElement, toY y: CGFloat, in app: XCUIApplication) {
        let limit = app.windows.firstMatch.frame.height * 0.3
        for _ in 0..<8 {
            let delta = y - row.frame.minY
            // A drag shorter than the scroll view's touch slop turns into a long press and opens the message menu.
            if abs(delta) < 16 { break }
            self.drag(by: max(-limit, min(limit, delta)), in: app)
        }
        sleep(1)
    }

    private func drag(by dy: CGFloat, in app: XCUIApplication) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        start.press(forDuration: 0, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)),
                    withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    private func capture(_ name: String, to dir: URL) throws {
        let shot = XCUIScreen.main.screenshot()
        try shot.pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
