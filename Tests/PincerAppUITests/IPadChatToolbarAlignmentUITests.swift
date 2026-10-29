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

        // Chats reachable from the demo sidebar without expanding groups.
        for (chat, tag) in [("Main, Disk", "main"), ("Fix retry backoff", "working"), ("Home-lab migration", "homelab")] {
            guard self.open(chat, in: app) else { continue }
            for (orientation, name) in [(UIDeviceOrientation.landscapeLeft, "landscape"), (.portrait, "portrait")] {
                XCUIDevice.shared.orientation = orientation
                sleep(2)
                self.check(app, name: "\(tag)-\(name)")
            }
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(1)
        }
    }

    /// Opens a demo chat from the sidebar, scrolling the sidebar when its row is out of view.
    private func open(_ title: String, in app: XCUIApplication) -> Bool {
        let cell = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        _ = cell.waitForExistence(timeout: 10)
        let window = app.windows.firstMatch
        func drag(_ from: CGFloat, _ to: CGFloat) {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: from))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: to)))
        }
        for _ in 0..<4 where !cell.exists || !cell.isHittable { drag(0.8, 0.35) }
        for _ in 0..<6 where !cell.exists || !cell.isHittable { drag(0.35, 0.8) }
        guard cell.waitForExistence(timeout: 5) else {
            print("#1088 demo chat \(title) isn't in the sidebar; skipped")
            return false
        }
        let hittable = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: cell)
        if XCTWaiter().wait(for: [hittable], timeout: 10) == .completed { cell.tap() }
        else { cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        let options = app.buttons["Chat Options"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 20), "chat options button did not appear")
        // The model and thinking pickers fill in after the catalog loads.
        _ = app.buttons["Thinking Level"].firstMatch.waitForExistence(timeout: 10)
        sleep(2)
        return true
    }

    private func check(_ app: XCUIApplication, name: String) {
        let window = app.windows.firstMatch.frame
        let shot = XCUIScreen.main.screenshot()
        let full = XCTAttachment(screenshot: shot)
        let prefix = ProcessInfo.processInfo.environment["PINCER_SHOTS_PREFIX"].flatMap { $0.isEmpty ? nil : $0 } ?? "before"
        full.name = "\(prefix)-app-ipad-\(name)"
        full.lifetime = .keepAlways
        add(full)

        let bar = app.navigationBars.containing(.button, identifier: "Chat Options").firstMatch
        XCTAssertTrue(bar.exists, "chat navigation bar not found (\(name))")
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
