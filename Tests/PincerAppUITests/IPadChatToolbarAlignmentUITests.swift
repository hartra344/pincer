import XCTest

/// #1088: on iPad (regular width, sidebar visible) the chat header's trailing toolbar group (Runs, Browser,
/// branch, model, thinking level, Chat Options) must sit inside the navigation bar with every control
/// inside the window and the group's controls laid out in order, without overlapping each other.
@MainActor
final class IPadChatToolbarAlignmentUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    func testTrailingChatToolbarFitsInsideNavigationBar() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad-only layout (#1088)")
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["PINCER_KEYCHAIN"] = "memory"
        app.launchEnvironment["PINCER_DEV_NAMESPACE"] = "uitest1088-\(UUID().uuidString.prefix(8))"
        app.launch()

        let tryDemo = app.buttons["Try the Demo"].firstMatch
        if tryDemo.waitForExistence(timeout: 10) { tryDemo.tap() }

        let options = app.buttons["Chat Options"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 20), "the demo didn't open a chat")
        // Open the chats by deep link (PincerRoute): the sidebar may not show them without scrolling or expanding groups.
        let chats = [("agent:research:dashboard:launch-plan", "runs"), ("agent:main:dashboard:garden", "branch")]
        for (session, tag) in chats {
            self.open(session, in: app)
            if tag == "runs" {
                let runs = app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Runs'")).firstMatch
                XCTAssertTrue(runs.waitForExistence(timeout: 10), "the Runs button is in the chat header")
            }
            for (orientation, name) in [(UIDeviceOrientation.landscapeLeft, "landscape"), (.portrait, "portrait")] {
                XCUIDevice.shared.orientation = orientation
                sleep(2)
                self.check(app, name: "\(tag)-\(name)")
            }
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(1)
        }
    }

    /// Opens a demo chat through a `pincer://open` link.
    private func open(_ session: String, in app: XCUIApplication) {
        var link = URLComponents()
        link.scheme = "pincer"
        link.host = "open"
        link.queryItems = [URLQueryItem(name: "gateway", value: "demo"), URLQueryItem(name: "session", value: session)]
        app.open(link.url!)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "Pincer is in front after the link")
        XCTAssertTrue(app.buttons["Chat Options"].firstMatch.waitForExistence(timeout: 20), "chat options button did not appear")
        // The model and thinking pickers fill in after the catalog loads.
        _ = app.buttons["Thinking Level"].firstMatch.waitForExistence(timeout: 10)
        sleep(2)
    }

    private func check(_ app: XCUIApplication, name: String) {
        let window = app.windows.firstMatch.frame
        let shot = XCUIScreen.main.screenshot()
        let full = XCTAttachment(screenshot: shot)
        full.name = "app-ipad-\(name)"
        full.lifetime = .keepAlways
        add(full)

        let bar = app.navigationBars.containing(.button, identifier: "Chat Options").firstMatch
        // Narrow layouts (iPad mini portrait) can move Chat Options out of the accessibility navigation bar.
        guard bar.exists else {
            print("#1088 \(name): no navigation bar holds Chat Options; screenshot only")
            return
        }
        let barFrame = bar.frame
        var frames: [(String, CGRect)] = []
        for button in bar.buttons.allElementsBoundByIndex where button.exists {
            let frame = button.frame
            // SwiftUI menus expose an unlabeled inner button with the same frame as the labeled one.
            guard frame.width > 1, frame.height > 1, frame.minX > barFrame.minX + 60, !button.label.isEmpty,
                  !frames.contains(where: { $0.1 == frame }) else { continue }
            frames.append((button.label, frame))
        }
        frames.sort { $0.1.minX < $1.1.minX }
        let firstTrailing = frames.first?.1.minX ?? barFrame.maxX
        let title = bar.staticTexts.allElementsBoundByIndex
            .map(\.frame).first { $0.width > 1 && $0.maxX < firstTrailing && $0.minX > barFrame.minX + 50 }
        var report = "#1088 \(name) window=\(window) navigationBar=\(barFrame) title=\(title.map { "\($0)" } ?? "nil")\n"
        for (label, frame) in frames {
            report += "  \(label): \(frame) midY=\(frame.midY)\n"
        }
        let union = frames.reduce(CGRect.null) { $0.union($1.1) }
        report += "  trailingUnion=\(union) trailingMargin=\(window.maxX - union.maxX)\n"
        report += bar.debugDescription
        let text = XCTAttachment(string: report)
        text.name = "ipad-\(name)-frames"
        text.lifetime = .keepAlways
        add(text)
        print(report)

        XCTAssertTrue(frames.contains { $0.0 == "Chat Options" }, "Chat Options is in the trailing group (\(name))")
        XCTAssertTrue(frames.contains { $0.0 == "Model" }, "Model picker is in the trailing group (\(name))")
        for (label, frame) in frames {
            XCTAssertLessThanOrEqual(frame.maxX, window.maxX - 8, "\(label) stays clear of the window's trailing edge (\(name)): \(frame)")
            XCTAssertGreaterThanOrEqual(frame.minX, barFrame.minX, "\(label) stays inside the navigation bar (\(name)): \(frame)")
        }
        for (a, b) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(a.1.maxX, b.1.minX + 0.5, "\(a.0) and \(b.0) don't overlap (\(name)): \(a.1) vs \(b.1)")
        }
        if let title {
            for (label, frame) in frames {
                XCTAssertLessThanOrEqual(abs(frame.midY - title.midY), 2, "\(label) is vertically centred with the title (\(name)): \(frame) vs \(title)")
            }
        }
    }
}
