import XCTest

final class LastCheckedUITests: XCTestCase {
    @MainActor
    func testActualFixedSavedTimestampChangesRenderedLabel() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launch()
        let value = app.staticTexts.matching(identifier: "notification-last-checked-value")
        guard value.firstMatch.waitForExistence(timeout: 15), value.count == 1 else {
            XCTFail("Exactly one actual accessible settings value is required before qualification")
            return
        }
        let initial = value.element.label
        guard !initial.isEmpty, initial.contains("Up to date"), initial != "Up to date" else {
            XCTFail("The actual baseline must include both timestamp and result suffix")
            return
        }
        let predicate = NSPredicate { _, _ in
            value.count == 1 && !value.element.label.isEmpty
                && value.element.label.contains("Up to date") && value.element.label != "Up to date"
                && value.element.label != initial
        }
        let changed = expectation(for: predicate, evaluatedWith: nil)
        wait(for: [changed], timeout: 15)
        guard value.count == 1 else {
            XCTFail("Exactly one actual value must remain after qualification")
            return
        }
        XCTAssertTrue(value.element.label.contains("Up to date"))
        // No app/root/input replacement occurs between the two actual label observations.
    }
}
