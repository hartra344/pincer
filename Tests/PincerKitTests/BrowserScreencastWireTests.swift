import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PincerKit

/// Builds screencast wire messages and real JPEGs for the browser tests.
enum BrowserFixtures {
    static func message(header: String, jpeg: Data) -> Data {
        let head = Data(header.utf8)
        var length = UInt32(head.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(head)
        out.append(jpeg)
        return out
    }

    static let header = #"{"url":"https://example.com/a","cssWidth":800,"cssHeight":600,"scrollX":0,"scrollY":12,"ts":1.5}"#

    /// A solid JPEG of the given pixel size.
    static func jpeg(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

struct BrowserScreencastWireTests {
    @Test func parsesAValidFrame() throws {
        let jpeg = BrowserFixtures.jpeg(width: 8, height: 6)
        let parsed = try BrowserScreencastWire.parse(BrowserFixtures.message(header: BrowserFixtures.header, jpeg: jpeg))
        #expect(parsed.jpeg == jpeg)
        #expect(parsed.header.url == "https://example.com/a")
        #expect(parsed.header.cssWidth == 800)
        #expect(parsed.header.cssHeight == 600)
    }

    @Test func decodesTheHeaderLeniently() throws {
        let parsed = try BrowserScreencastWire.parse(BrowserFixtures.message(header: "{}", jpeg: Data([1, 2, 3])))
        #expect(parsed.header.url == nil)
        #expect(parsed.header.cssWidth == nil)
        let odd = try BrowserScreencastWire.parse(BrowserFixtures.message(header: #"{"url":5,"cssWidth":"x","extra":true}"#, jpeg: Data([1])))
        #expect(odd.jpeg == Data([1]))
    }

    @Test func rejectsTruncatedInput() {
        #expect(throws: (any Error).self) { try BrowserScreencastWire.parse(Data()) }
        #expect(throws: (any Error).self) { try BrowserScreencastWire.parse(Data([0, 0])) }
        // Header length larger than the data.
        var data = BrowserFixtures.message(header: BrowserFixtures.header, jpeg: Data())
        data.removeLast(10)
        #expect(throws: (any Error).self) { try BrowserScreencastWire.parse(data) }
        var huge = UInt32(5000).bigEndian
        #expect(throws: (any Error).self) { try BrowserScreencastWire.parse(Data(bytes: &huge, count: 4) + Data("{}".utf8)) }
    }

    @Test func rejectsAnOversizedHeader() {
        let filler = String(repeating: "a", count: 64 * 1024 + 1)
        let header = #"{"url":""# + filler + #""}"#
        #expect(throws: (any Error).self) {
            try BrowserScreencastWire.parse(BrowserFixtures.message(header: header, jpeg: Data([1])))
        }
        var absurd = UInt32.max.bigEndian
        #expect(throws: (any Error).self) { try BrowserScreencastWire.parse(Data(bytes: &absurd, count: 4) + Data(count: 16)) }
    }

    @Test func rejectsAnOversizedFrame() {
        let big = Data(count: 8 * 1024 * 1024 + 1)
        #expect(throws: (any Error).self) {
            try BrowserScreencastWire.parse(BrowserFixtures.message(header: "{}", jpeg: big))
        }
    }

    @Test func rejectsInvalidHeaderJSON() {
        #expect(throws: (any Error).self) {
            try BrowserScreencastWire.parse(BrowserFixtures.message(header: "{not json", jpeg: Data([1])))
        }
    }

    @Test func parsesControlMessages() {
        let ready = BrowserScreencastWire.parseControl(#"{"type":"ready","targetId":"t1","url":"https://a.test","title":"A"}"#)
        #expect(ready == .ready(targetId: "t1", url: "https://a.test", title: "A"))
        let meta = BrowserScreencastWire.parseControl(#"{"type":"meta","url":"https://b.test","title":"B"}"#)
        #expect(meta == .meta(url: "https://b.test", title: "B"))
        if case .error = BrowserScreencastWire.parseControl(#"{"type":"error","message":"nope"}"#) {} else {
            Issue.record("an error message parses as .error")
        }
        #expect(BrowserScreencastWire.parseControl("not json") == nil)
        #expect(BrowserScreencastWire.parseControl(#"{"type":"mystery"}"#) == nil)
        #expect(BrowserScreencastWire.parseControl("") == nil)
    }
}
