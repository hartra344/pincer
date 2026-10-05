import XCTest

final class LastCheckedUITests: XCTestCase {
    @MainActor
    func testActualFixedSavedTimestampChangesRenderedLabel() async throws {
        let app = XCUIApplication()
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
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        var changed = false
        while clock.now < deadline {
            try Task.checkCancellation()
            if value.count == 1 {
                let current = value.element.label
                if !current.isEmpty, current.contains("Up to date"), current != "Up to date", current != initial {
                    changed = true
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(changed, "The actual fixed-input timestamp must change within 15 seconds")
        guard value.count == 1 else {
            XCTFail("Exactly one actual value must remain after qualification")
            return
        }
        XCTAssertTrue(value.element.label.contains("Up to date"))
        // No app/root/input replacement occurs between the two actual label observations.
    }
}
