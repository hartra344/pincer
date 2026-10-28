import XCTest

/// #1026: opening the workspace Browser sheet from a chat's "•••" menu and closing it must not leave a
/// "Browser" title stuck in the compact chat's navigation bar.
@MainActor
final class BrowserSheetHeaderUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testClosingBrowserSheetLeavesNoBrowserTitleInChatHeader() {
        let app = XCUIApplication()
        app.launchEnvironment["PINCER_KEYCHAIN"] = "memory"
        app.launchEnvironment["PINCER_DEV_NAMESPACE"] = "uitest1026"
        app.launch()

        let tryDemo = app.buttons["Try the Demo"].firstMatch
        if tryDemo.waitForExistence(timeout: 10) { tryDemo.tap() }

        let chat = app.cells.matching(NSPredicate(format: "label BEGINSWITH 'Main, '")).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 20), "demo chat list did not appear")
        chat.tap()

        let options = app.buttons["Chat Options"]
        XCTAssertTrue(options.waitForExistence(timeout: 20), "chat options button did not appear")
        attachHeader(app, named: "header before")

        // A loaded CI runner once took over 10s to show the sheet: the menu item existed while the menu
        // was still animating in, so the tap was dropped. Tap only once it's hittable, and reopen the
        // menu if it closed without presenting the sheet.
        let done = app.buttons["Done"]
        for attempt in 1...2 where !done.exists {
            XCTAssertTrue(waitForHittable(options, timeout: 30), "chat options button is not hittable")
            options.tap()
            let browserItem = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH 'Show Browser'"))
                .firstMatch
            XCTAssertTrue(waitForHittable(browserItem, timeout: 30), "Show Browser menu item did not appear")
            browserItem.tap()
            if done.waitForExistence(timeout: 30) { break }
            XCTAssertLessThan(attempt, 2, "Browser sheet did not open")
            attachHeader(app, named: "sheet missing after attempt \(attempt)")
        }
        XCTAssertTrue(done.exists, "Browser sheet did not open")
        done.tap()

        let sheetGone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: done)
        wait(for: [sheetGone], timeout: 30)
        XCTAssertTrue(options.waitForExistence(timeout: 20), "chat options button did not return after closing Browser sheet")

        // The stale title can take a moment to show, so give it a few seconds before asserting its absence.
        let browserTitle = app.navigationBars.staticTexts["Browser"]
        let appeared = browserTitle.waitForExistence(timeout: 3)
        attachHeader(app, named: "header after")
        XCTAssertFalse(appeared, "a stuck \"Browser\" title is in the nav bar")
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let hittable = expectation(for: NSPredicate(format: "exists == true AND hittable == true"), evaluatedWith: element)
        return XCTWaiter().wait(for: [hittable], timeout: timeout) == .completed
    }

    /// Kept only for diagnosis: the screenshots are attached to the result and never compared.
    private func attachHeader(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
