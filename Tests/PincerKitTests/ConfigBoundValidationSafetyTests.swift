import Foundation
import Testing
import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct ConfigBoundValidationSafetyTests {
    private static func field(bound: String, value: Double) -> ConfigField? {
        ConfigSchema(schema: ["type": "object", "properties": ["limit": ["type": "number", bound: .number(value)]]]).field(at: ["limit"])
    }

    @Test(arguments: [true, false])
    func finiteSchemaBoundsOutsideInt64CannotTrap(minimum: Bool) async throws {
        let field = try #require(await Task.detached {
            Self.field(bound: minimum ? "minimum" : "maximum", value: minimum ? 1e30 : -1e30)
        }.value)
        let expected = minimum ? "Must be at least 1e+30." : "Must be at most -1e+30."
        #expect(field.validate( .number(0)) == expected)
    }

    @Test func ordinaryIntegerAndFractionalMessagesStayExact() async throws {
        let integer = try #require(Self.field(bound: "minimum", value: 10))
        let fractional = try #require(Self.field(bound: "maximum", value: 2.5))
        #expect(integer.validate( .number(9)) == "Must be at least 10.")
        #expect(integer.validate( .number(10)) == nil)
        #expect(fractional.validate( .number(3)) == "Must be at most 2.5.")
        #expect(fractional.validate( .number(2.5)) == nil)
    }
}
