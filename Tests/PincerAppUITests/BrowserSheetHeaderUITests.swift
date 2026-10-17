import CoreGraphics
import XCTest

/// #1026: opening the workspace Browser sheet from a chat's "•••" menu and closing it must leave the
/// compact chat header (avatar + session pill) exactly as it was, with no "Browser" title stuck on it.
@MainActor
final class BrowserSheetHeaderUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testClosingBrowserSheetLeavesChatHeaderUntouched() throws {
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
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        let before = try headerImages(app)

        options.tap()
        let browserItem = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show Browser'")).firstMatch
        XCTAssertTrue(browserItem.waitForExistence(timeout: 5))
        browserItem.tap()

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "Browser sheet did not open")
        done.tap()
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        let sheetGone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: done)
        wait(for: [sheetGone], timeout: 10)

        let after = try headerImages(app)

        XCTAssertFalse(app.navigationBars.staticTexts["Browser"].exists, "a stuck \"Browser\" title is in the nav bar")
        let diff = zip(before, after).map { Self.differingFraction($0, $1) }.max() ?? 1
        XCTAssertLessThan(diff, 0.002, "chat header changed after closing the Browser sheet (\(diff * 100)% of pixels differ)")
    }

    /// The nav-bar strips left and right of the avatar, which idles with a small bob, so it can't be
    /// compared pixel for pixel. A stuck "Browser" title is wide enough to cover both strips. Waits until
    /// two consecutive captures agree so a still-settling header isn't compared.
    private func headerImages(_ app: XCUIApplication) throws -> [CGImage] {
        var last = try captureHeader(app)
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.5)
            let next = try captureHeader(app)
            if zip(last, next).allSatisfy({ Self.differingFraction($0, $1) < 0.0005 }) { return next }
            last = next
        }
        return last
    }

    private func captureHeader(_ app: XCUIApplication) throws -> [CGImage] {
        guard let full = app.screenshot().image.cgImage else { throw XCTSkip("no screenshot") }
        let w = CGFloat(full.width), h = CGFloat(full.height)
        return try [0.3, 0.6].map { x in
            try XCTUnwrap(full.cropping(to: CGRect(x: w * x, y: h * 0.07, width: w * 0.1, height: h * 0.065)))
        }
    }

    private static func differingFraction(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height else { return 1 }
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return data
        }
        let pa = pixels(a), pb = pixels(b)
        var differing = 0
        for i in stride(from: 0, to: pa.count, by: 4) {
            let d = abs(Int(pa[i]) - Int(pb[i])) + abs(Int(pa[i + 1]) - Int(pb[i + 1])) + abs(Int(pa[i + 2]) - Int(pb[i + 2]))
            if d > 48 { differing += 1 }
        }
        return Double(differing) / Double(a.width * a.height)
    }
}
