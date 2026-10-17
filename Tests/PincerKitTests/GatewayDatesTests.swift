import Foundation
import Testing
@testable import PincerKit

@Suite("Gateway dates and method support")
struct GatewayDatesTests {
    @Test func isoParsesFractionalAndPlain() {
        #expect(GatewayDates.iso("2026-01-02T03:04:05Z")?.timeIntervalSince1970 == 1_767_323_045)
        #expect(GatewayDates.iso("2026-01-02T03:04:05.500Z")?.timeIntervalSince1970 == 1_767_323_045.5)
        #expect(GatewayDates.iso("nope") == nil)
        #expect(GatewayDates.iso("") == nil)
    }

    @Test func isoStringRoundTripsWithFraction() {
        let date = Date(timeIntervalSince1970: 1_767_323_045.5)
        #expect(GatewayDates.isoString(date) == "2026-01-02T03:04:05.500Z")
        #expect(GatewayDates.iso(GatewayDates.isoString(date)) == date)
    }

    @Test func consumersKeepSemantics() {
        #expect(SessionBranch.date(.string("1500")) == Date(timeIntervalSince1970: 1.5))
        #expect(SessionBranch.date(.number(2000)) == Date(timeIntervalSince1970: 2))
        #expect(SessionBranch.date(.string("2026-01-02T03:04:05Z")) != nil)
        #expect(SessionBranch.date(.bool(true)) == nil)
    }

    @Test func epochMillisGuards() {
        #expect(JSONValue.number(1500).epochMillisDate() == Date(timeIntervalSince1970: 1.5))
        #expect(JSONValue.string("1500").epochMillisDate() == Date(timeIntervalSince1970: 1.5))
        #expect(JSONValue.number(0).epochMillisDate() == Date(timeIntervalSince1970: 0))
        #expect(JSONValue.number(0).epochMillisDate(positiveOnly: true) == nil)
        #expect(JSONValue.number(-5).epochMillisDate(positiveOnly: true) == nil)
        #expect(JSONValue.number(.infinity).epochMillisDate(requireFinite: true) == nil)
        #expect(JSONValue.number(.nan).epochMillisDate(positiveOnly: true) == nil)
        #expect(JSONValue.bool(true).epochMillisDate() == nil)
        #expect(JSONValue.string("x").epochMillisDate() == nil)
    }

    @Test func methodSupportMatrix() {
        #expect(GatewayMethodSupport.supports("a", advertised: nil))
        #expect(GatewayMethodSupport.supports("a", advertised: []))
        #expect(GatewayMethodSupport.supports("a", advertised: ["a"]))
        #expect(!GatewayMethodSupport.supports("a", advertised: ["b"]))
        #expect(!GatewayMethodSupport.supports("a", advertised: nil, rejected: ["a"]))
        #expect(!GatewayMethodSupport.supports("a", advertised: ["a"], rejected: ["a"]))
        #expect(GatewayMethodSupport.supports("a", advertised: ["a"], rejected: ["b"]))
    }
}
