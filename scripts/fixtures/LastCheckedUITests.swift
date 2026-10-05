import XCTest

final class LastCheckedUITests: XCTestCase {
    func testActualFixedSavedTimestampChangesRenderedLabel() throws {
        let app = XCUIApplication()
        app.launch()
        let value = app.staticTexts.matching(identifier: "notification-last-checked-value")
        XCTAssertTrue(value.firstMatch.waitForExistence(timeout: 15), "Actual settings value must be accessible")
        XCTAssertEqual(value.count, 1, "Exactly one actual rendered value is required")
        let initial = value.element.label
        XCTAssertFalse(initial.isEmpty)
        XCTAssertTrue(initial.contains("Up to date"))
        let predicate = NSPredicate { _, _ in
            value.count == 1 && !value.element.label.isEmpty
                && value.element.label.contains("Up to date") && value.element.label != initial
        }
        let changed = expectation(for: predicate, evaluatedWith: nil)
        wait(for: [changed], timeout: 15)
        XCTAssertEqual(value.count, 1)
        XCTAssertTrue(value.element.label.contains("Up to date"))
        // No app/root/input replacement occurs between the two actual label observations.
    }
}
